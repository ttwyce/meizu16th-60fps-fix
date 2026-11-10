# 魅族 16th（m1882）碎屏后桌面 60fps 修复

> Meizu 16th (m1882) dead-screen 60fps fix — 死屏导致 2fps 的根因分析与内核二进制补丁

**最终结果：桌面持续滚动从 2fps 恢复到 60fps，满负荷 111 秒零内核错误。**

---

## 1. 这是什么

魅族 16th 的 DSI **command mode** AMOLED 屏幕物理损坏后，面板不再返回
`PP_TX_DONE` 中断和 TE（tearing effect）信号。系统虽然能正常启动、adb / 触摸 /
SurfaceFlinger 全部正常，但**帧率只有 2fps**，桌面几乎无法使用。

本项目通过**修改内核中 vsync 源的选择逻辑**（而非换屏幕），让 MDP 改用硬件看门狗
定时器按 60Hz 生成 vsync，不再依赖已损坏的面板信号，最终在桌面场景恢复稳定 60fps。

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 桌面持续滚动 | 2 fps | **60 fps** |
| 满负荷稳定性 | — | **111 秒零异常** |
| `wait for vblank failed` | 每帧报错 | **0** |
| SMMU context fault | 有（某些补丁版本致命） | **0** |
| kickoff 超时 | 每帧 | **0** |
| PANEL_DEAD | 有 | **0** |

---

## 2. 设备与环境

| 项 | 值 |
|---|---|
| 型号 | 魅族 16th（m1882 / meizu_16th_CN） |
| SoC | 高通 SDM845 |
| 屏幕 | DSI command mode AMOLED（**物理损坏**） |
| ROM | MoKee 10 / Android 10（`MK100.0-m1882-220427-RELEASE`） |
| 内核 | `4.9.65-perf+`（flyme@Mz-Builder-l9，#1 SMP PREEMPT） |
| Recovery | TWRP 3.3.1-1125 |
| Root | Magisk 30.6 |
| 引导状态 | unlocked / `verifiedbootstate=orange` / `veritymode=disabled` |

关键地址：

```
_text 虚拟地址 = 0xffffff8a51680000
文件偏移       = VA - 0xffffff8a51680000
boot 分区      = /dev/block/bootdevice/by-name/boot
```

---

## 3. 根因分析（三层递进）

### 3.1 第一层：PP_TX_DONE 中断缺失

command mode 面板正常工作时，每帧完成后会向驱动发 `PP_TX_DONE` 中断，
驱动在 `sde_encoder_phys_cmd_pp_tx_done_irq()` 里完成三件事：

```c
/* 1. 递减 retire fence 计数并发 retire fence */
if (atomic_add_unless(&phys_enc->pending_retire_fence_cnt, -1, 0))
    handle_frame_done(..., SIGNAL_RETIRE_FENCE);
/* 2. 发 release fence */
handle_frame_done(..., DONE | SIGNAL_RELEASE_FENCE);
/* 3. 递减 pending_kickoff_cnt 并唤醒等待队列 */
atomic_add_unless(&phys_enc->pending_kickoff_cnt, -1, 0);
wake_up_all(&phys_enc->pending_kickoff_wq);
```

面板损坏 → 中断不来 → fence 无人释放、`pending_kickoff_cnt` 不递减 →
每帧 `wait_for_idle` 等满超时 → 状态机降级 → 2fps。

### 3.2 第二层：fence 合成的探索（V27~V36）

在 `trigger_start` 处用代码洞主动补发 `handle_frame_done()`。反汇编
`sde_encoder_frame_done_callback` 发现了关键掩码：

```asm
and  w0, w2, #0x7        ; 只测试 event 低 3 位
cbz  w0, <旁路回调>       ; (event & 7)==0 则不进入主帧事件机制
```

因此：
- 只发 `0x8`（RELEASE）→ `&7==0` → 走旁路 → 10fps
- 只发 `0x1`（RETIRE）→ 进主路径但缺 RELEASE → SF 饿死 → 0fps
- 发 `0x9`（RETIRE|RELEASE）→ 60fps，但触发 SMMU 崩溃

### 3.3 V27 崩溃的真正原因（抓到 backtrace）

```
arm-smmu 15000000.apps-smmu: Unhandled context fault:
    iova=0x85c00800  fsr=0x40000402  SID=0x880
SOFTWARE TABLE WALK FAILED! accessed an unmapped address!
kernel BUG at drivers/iommu/arm-smmu.c:1504
Kernel panic - not syncing: Fatal exception
```

