# 魅族 16th（m1882）碎屏后桌面 60fps 修复 · 完整技术文档

> 版本：v1.0 ｜ 完成日期：2026-11-10 ｜ 最终方案：**V38**
> 最终镜像：`audit/boot_v38.img` ｜ md5 `f631bfa8c45c3192831654c76b57cac4`

---

## 目录

1. [摘要](#1-摘要)
2. [设备与环境](#2-设备与环境)
3. [问题现象](#3-问题现象)
4. [根因分析（三层递进）](#4-根因分析三层递进)
5. [版本演进全记录](#5-版本演进全记录)
6. [最终方案 V38](#6-最终方案-v38)
7. [验证数据](#7-验证数据)
8. [复现步骤](#8-复现步骤)
9. [回退与风险](#9-回退与风险)
10. [附录](#10-附录)

---

## 1. 摘要

### 1.1 问题

魅族 16th 屏幕物理损坏（DSI command mode AMOLED 面板不再返回 TE / PP_TX_DONE 中断）后，
系统帧率从 60fps 掉到 **2fps**，桌面几乎无法使用。

### 1.2 结果

通过修改内核中 **vsync 源的选择逻辑**，让 MDP 改用硬件看门狗定时器生成 vsync，
不再依赖已损坏的面板 TE 信号：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 桌面持续滚动 | 2 fps | **60 fps** |
| 静止（无动画） | 2 fps | 2~5 fps（正常省电行为） |
| 稳定性 | — | **111 秒满负荷零异常** |
| 内核错误 | 每帧 vblank 超时 | **全部为 0** |

### 1.3 关键突破

绕开了此前"改 fence 计数就冻结、不改就 panic"的死结，从**vsync 信号源头**下手。
补丁只有 **1 条指令**（加上此前已验证的 2 条 + 1 个代码洞）。

---

## 2. 设备与环境

### 2.1 硬件

| 项 | 值 |
|---|---|
| 型号 | 魅族 16th（m1882 / meizu_16th_CN） |
| SoC | 高通 SDM845 |
| 屏幕 | DSI **command mode** AMOLED（**物理损坏**） |
| 序列号 | 882QAET72F4YB |

### 2.2 软件

| 项 | 值 |
|---|---|
| ROM | MoKee 10 / Android 10（`MK100.0-m1882-220427-RELEASE`） |
| 内核版本 | `4.9.65-perf+` |
| 内核构建者 | `flyme@Mz-Builder-l9`，gcc 4.9.x，`#1 SMP PREEMPT Tue Jan 7 15:12:16 CST 2020` |
| Recovery | TWRP 3.3.1-1125 |
| Root | Magisk 30.6 |
| SELinux | permissive |
| 引导状态 | unlocked / `verifiedbootstate=orange` / `veritymode=disabled` |

### 2.3 关键地址

```
_text 虚拟地址 = 0xffffff8a51680000
文件偏移 = VA - 0xffffff8a51680000

boot 分区      = /dev/block/bootdevice/by-name/boot
boot.img 布局  = header(4096) | kernel(2876页) | ramdisk(227页) | second(0) | 尾部AVB
kernel 段      = 11,777,356 字节 = gzip(11,348,178) + 追加DTB(429,178)
ramdisk        = 928,725 字节
```

---

## 3. 问题现象

### 3.1 症状

屏幕损坏后：

- 系统能正常启动、adb / 触摸 / SurfaceFlinger 全部正常
- 但**帧率只有 2fps**，滑动几乎不动
- 静止时也是 2fps（正常手机静止时也低，但这里是被卡住的 2fps）

### 3.2 伴随的内核报错

```
[drm:_sde_encoder_update_rsc_client:1685] [sde error]enc25 wait for vblank failed ret:-110
```

`-110` = `-ETIMEDOUT`。每帧出现，间隔约 **200ms**。

### 3.3 早期误判（已推翻）

| 误判 | 推翻依据 |
|---|---|
| "只能换屏幕" | 锁屏 doze 路径可以到 60fps，证明软件层可绕 |
| "超时时间太长" | 缩短超时只到 25fps |
| "SurfaceFlinger backpressure" | `debug.sf.disable_backpressure=1` 反而更差（60→10fps） |
| "背光 DCS 写入导致" | 亮度调到 0/5/794 帧率不变 |
| "硬件进一步退化" | **错误结论**：当时测量时设备其实处于解锁桌面态，把桌面数据当成了锁屏数据 |

---

## 4. 根因分析（三层递进）

### 4.1 第一层：PP_TX_DONE 中断缺失（已知）

command mode 面板正常工作时，每帧完成后会向驱动发 `PP_TX_DONE` 中断。
驱动在 `sde_encoder_phys_cmd_pp_tx_done_irq()` 里做三件事：

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

面板坏了 → 中断不来 → fence 无人释放、`pending_kickoff_cnt` 不递减 →
每帧 `wait_for_idle` 等满超时 → 状态机降级 → 2fps。

### 4.2 第二层：fence 合成的死结（V27~V36 的探索）

尝试在 `trigger_start` 处用代码洞主动补发 `handle_frame_done()`：

| 版本 | 发送的事件 | 是否递减计数 | 结果 |
|---|---|---|---|
| V24 | `0x8` RELEASE | 无 | 10 fps |
| **V27** | **`0x9` RETIRE\|RELEASE** | **无** | **60 fps，但 70 秒后 panic** |
| V32 | `0x9` | retire + kickoff | 0 fps |
| V33 | `0x9` | 只 retire | 0 fps |
| V34 | `0x1` RETIRE | 无 | 0 fps |
| **V36** | `0x9` | **只 kickoff** | **不 panic，但仅 10~15 fps** |

**反汇编 `sde_encoder_frame_done_callback` 解释了这个规律：**

```asm
and  w0, w2, #0x7        ; 只测试 event 低 3 位
cbz  w0, <旁路回调>       ; (event & 7)==0 则不进入主帧事件机制
```

- `0x8`（只有 RELEASE）：`& 7 == 0` → 走旁路 → 10fps
- `0x1`（只有 RETIRE）：进主路径但缺 RELEASE → SF 饿死 → 0fps
- `0x9`：进主路径且带 RELEASE → 60fps ✓

### 4.3 V27 崩溃的真正原因（抓到了 backtrace）

此前一直猜"引用计数错乱"，**错了**。抓到 ramoops 后真相是：

```
msm_drm ae00000.qcom,mdss_mdp: <转储 lm/rsc 寄存器>
arm-smmu 15000000.apps-smmu: Unhandled context fault:
    iova=0x85c00800  fsr=0x40000402  fsynr=0x3c0022  SID=0x880
arm-smmu: SOFTWARE TABLE WALK FAILED! accessed an unmapped address!
arm-smmu: Unhandled arm-smmu context fault!
kernel BUG at drivers/iommu/arm-smmu.c:1504
PC: arm_smmu_context_fault+0x34c/0x568   (指令 d4210000 = brk #0)
Kernel panic - not syncing: Fatal exception
```

**根因：显示缓冲区 use-after-free。**
V27 让 SF 以为每帧都完成（60fps），SF 以 60fps 释放旧 buffer；
但硬件实际只按约 10fps 消费（因为 kickoff 计数从不递减，每帧等满 84ms 超时）。
buffer 被 unmap 时 MDP 还在读 → SMMU 故障 → BUG → panic。

**修复：V36 = V27 + 只递减 `pending_kickoff_cnt`（0x290），不动 retire 计数。**
→ 硬件 kickoff 不再被超时卡住 → SMMU 故障 0、kickoff 超时 0、不再 panic。
但帧率仍只有 10~15fps。

### 4.4 第三层：真正根因 —— vsync 源指向已坏的面板 TE ★

用四种独立方法交叉验证瓶颈（见 §7.1），确认每帧被 `_sde_encoder_update_rsc_client`
的 vblank 等待阻塞约 200ms。

读源码 `sde_encoder.c` 发现等待循环：

```c
for (wait_count = 0; wait_count < MAX_RSC_WAIT; wait_count++) {
    if (sde_rsc_client_is_state_update_complete(sde_enc->rsc_client))
        break;

    if (crtc->base.id == wait_vblank_crtc_id)
        ret = sde_encoder_wait_for_event(drm_enc, MSM_ENC_VBLANK);   /* 主屏走这条 */
    else
        drm_wait_one_vblank(drm_enc->dev, pipe);

    if (ret) {
        SDE_ERROR_ENC(sde_enc, "wait for vblank failed ret:%d\n", ret);
        if (crtc->base.id == wait_vblank_crtc_id)
            _sde_encoder_switch_to_watchdog_vsync(drm_enc);
    }
}
```

**驱动本来就有"没真 vsync 就用看门狗定时器"的兜底**，但看它的实现：

```c
static int _sde_encoder_switch_to_watchdog_vsync(struct drm_encoder *drm_enc)
{
    ...
    memcpy(&disp_info, &sde_enc->disp_info, sizeof(disp_info));  /* ← 拷贝到局部变量 */
    disp_info.is_te_using_watchdog_timer = true;                  /* ← 只改局部副本 */
    _sde_encoder_update_vsync_source(sde_enc, &disp_info, false);
    ...
}
```

而 vsync 源的选择在这里：

```c
static void _sde_encoder_update_vsync_source(...)
{
    if (hw_mdptop->ops.setup_vsync_source &&
            (disp_info->capabilities & MSM_DISPLAY_CAP_CMD_MODE)) {
        ...
        vsync_cfg.vsync_source = sde_enc->cur_master->hw_pp->caps->te_source;  /* 默认：面板 TE */
        if (is_dummy)
            vsync_cfg.vsync_source = SDE_VSYNC_SOURCE_WD_TIMER_1;
        else if (disp_info->is_te_using_watchdog_timer)
            vsync_cfg.vsync_source = SDE_VSYNC_SOURCE_WD_TIMER_0;
        ...
        hw_mdptop->ops.setup_vsync_source(hw_mdptop, &vsync_cfg);
    }
}
```

**问题链：**

1. 每次提交新帧，`_sde_encoder_update_vsync_source` 按 `sde_enc->disp_info`（其中标志仍是 `false`）
   把 vsync 源设回**已坏的面板 TE**
2. 等待 vsync → 超时 `-110` → 打印错误 → 调用 `_sde_encoder_switch_to_watchdog_vsync` 切看门狗
3. 但标志只写进了**局部副本**，`sde_enc->disp_info` 没更新
4. 下一帧又设回面板 TE → 再次超时 → **每帧循环烧掉 200ms**

**这就是 2fps / 10fps 的真正来源。**

**修复：让"看门狗 vsync"的选择恒为真。**

`is_te_using_watchdog_timer` 为真时，`sde_hw_setup_vsync_source()` 会：

```c
if (cfg->vsync_source >= SDE_VSYNC_SOURCE_WD_TIMER_4 &&   /* >= 11 */
    cfg->vsync_source <= SDE_VSYNC_SOURCE_WD_TIMER_0) {   /* <= 15 */
    case SDE_VSYNC_SOURCE_WD_TIMER_0:                     /* 15 */
        wd_load_value = MDP_WD_TIMER_0_LOAD_VALUE;
    ...
    SDE_REG_WRITE(c, wd_load_value, CALCULATE_WD_LOAD_VALUE(cfg->frame_rate)); /* 按 60Hz 算周期 */
    SDE_REG_WRITE(c, wd_ctl, BIT(0));      /* clear timer */
    reg |= BIT(8);                          /* enable heartbeat timer */
    reg |= BIT(0);                          /* enable WD timer */
    SDE_REG_WRITE(c, wd_ctl2, reg);
}
```

→ MDP 硬件看门狗定时器按 60Hz 产生 vsync，**不再依赖面板**。

---

## 5. 版本演进全记录

| 版本 | 改动 | 帧率 | 稳定 | 结论 |
|---|---|---|---|---|
| 原版 | — | 2 fps | 稳定 | 基线 |
| V3~V19 | 各类字节补丁 | 0~10 fps | 部分 | 全部失败 |
| **V20** | `0x56A94C` 0xE→0xA、`0x56A83C` 4→3 | 10 fps | 稳定 | 抑制 PANEL_DEAD，有改善 |
| V21~V26 | 各类 fence/超时变体 | 0~25 fps | 部分 | 失败 |
| **V27** | 代码洞发 `0x9`，不递减 | **60 fps** | **70s panic** | 证明 60fps 可达 |
| V28 | 变体 | 无改善 | — | 失败 |
| V29 | 在 trigger_start 递减 retire | 0 fps | — | **机器码写错**（`stlxr` 基址错） |
| V32 | `0x9` + 递减 retire + kickoff | 0 fps | — | 失败 |
| V33 | `0x9` + 只递减 retire | 0 fps | — | 失败 |
| V34 | 只发 `0x1` RETIRE | 0 fps | — | 缺 RELEASE，SF 饿死 |
| **V36** | V27 + 只递减 kickoff | 10~15 fps | **稳定** | 解决 SMMU 崩溃 |
| V37 | `MAX_RSC_WAIT` 5→1 | 0 fps | — | RSC 状态机需要多次 vblank |
| **V38** | **V36 + 强制看门狗 vsync** | **60 fps** | **稳定** | ★ 最终方案 |

### 5.1 弯路教训

| 教训 | 说明 |
|---|---|
| 先抓 backtrace 再改 | V27 崩溃原因猜了 5 个版本都不对，抓到 ramoops 后一次定位 |
| 测帧率必须记录前置状态 | 曾把解锁桌面数据当锁屏数据，得出"硬件退化"的错误结论 |
| 先读文档再动手 | 亮度实验早已证伪，仍重复做了 |
| 改前核实常量与偏移 | V29 因 `stlxr` 基址写错（`0x88007C00` 应为 `0x8800FC00`）导致非法指令 |
| 交叉验证 | 单一测量方法会被假象误导（vsync 计数器在降级态不可靠） |

---

## 6. 最终方案 V38

### 6.1 补丁清单（4 处）

基于**原厂 `boot.img` 里的 `Image`**（4.9.65）打补丁，不重新编译。

| # | 地址 | 原值 | 新值 | 作用 |
|---|---|---|---|---|
| 1 | `0x56A94C` | `0x528001C2` | `0x52800142` | frame_event `0xE`→`0xA`，抑制 PANEL_DEAD |
| 2 | `0x56A83C` | `0x52800081` | `0x52800061` | enable_state `4`→`3`，避免降级 |
| 3 | `0x566864` | — | 代码洞 | 合成 fence 信号 + 递减 kickoff |
| 4 | `0x56A0E8` | 原指令 | `bl 0x566864` | 挂到 `trigger_start` |
| 5 | `0x55E478` | `0x3940C6A4` | `0x52800024` | **强制看门狗 vsync（关键）** |

### 6.2 代码洞内容（0x566864，17 条指令）

```asm
0x566864  a9be7bfd   stp  x29,x30,[sp,#-0x20]!
0x566868  f9000bf3   str  x19,[sp,#0x10]
0x56686c  aa0003f3   mov  x19,x0                  ; phys_enc
0x566870  97ffe58a   bl   0x55fe98               ; 原 trigger_start
0x566874  f9400260   ldr  x0,[x19]                ; parent
0x566878  aa1303e1   mov  x1,x19
0x56687c  52800122   mov  w2,#9                   ; RETIRE|RELEASE
0x566880  97fff8dc   bl   0x564bf0               ; sde_encoder_frame_done_callback
0x566884  910a4265   add  x5,x19,#0x290           ; &pending_kickoff_cnt
0x566888  885f7ca6   ldaxr w6,[x5]
0x56688c  34000086   cbz  w6, end
0x566890  510004c6   sub  w6,w6,#1
0x566894  8807fca6   stxr w7,w6,[x5]
0x566898  35ffff87   cbnz w7, retry
0x56689c  f9400bf3   ldr  x19,[sp,#0x10]
0x5668a0  a8c27bfd   ldp  x29,x30,[sp],#0x20
0x5668a4  d65f03c0   ret
```

### 6.3 关键补丁详解（0x55E478）

```
原：3940c6a4   ldrb w4,[x21,#0x31]   ; 读 disp_info->is_te_using_watchdog_timer
新：52800024   mov  w4,#1            ; 恒为 true
```

**核实依据（全部来自 4.9.65 源码树 `meizucustoms/android_kernel_meizu_sdm845@oreo`）：**

| 项 | 值 | 出处 |
|---|---|---|
| 基准树版本 | 4.9.65 | `Makefile` `SUBLEVEL = 65` |
| `is_te_using_watchdog_timer` 偏移 | **0x31** | `msm_drv.h:451-470` 布局算出，与二进制 `ldrb w4,[x21,#0x31]` 吻合 |
| `SDE_VSYNC_SOURCE_WD_TIMER_0` | **15** | `sde_hw_mdss.h:96` |
| `PINGPONG_MAX` | **7** | `sde_hw_mdss.h:202-210` |
| `struct sde_vsync_source_cfg` | 见附录 A | `sde_hw_top.h:90-96` |
| WD_TIMER_0 配置行为 | 按 `frame_rate` 设定定时器周期 | `sde_hw_top.c:280-298` |

**六字段偏移交叉核对（全部吻合）：**

| 字段 | 结构体算出 | 二进制实测 |
|---|---|---|
| `pp_count` | 0x30 | `str w1,[x29,#0x30]` ✓ |
| `frame_rate` | 0x34 | `str w3,[x29,#0x34]` ✓ |
| `ppnumber[0]` | 0x38 | `str w0,[x29,#0x38]` ✓ |
| `ppnumber[1]` | 0x3c | `str w0,[x29,#0x3c]` ✓ |
| **`vsync_source`** | **0x54** | **`str w1,[x29,#0x54]`** ✓ |
| `is_dummy` | 0x58 | `strb w31,[x29,#0x58]` ✓ |

---

## 7. 验证数据

### 7.1 交叉验证：确认瓶颈（V36 上做的）

| 方法 | 结果 | 结论 |
|---|---|---|
| vsync 细采样（每 400ms） | 10~15 fps | 稳定低速，非周期性卡顿 |
| dmesg 时间戳 | 每 **200ms** 一次 `wait for vblank failed`，连续 | 每帧都卡 |
| SurfaceFlinger 状态 | 拖拽中 `state=VSync`（活跃） | 非 idle 导致 |
| `dumpsys gfxinfo` | 中位 46ms / 95%分位 **250ms** / 66.7% 卡顿 | 与 200~250ms 等待吻合 |

四种方法互相印证 → 瓶颈 = `_sde_encoder_update_rsc_client` 的 vblank 等待。

### 7.2 V38 最终验证

**错误统计（111 秒满负荷后）：**

```
wait for vblank failed = 0
context fault          = 0
kickoff timed out      = 0
PANEL_DEAD             = 0
Internal error (oops)  = 0
```

**帧率（每 10 秒采样，连续滑动 111 秒）：**

```
up=214.28  60 fps      up=274.85  60 fps
up=224.38  60 fps      up=284.95  60 fps
up=234.47  60 fps      up=295.03  60 fps
up=244.56  60 fps      up=305.11  60 fps
up=254.67  60 fps      up=315.22  60 fps
up=264.76  60 fps      up=325.30  60 fps
```

**各版本横向对比：**

| 指标 | 原版 | V20 | V27 | V36 | **V38** |
|---|---|---|---|---|---|
| 桌面滚动 | 2 fps | 10 fps | 60 fps | 10~15 fps | **60 fps** |
| 稳定时长 | — | — | 70s 后 panic | 稳定 | **111 秒零异常** |
| vblank 失败 | 每帧 | 每帧 | 有 | 4/2.5s | **0** |
| SMMU 故障 | 0 | 0 | **致命** | 0 | **0** |
| kickoff 超时 | 有 | 有 | 有 | 0 | **0** |

### 7.3 静止时帧率

静止时 `dumpsys SurfaceFlinger` 显示 `app: state=Idle`，帧率降到 2~5fps。

**这是 Android 标准省电行为**：没有画面变化（damage）就不合成新帧。
任何正常手机静止时都是这样。一旦滑动 / 播放动画，立即回到 60fps。

---

## 8. 复现步骤

### 8.1 准备

```powershell
# 需要的文件
handoff_kernel_patch/Image    # 从原厂 boot.img 解出的 4.9.65 Image（32,915,464 字节）
handoff_kernel_patch/boot.img # 原厂 boot.img（67,108,864 字节）
```

### 8.2 打补丁

`audit/patch_v38.py` 会：
1. 打 V20 的两条字节补丁
2. 写入代码洞（0x566864）并挂接到 0x56A0E8
3. 打看门狗 vsync 补丁（0x55E478）
4. gzip 压缩 + 追加原 DTB
5. 重打包成 boot.img（保持原布局与 AVB footer）

### 8.3 刷入

```bash
adb push boot_v38.img /sdcard/boot_v38.img
adb shell su -c "dd if=/sdcard/boot_v38.img of=/dev/block/bootdevice/by-name/boot bs=4096"
adb shell su -c sync
adb reboot
```

### 8.4 验证

```bash
# 1. 确认无 vblank 失败
adb shell 'dmesg | grep -c "wait for vblank failed"'   # 应为 0

# 2. 测帧率（需先施加负载，否则处于 Idle）
adb shell 'su -c "for i in \$(seq 1 200); do input swipe 540 1400 540 700 80; input swipe 540 700 540 1400 80; done" &
vs() { cat /sys/kernel/debug/dri/0/encoder25/status | sed -n "s/.*vsync: *\([0-9]*\).*/\1/p"; }
a=$(vs); sleep 3; b=$(vs); echo $(( (b-a)/3 )) fps'

# 3. 或用 scrcpy
scrcpy --print-fps --no-audio
```

---

## 9. 回退与风险

### 9.1 回退镜像（均在 `/sdcard/`）

| 文件 | md5 | 说明 |
|---|---|---|
| `boot_v38.img` | `f631bfa8c45c3192831654c76b57cac4` | 当前，60fps |
| `boot_v36.img` | `5d1dbd07377cded5bf921cc2581c3e10` | 不崩但仅 10~15fps |
| `boot_v20.img` | `307b762bc84040516033f8f3771d6cf5` | 10fps |
| `part_backup/boot.img` | `32e48617d1437a890c9703adf111f8ac` | 完全原版 |

### 9.2 回退命令

```bash
# 正常状态
adb shell su -c "dd if=/sdcard/part_backup/boot.img of=/dev/block/bootdevice/by-name/boot bs=4096"
adb shell su -c sync && adb reboot

# 若已无法启动：进 TWRP（Vol-Up + Power）
adb shell "dd if=/sdcard/part_backup/boot.img of=/dev/block/bootdevice/by-name/boot bs=4096"
adb shell sync && adb reboot
```

### 9.3 已知风险

| 风险 | 说明 | 严重度 |
|---|---|---|
| 看门狗定时器未接线 | 若 m1882 的 MDP WD timer 不可用，可能无改善（不会更差） | 低 |
| 初始化阶段也走看门狗 | `is_te_using_watchdog_timer` 全局为真，开机 modeset 也用它 | 低（已实测可正常启动） |
| 静止帧率低 | 属正常省电行为，非缺陷 | 无 |
| 功耗 | 60fps 合成比 2fps 耗电 | 中（可接受） |

---

## 10. 附录

### 附录 A：`struct sde_vsync_source_cfg`（`sde_hw_top.h:90-96`）

```c
struct sde_vsync_source_cfg {
    u32  pp_count;                /* +0x00 */
    u32  frame_rate;              /* +0x04 */
    u32  ppnumber[PINGPONG_MAX];  /* +0x08，PINGPONG_MAX = 7，共 28 字节 */
    u32  vsync_source;            /* +0x24 */
    bool is_dummy;                /* +0x28 */
};
```

### 附录 B：`struct msm_display_info` 偏移（`msm_drv.h:451-470`）

```c
struct msm_display_info {
    int      intf_type;                     /* 0x00 */
    uint32_t capabilities;                  /* 0x04 */
    uint32_t num_of_h_tiles;                /* 0x08 */
    uint32_t h_tile_instance[2];            /* 0x0C */
    bool     is_connected;                  /* 0x14 → 补到 0x18 */
    unsigned int width_mm;                  /* 0x18 */
    unsigned int height_mm;                 /* 0x1C */
    uint32_t max_width;                     /* 0x20 */
    uint32_t max_height;                    /* 0x24 */
    uint64_t clk_rate;                      /* 0x28 */
    bool     is_primary;                    /* 0x30 */
    bool     is_te_using_watchdog_timer;    /* 0x31 ★ */
    struct msm_roi_caps roi_caps;
};
```

### 附录 C：vsync 源常量（`sde_hw_mdss.h:87-96`）

```c
#define SDE_VSYNC0_SOURCE_GPIO       0
#define SDE_VSYNC1_SOURCE_GPIO       1
#define SDE_VSYNC2_SOURCE_GPIO       2
#define SDE_VSYNC_SOURCE_INTF_0      3
#define SDE_VSYNC_SOURCE_INTF_1      4
#define SDE_VSYNC_SOURCE_INTF_2      5
#define SDE_VSYNC_SOURCE_INTF_3      6
#define SDE_VSYNC_SOURCE_WD_TIMER_4  11
#define SDE_VSYNC_SOURCE_WD_TIMER_3  12
#define SDE_VSYNC_SOURCE_WD_TIMER_2  13
#define SDE_VSYNC_SOURCE_WD_TIMER_1  14
#define SDE_VSYNC_SOURCE_WD_TIMER_0  15   /* ★ 我们用的 */
```

### 附录 D：事件位掩码（`sde_encoder.h`）

```c
#define SDE_ENCODER_FRAME_EVENT_SIGNAL_RETIRE_FENCE   0x1
#define SDE_ENCODER_FRAME_EVENT_ERROR                 0x2
#define SDE_ENCODER_FRAME_EVENT_PANEL_DEAD            0x4
#define SDE_ENCODER_FRAME_EVENT_SIGNAL_RELEASE_FENCE  0x8
#define SDE_ENCODER_FRAME_EVENT_DONE                  0x10
```

### 附录 E：`struct sde_encoder_phys` 关键偏移

| 字段 | 偏移 |
|---|---|
| `parent` | 0x000 |
| `pending_ctlstart_cnt` | 0x28C |
| `pending_kickoff_cnt` | 0x290 |
| `pending_retire_fence_cnt` | 0x294 |
| `pending_kickoff_wq` | 0x298 |
| `enable_state` | 0x270 |

### 附录 F：关键函数地址（文件偏移）

| 函数 | 偏移 |
|---|---|
| `sde_encoder_frame_done_callback` | 0x564BF0 |
| `sde_encoder_phys_cmd_trigger_start` | 0x55FE98 |
| `sde_encoder_kickoff` | 0x55FFE0 |
| `_sde_encoder_update_rsc_client` | 0x562564 |
| `_sde_encoder_update_vsync_source` | 0x55E3E0 |
| `_sde_encoder_switch_to_watchdog_vsync` | 0x55FADC |
| `sde_hw_setup_vsync_source` | 0x5CD24C |
| `_sde_encoder_phys_cmd_wait_for_idle` | 0x56A5F4 |
| 代码洞 | 0x566864 |

### 附录 G：ARM64 指令编码参考（本次用到）

| 指令 | 编码 |
|---|---|
| `stp x29,x30,[sp,#-0x20]!` | 0xA9BE7BFD |
| `ldp x29,x30,[sp],#0x20` | 0xA8C27BFD |
| `str x19,[sp,#0x10]` | 0xF9000BF3 |
| `ldr x19,[sp,#0x10]` | 0xF9400BF3 |
| `ldr x0,[x19]` | 0xF9400260 |
| `mov x19,x0` | 0xAA0003F3 |
| `mov x1,x19` | 0xAA1303E1 |
| `movz w2,#9` | 0x52800122 |
| `movz w4,#1` | 0x52800024 |
| `add x5,x19,#0x290` | 0x910A4265 |
| `ldaxr w6,[x5]` | 0x885F7CA6 |
| `stxr w7,w6,[x5]` | 0x8807FCA6 |
| `sub w6,w6,#1` | 0x510004C6 |
| `cbz w6,+16` | 0x34000086 |
| `cbnz w7,-16` | 0x35FFFF87 |
| `ret` | 0xD65F03C0 |

> ⚠️ **注意**：`STLXR` 基址是 `0x8808FC00`，`STXR` 基址是 `0x8800FC00`。
> 曾误用 `0x88007C00` 导致生成非法指令（V29 的 0fps 就是这个原因）。

---

## 附：相关文件清单

| 路径 | 说明 |
|---|---|
| `audit/boot_v38.img` | **最终镜像** |
| `audit/patch_v38.py` | 生成脚本（完整可复现） |
| `audit/Image_v38.img` | 补丁后的 Image |
| `audit/v27_panic.txt` | V27 崩溃 ramoops 原始日志 |
| `尝试追踪链.md` | 全部 36 节调试历史 |
| `audit/o65_*.h` | 4.9.65 源码树关键头文件副本 |

---

**文档结束**