**显示缓冲区 use-after-free**：补丁让 SF 以 60fps 释放旧 buffer，但硬件只按约 10fps
消费（kickoff 计数不递减，每帧等满 84ms 超时）→ buffer 被 unmap 时 MDP 还在读 → SMMU 故障。

**修复：同时递减 `pending_kickoff_cnt`（0x290），不动 retire 计数。**
→ SMMU 故障 0、kickoff 超时 0、不再 panic，但帧率仍只有 10~15fps。

### 3.4 第三层：真正根因 —— vsync 源指向已坏的面板 TE ★

每帧被 `_sde_encoder_update_rsc_client` 的 vblank 等待阻塞约 200ms。读源码发现
驱动**本来就有**"没真 vsync 就用看门狗定时器"的兜底：

```c
static int _sde_encoder_switch_to_watchdog_vsync(struct drm_encoder *drm_enc)
{
    ...
    memcpy(&disp_info, &sde_enc->disp_info, sizeof(disp_info));  /* 拷贝到局部变量 */
    disp_info.is_te_using_watchdog_timer = true;                  /* 只改局部副本 */
    _sde_encoder_update_vsync_source(sde_enc, &disp_info, false);
}
```

而 vsync 源选择在这里：

```c
vsync_cfg.vsync_source = sde_enc->cur_master->hw_pp->caps->te_source;  /* 默认：面板 TE */
if (is_dummy)
    vsync_cfg.vsync_source = SDE_VSYNC_SOURCE_WD_TIMER_1;
else if (disp_info->is_te_using_watchdog_timer)
    vsync_cfg.vsync_source = SDE_VSYNC_SOURCE_WD_TIMER_0;
```

**问题链**：每帧提交时按 `sde_enc->disp_info`（标志仍是 `false`）把 vsync 源设回已坏
面板 TE → 等待超时 → 切看门狗（但只改局部副本）→ 下一帧又设回 → **每帧循环烧 200ms**。

**修复：让"看门狗 vsync"的选择恒为真**（一条指令），MDP 看门狗定时器按 60Hz 生成 vsync。

---

## 4. 补丁详情（V38）

基于原厂 `boot.img` 内的 `Image`（4.9.65）打二进制补丁，不重新编译。

| # | 地址 | 原值 | 新值 | 作用 |
|---|---|---|---|---|
| 1 | `0x56A94C` | `0x528001C2` | `0x52800142` | frame_event `0xE`→`0xA`，抑制 PANEL_DEAD |
| 2 | `0x56A83C` | `0x52800081` | `0x52800061` | enable_state `4`→`3`，避免降级 |
| 3 | `0x566864` | — | 代码洞（17 条指令） | 合成 fence 信号 + 递减 kickoff |
| 4 | `0x56A0E8` | 原指令 | `bl 0x566864` | 挂到 `trigger_start` |
| 5 | `0x55E478` | `0x3940C6A4` | `0x52800024` | **强制看门狗 vsync（关键）** |

补丁 5 的语义：

```asm
原：3940c6a4   ldrb w4,[x21,#0x31]   ; 读 disp_info->is_te_using_watchdog_timer
新：52800024   mov  w4,#1            ; 恒为 true
```

关键常量（全部来自 4.9.65 源码树 `meizucustoms/android_kernel_meizu_sdm845@oreo` 并
与二进制交叉核对）：

| 项 | 值 | 出处 |
|---|---|---|
| `is_te_using_watchdog_timer` 偏移 | `0x31` | `msm_drv.h:451-470` |
| `SDE_VSYNC_SOURCE_WD_TIMER_0` | `15` | `sde_hw_mdss.h:96` |
| `PINGPONG_MAX` | `7` | `sde_hw_mdss.h:202-210` |
| `struct sde_vsync_source_cfg` | 见完整文档附录 | `sde_hw_top.h:90-96` |

---

## 5. 验证数据

**四方法交叉验证瓶颈**（V36 上做）：

| 方法 | 结果 | 结论 |
|---|---|---|
| vsync 细采样 | 10~15 fps | 稳定低速 |
| dmesg 时间戳 | 每 200ms 一次 vblank 失败 | 每帧都卡 |
| SurfaceFlinger 状态 | `state=VSync` | 非 idle 导致 |
| gfxinfo | 95% 分位 250ms | 与等待吻合 |

**V38 满负荷 111 秒**（每 10 秒采样）：

```
60 / 60 / 60 / 60 / 60 / 60 / 60 / 60 / 60 / 60 / 60 / 60 fps
错误统计：vblank失败=0  smmu=0  kickoff超时=0  PANEL_DEAD=0  oops=0
```

**说明**：静止时帧率降到 2~5fps 是 SurfaceFlinger `state=Idle` 的正常省电行为，
一旦有滑动/动画立即回到 60fps。

---

## 6. 使用方法

### 6.1 直接刷入镜像

```bash
adb push images/boot_v38.img /sdcard/boot_v38.img
adb shell su -c "dd if=/sdcard/boot_v38.img of=/dev/block/bootdevice/by-name/boot bs=4096"
adb shell su -c sync
adb reboot
```

镜像校验：

```
boot_v38.img  md5  f631bfa8c45c3192831654c76b57cac4
Image_v38.img md5  （见完整文档）
```

### 6.2 从原厂镜像复现补丁

```bash
# 需要：原厂 boot.img 解出的 Image + patch/patch_v38.py
# patch_v38.py 内写死了路径，按需修改 SRC / BOOT / OI / OB 后运行：
python patch_v38.py
```

### 6.3 验证

```bash
# 1. 无 vblank 失败
adb shell 'dmesg | grep -c "wait for vblank failed"'   # 应为 0

# 2. 帧率（先施加负载）
adb shell 'su -c "for i in \$(seq 1 200); do input swipe 540 1400 540 700 80; input swipe 540 700 540 1400 80; done" &
vs() { cat /sys/kernel/debug/dri/0/encoder25/status | sed -n "s/.*vsync: *\([0-9]*\).*/\1/p"; }
a=$(vs); sleep 3; b=$(vs); echo $(( (b-a)/3 )) fps'
```

### 6.4 回退

```bash
# 原厂 boot.img
adb shell su -c "dd if=/sdcard/part_backup/boot.img of=/dev/block/bootdevice/by-name/boot bs=4096"
adb shell su -c sync && adb reboot
```

---

## 7. 仓库结构

```
meizu16th-60fps-fix/
├── README.md                                    ← 本文
├── docs/
│   ├── 魅族16th死屏60fps修复_完整技术文档.md     ← 完整技术文档（10章+7附录）
│   ├── 尝试追踪链.md                             ← 36节完整调试历史
│   └── 目录结构说明.md                           ← 本地文件组织说明
├── patch/
│   └── patch_v38.py                             ← 从原厂 Image 复现补丁的脚本
└── images/
    ├── boot_v38.img                             ← 最终可刷镜像（64MB）
    └── Image_v38.img                            ← 补丁后的内核 Image（31MB）
```

---

## 8. 版本演进摘要

| 版本 | 改动 | 帧率 | 稳定 | 结论 |
|---|---|---|---|---|
| 原版 | — | 2 fps | 稳定 | 基线 |
| V20 | 抑制 PANEL_DEAD | 10 fps | 稳定 | 有改善 |
| V27 | 代码洞发 `0x9`，不递减 | 60 fps | 70s panic | 证明 60fps 可达 |
| V36 | V27 + 递减 kickoff | 10~15 fps | 稳定 | 解决 SMMU 崩溃 |
| **V38** | **V36 + 强制看门狗 vsync** | **60 fps** | **稳定** | ★ 最终 |

完整 34 个版本的记录见 `docs/尝试追踪链.md`。

---

## 9. 免责声明

- 本项目针对**屏幕已物理损坏**、且已解锁引导、已 root 的设备。正常设备无需也无益。
- 刷写 boot 分区有风险，请先备份原厂 `boot.img` 与 `dtbo`，并确认能进 TWRP。
- 补丁改动了 vsync 源，可能影响功耗（60fps 合成比 2fps 耗电）。
- 镜像基于魅族原厂内核二进制修改，仅用于个人设备维修，请遵守当地法律法规。

---

## 10. 致谢与出处

- 4.9.65 源码树：[meizucustoms/android_kernel_meizu_sdm845](https://github.com/meizucustoms/android_kernel_meizu_sdm845)（`oreo` 分支）
- 设备 ROM：MoKee OpenSource（使用魅族原厂预编译内核）
- 完整调试过程见 `docs/尝试追踪链.md`