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
---

## 11. 后续迭代：从 V38 到 V43（2026-11-10 下午）

> 本章记录 V38 之后针对"停止再滑动卡顿 / 浏览器 0fps"的继续排查。
> **最终定版：V43**（md5 `d03680624bcbb14f755317a15d907156`）。

### 11.1 V38 的遗留问题

用户反馈"一直滑动不卡，停止滑动再滑动时会卡"。100ms 细采样定位：

```
静止时 SF 释放 vblank 引用 → 驱动注销 RDPTR 中断 → 看门狗 vsync 停摆
恢复滑动需重新注册 → 100~200ms 空档 → 第一帧出不来
```

实测：静止 10~20s 后恢复滑动，前 300ms 仅 20~28fps（V38）。

### 11.2 失败尝试（都查清了原因，非瞎试）

| 版本 | 改动 | 结果 | 根因 |
|---|---|---|---|
| **V39** | 递减 `pending_ctlstart_cnt`（0x28C） | 约 8 分钟后 **GPU 死锁** | 在 0ms 伪造"帧已开始"，硬件未动 → display buffer use-after-free → SF 卡在 `adreno_drawctxt_wait` |
| **V40** | 驱动层 no-op `unregister_irq(RDPTR)` | **黑屏 0fps** | 只改驱动层，DRM 核心层仍置 `vblank_enable=0`，状态不一致 |
| **V41** | DRM 层 `vblank_disable_fn` 永不关闭 | 开始流畅，约 9 分钟后 **0fps** | vblank 常开 → SF 持续提交 → ctl_start 超时 → commit 失败 → `retire event overflow`（槽耗尽） |
| **V42** | V41 + ctl_start 超时 `ret=0` | 桌面 5 分钟 60fps，但**打开浏览器 GPU 死锁** | 超时路径与代码洞**双重 signal retire fence** → fence 序号错位 → GPU syncpoint deadlock |

V42 死锁的决定性证据：
```
kgsl: possible gpu syncpoint deadlock
context[2] pending events: [0] FENCE sde_fence:conn26:39654
plane92 9999ms timeout on kgsl-timeline
```

### 11.3 V43 最终定版

**V43 = V38 + 仅 ctl_start 超时 `ret=0`（撤销 vblank 常开）**

```
0x56AE64: 12800DB4 (movn w20,#0x6d = -110)  →  52800014 (movz w20,#0)
```

原理：`wait_for_ctl_start` 超时后驱动本来就有降级处理（signal retire + 递减 ctlstart），
但返回 `-ETIMEDOUT` 导致 commit 失败。改成 `ret=0` 后 commit 继续、retire 槽正常释放。
同时**保留 vblank 正常关闭**（撤销 V41），避免 SF 无限提交导致 GPU 队列堆积。

**与 V39 的本质区别**：V39 在 0ms 伪造成功；V43 等满 84ms 后才放弃，硬件有足够时间，安全。

### 11.4 V43 实测（最终验收）

| 场景 | 结果 |
|---|---|
| 桌面持续滑动 5 分钟 | 60 fps |
| 停止→滑动循环 18 轮 | 61~62 fps |
| **浏览器（Via）持续滚动** | **53~60 fps**（scrcpy 实测，偶有 29/42/50 波动属正常） |
| GPU 死锁 / retire overflow / fence 超时 | **全 0** |
| ctl_start / commit / vblank 错误 | **全 0** |

### 11.5 ⚠️ 测量陷阱（重要教训）

曾误报"浏览器滑动只有 6fps"，**实为测量失效**：
`input swipe` 报 `INJECT_EVENTS` 权限错误 → 滑动根本没注入 → SF 进 Idle → vsync 停摆。

**正确做法**：
- 用 `su -c` 执行 input 保证权限
- 同时记录两个指标：`/sys/kernel/debug/dri/0/encoder25/status` 的 vsync 计数 + scrcpy `--print-fps` 实际编码帧率
- 报数前先确认 `ps -A | grep surfaceflinger` 线程状态与输入是否真的生效

用户在投屏窗口看到的 30 多 fps 是真实的；错误结论来自测量脚本，不是设备。

### 11.6 当前 V43 完整补丁清单

| # | 地址 | 改动 | 作用 |
|---|---|---|---|
| 1 | `0x56A94C` / `0x56A83C` | V20 两点 | 抑制 PANEL_DEAD / 降级 |
| 2 | `0x55E478` | watchdog vsync | 坏面板 TE → 硬件看门狗定时器 |
| 3 | `0x566864` + `0x56A0E8` | 代码洞 | `frame_done(0x9)` + 递减 kickoff |
| 4 | `0x56AE64` | ctl 超时 `ret=0` | commit 不失败，retire 槽不堆积 |

> 不含 V41 的 vblank 常开（`0x51B840` 保持原样 `0x35000120`）。

### 11.7 版本链

```
V38（恢复卡顿）→ V39（GPU 死锁，废）→ V40（黑屏，废）
→ V41（0fps 溢出）→ V42（浏览器 GPU 死锁）→ V43（★ 最终定版）
```

---

## 12. ★ V45 最终修复：真正的根因是 ESD 检测（2026-11-10 傍晚）

> **最终定版：V45**｜md5 `565d5a9e78fca3b16661ef73a3a219e1`

### 12.1 ⚠️ 必须先承认的测量错误（贯穿 V38~V44）

之前所有"60fps"读数都来自：

```bash
cat /sys/kernel/debug/dri/0/encoder25/status   # vsync 计数
```

**这个计数器由看门狗定时器以 60Hz 独立驱动，与画面是否真的合成无关。**
面板坏了、屏幕全黑时，它照样显示 60。因此出现了"我报 60fps、用户看到黑屏 0fps"的矛盾。

**正确测量方法（缺一不可）**：

| 指标 | 命令 | 说明 |
|---|---|---|
| 真实帧率 | `scrcpy --print-fps` | 实际编码/传输帧率，最接近人眼观感 |
| 画面内容 | `screencap -p /sdcard/x.png` + 像素采样 | **判断是否黑屏的唯一可靠手段** |
| 内核错误 | `dmesg \| grep -c ...` | PANEL_DEAD / timeline reset / ctl start |

**教训**：vsync 计数在"用看门狗伪造 vsync"的方案里完全失去测量意义。

### 12.2 V44 失败

V44 = V43 + ctl_start 超时后补发 retire。刷入后**从未做过真实帧率测量**（只看了 vsync 计数），
实际从启动就黑屏。排查确认：`vblank_enable=0`、截图全黑（14050 字节纯黑 PNG）、scrcpy 0fps。

### 12.3 ★ 真正的根因：ESD 检测失败 → PANEL_DEAD → fence 时间线重置

杀 SF 强制冷启动后，dmesg 暴露了关键错误：

```
[drm:_sde_connector_report_panel_dead:1760] esd check failed report PANEL_DEAD conn_id: 26 enc_id: 25
[sde error]timeline reset attempt! done count:3175 commit:3178
```

**完整链条**：

```
1. 面板物理损坏 → DCS 寄存器读（ESD reg_read 模式）必然超时
2. sde_connector_check_status_work() 检测失败（rc <= 0）
3. → _sde_connector_report_panel_dead()
4. → msm_mode_object_event_notify(DRM_EVENT_PANEL_DEAD)
5. → sde_encoder_display_failure_notification()
6. → 显示管线重启 + fence timeline reset
7. → GPU 在等的 fence 序号被清零 → syncpoint deadlock
8. → vblank 被关闭 → SF 停止合成 → 黑屏 / 0fps
```

**这解释了 V38~V44 全部"用几分钟/几十分钟后变黑"的现象**——不是补丁退化，而是 ESD 每隔
`STATUS_CHECK_INTERVAL_MS` 就拆一次台。

**尝试过但无效**：debugfs `esd_check_mode` 改 `te_signal_check`（坏屏 TE 也不可靠，仍失败）、
`err_fg_gpio`（同样依赖面板反馈）。**坏屏下任何 ESD 检测模式都必然失败，只能彻底禁用。**

### 12.4 V45 修复（2 条指令）

```
0x5854CC: sde_connector_schedule_status_work → ret (0xD65F03C0)
          ESD 状态检查永不调度，从源头消除 PANEL_DEAD
0x584350: _sde_connector_report_panel_dead   → ret (0xD65F03C0)
          双保险：即使被调用也直接返回
```

配套 Magisk 持久脚本 `/data/adb/service.d/esdfix.sh`（等 debugfs 节点出现后写入
`te_signal_check`，作为第三层保险）。

### 12.5 实测结果（全部使用真实指标）

| 项目 | 结果 |
|---|---|
| 截图内容 | **968/968 采样点非黑 ✓ 有画面** |
| PANEL_DEAD | **0** |
| timeline reset | **0** |
| ctl_start 超时 | **0** |
| GPU syncpoint deadlock | **0** |
| retire event overflow | **0** |
| 连续运行 | **420 秒（7 分钟）零错误** |
| 快速滚动帧率 | 峰值 **60~66fps**，平均 ~40-50（含手势间隙造成的 SF 空闲） |

### 12.6 V45 完整补丁清单（6 处）

| # | 地址 | 改动 | 作用 |
|---|---|---|---|
| 1 | `0x56A94C` / `0x56A83C` | V20 两点 | 抑制 PANEL_DEAD 事件位 / 防降级 |
| 2 | `0x55E478` | `ldrb→mov w4,#1` | vsync 源改 MDP 看门狗定时器 |
| 3 | `0x566864`+`0x56A0E8` | 代码洞 | 合成 frame_done(0x9) + 递减 kickoff |
| 4 | `0x56AE64` | `movn #-110 → movz #0` | ctl_start 超时后 commit 继续 |
| 5 | `0x5854CC` | `stp → ret` | **ESD 检查永不调度（本轮核心）** |
| 6 | `0x584350` | `stp → ret` | **PANEL_DEAD 上报永不执行（本轮核心）** |

### 12.7 版本链与结论

```
V38（恢复卡顿）→ V39（GPU死锁）→ V40（黑屏）→ V41（overflow）
→ V42（双重retire）→ V43（ESD未修，会渐变黑）→ V44（从未真正工作）
→ V45（★ 定位 ESD 真根因，彻底禁用，画面正常、零错误）
```

**根本教训**：
- 坏屏设备的故障是**多因叠加**：vsync 源、ctl_start、kickoff 计数、retire 记账、**ESD 检测**，
  必须逐一定位，缺一不可。
- **测量方法本身必须先被验证**。本轮最大的坑是我用了一个与观感无关的计数器当作帧率，
  导致连续多个版本"测试通过"实际是黑屏。
- 任何"我这边正常"的结论，必须同时给出 **截图非黑 + scrcpy 实际帧率 + 内核零错误** 三项证据。

---

## 13. ★ V53 最终修复（2026-11-10 晚）

> **最终定版：V53**｜md5 `f26c9525cacf934b17f74d9ac96ba874`
>
> 实测：长时间使用丝滑，内核 `sde error` 数为 **0**。

### 13.1 V50 失败：fence 永不阻塞（方案 A）

把 `sde_fence_signaled()`（sde_fence.c:126）改成永远 `return true`：

```
0x59BCE8: stp x29,x30  →  mov w0,#1 ; ret
```

效果：SF 从 `adreno_drawctxt_wait` 变成 `R`（Running），不再阻塞。但
`prepare_commit` 的 retire 队列仍然每 100ms 溢出一次，最终系统彻底停止响应（看门狗重启）。
**结论：消除等待不等于消除队列卡死。**

### 13.2 V51 失败：自旋锁自死锁 → 无限重启（关键教训）

思路：不再手写逻辑，改为调用驱动自己的
`sde_encoder_phys_cmd_pp_tx_done_irq()`（0x568BC0）。

**结果：第一帧就死锁，无限重启。** 用源码证实了原因：

```c
/* sde_encoder.c:3603-3647  sde_encoder_kickoff() */
spin_lock_irqsave(&sde_enc->enc_spinlock, lock_flags);
    ...
    _sde_encoder_trigger_start(sde_enc->cur_master);   /* ← 我们的 hook 在这里 */
    ...
spin_unlock_irqrestore(&sde_enc->enc_spinlock, lock_flags);

/* sde_encoder.c:4783 */  phys_params.enc_spinlock = &sde_enc->enc_spinlock;
/* sapphire_phys_cmd.c:1452 */ phys_enc->enc_spinlock = p->enc_spinlock;
```

`pp_tx_done_irq` 内部要 `spin_lock_irqsave(phys_enc->enc_spinlock, ...)`——**与 kickoff
持有的是同一把非递归自旋锁**，因此在 hook 点调用它必然自死锁。

> **教训：改内核之前必须先确认调用点的锁状态。**

### 13.3 V52：代码洞语义修正（真正的进步）

不改调用位置，而是把驱动 `pp_tx_done_irq` 的**守卫语义**内联进代码洞
（此时锁已由 kickoff 持有，无需重复获取）：

```
/* 代码洞 0x566864，33 条指令 */
mov  x19, x0                       // phys_enc
add  x5, x19, #0x294               // &pending_retire_fence_cnt
ldaxr w6,[x5]; cbz w6, skip; sub w6,w6,#1; stxr w7,w6,[x5]; cbnz w7,retry
    → frame_done(SIGNAL_RETIRE_FENCE=0x1)
skip:
add  x5, x19, #0x28C               // &pending_ctlstart_cnt
ldaxr w6,[x5]; cbz w6, skip2; sub w6,w6,#1; stxr w7,w6,[x5]; cbnz w7,retry
skip2:
    → frame_done(DONE|SIGNAL_RELEASE_FENCE = 0x18)
add  x5, x19, #0x290               // &pending_kickoff_cnt
ldaxr w6,[x5]; cbz w6, done; sub w6,w6,#1; stxr w7,w6,[x5]; cbnz w7,retry
done: ret
```

**与旧版（V38~V46）的本质区别**：旧版是**无条件**发事件，导致账目错位
（漏记/多记/队列不释放）；新版每一步都受 `atomic_add_unless(…,-1,0)` 守卫——
**计数器为 0 时什么都不做**，这正是驱动 `pp_tx_done_irq` 的写法。

效果：`retire event overflow` / `without kickoff` / `syncpoint deadlock` / `ctl start`
全部归零。

### 13.4 V52 残留故障：我自己埋的坑

V52 启动正常，但使用后重启。dmesg：

```
failed to enable clk control -16 (EBUSY)
enc25 sw_event:1, rc in state 4            ← 状态机在 IDLE(4) 收到非法事件
enc25 resource kickoff failed rc -16
VBIF 0 client 12 not halting. TIMEDOUT.    ← 硬件停不下来
```

**根因是 V47 引入的两个"撒谎"补丁**：为了让转场不卡 84ms，曾把

```
0x56A5F4  _sde_encoder_phys_cmd_wait_for_idle   → mov w0,#0 ; ret
0x56A0F8  sde_encoder_phys_cmd_wait_for_vblank  → mov w0,#0 ; ret
```

改成直接返回成功。这让资源控制状态机以为硬件已空闲，**提前进入 IDLE 态**
（enum: `OFF=0, PRE_OFF=1, ON=2, MODESET=3, IDLE=4`），之后 KICKOFF 撞 EBUSY、
VBIF 无法 halt。

而这两个谎在 V52 之后**已无必要**：代码洞在 kickoff 时就把 `pending_kickoff_cnt`
递减到 0，真实的 `wait_for_idle` 会立即返回 0。

### 13.5 V53 定版

在 V52 基础上，**按原厂镜像完整恢复**上述两个函数（注意：必须恢复**两条**指令，
只恢复第一条会留下 `ret`，造成栈不平衡而崩溃）：

```
0x56A5F4: d101c3ff a9017bfd   (sub sp,sp,#0x70 ; stp x29,x30,[sp,#16])
0x56A0F8: a9bd7bfd 910003fd   (stp x29,x30,[sp,#-0x30]! ; add x29,sp,#0)
```

### 13.6 V53 验收

| 项目 | 结果 |
|---|---|
| `sde error`（本次开机全部） | **0** |
| retire event overflow | **0** |
| retire event without kickoff | **0** |
| GPU syncpoint deadlock | **0** |
| ctl_start 超时 | **0** |
| resource kickoff failed / clk control / VBIF not halting | **0** |
| PANEL_DEAD / timeline reset / esd check failed | **0** |
| DRM vblank | **58~60 fps** |
| 截图画面 | **968/968 采样点非黑** |
| 实际使用 | **丝滑，长时间无异常** |

### 13.7 V53 权威补丁清单（镜像 diff 生成）

| # | 地址 | 原厂 | V53 | 作用 |
|---|---|---|---|---|
| 1 | `0x55E478` | `3940C6A4` | `52800024` | vsync 源强制改 MDP 看门狗定时器 |
| 2 | `0x566864`~`0x5668E3` | — | 33 条指令 | **代码洞：守卫式完成逻辑**（覆盖 `_sde_encoder_phys_vid_wait_for_vblank`，video 模式专用，command 模式永不执行） |
| 3 | `0x56A0E8` | `97FFD76C` | `97FFF1DF` | `trigger_start` 中 `bl` 到代码洞 |
| 4 | `0x56A83C` | `52800081` | `52800061` | enable_state 4→3 |
| 5 | `0x56A94C` | `528001C2` | `52800142` | 抑制 PANEL_DEAD 事件位 |
| 6 | `0x56AE64` | `12800DB4` | `52800014` | ctl_start 超时返回 0，commit 继续 |
| 7 | `0x584350` | `A9BD7BFD` | `D65F03C0` | `_sde_connector_report_panel_dead` → `ret` |
| 8 | `0x5854CC` | `A9B87BFD` | `D65F03C0` | `sde_connector_schedule_status_work` → `ret`（ESD 检查永不调度） |

> 另：`0x566900`~`0x566957` 残留 V46 实验期代码（现已无跳转指向，属死代码，
> 位于永不执行的 video 模式函数空间内，无副作用）。

**已恢复原厂**（不再需要）：`0x56A5F4` / `0x56A0F8`（真实等待）、`0x56ACBC`、
`0x51B840`（vblank 常开）、`0x59BCE8`（fence 永不阻塞）。

### 13.8 版本终局

```
V38(恢复卡顿) → V39(GPU死锁) → V40(黑屏) → V41(overflow) → V42(双重retire)
→ V43(ESD未修) → V44(从未工作) → V45(定位ESD真根因) → V46(漏retire)
→ V47(谎报idle埋坑) → V48(vblank常开致溢出) → V49(autorefresh补过头)
→ V50(fence永不阻塞) → V51(自旋锁自死锁/无限重启)
→ V52(守卫式代码洞，残留状态机错误) → V53(★ 定版：零错误，丝滑)
```

### 13.9 本轮核心教训

1. **测量方法必须先被验证**。用 vsync 计数器当帧率，导致多个版本"测试通过"实为黑屏。
2. **改内核前先确认调用点的锁状态**。V51 在持锁区调用会再次取同一把锁 → 自死锁。
3. **不要对状态机撒谎**。把 `wait_for_idle` 改成恒返回 0，会让资源控制提前进 IDLE，
   后续 KICKOFF 撞 EBUSY、VBIF 无法 halt。
4. **伪造事件必须带守卫**。`atomic_add_unless(…,-1,0)` 的语义是"计数器为 0 就什么都不做"，
   无条件发事件必然导致记账错位。
5. **恢复补丁时要恢复完整指令组**。只恢复首条会留下 `ret`，造成栈不平衡。

---

## 14. 附：一次由调试脚本引发的 WebView 故障（2026-11-10 晚）

> 与 60fps 修复无关，但**是本次调试过程中自己造成的**，记录以免重犯。
> 症状：浏览器能上网但打不开网页 → 后发展为直接闪退。

### 14.1 症状与初步误判

- 设备网络正常（`ping` 通、`curl https://www.baidu.com` 返回 **HTTP 200 / 0.17s**）
- DNS 正常（当时 FlClash 在 fake-ip 模式，返回 `198.18.0.23`；关闭后返回真实 IP `110.242.69.21`）
- 但浏览器白屏、随后闪退

**容易误判为网络/代理问题，实际与网络无关。**

### 14.2 真正的崩溃原因

logcat 中的致命信息：

```
F DEBUG : Abort message: 'JNI FatalError called: (zygote) Failed open(
            /sys/kernel/debug/tracing/trace_marker, 1): Permission denied'
F DEBUG : name: webview_zygote  >>> webview_zygote <<<

backtrace:
  #03 art::JNI::FatalError
  #04 ZygoteFailure
  #05 FileDescriptorInfo::ReopenOrDetach
  #06 FileDescriptorTable::ReopenOrDetach
  #07 ForkCommon
  #08 Zygote.nativeForkAndSpecialize
  #22 ZygoteConnection.processOneCommand
  #43 WebViewZygoteInit.main
```

配合 `ActivityManager: com.android.webview:sandboxed_process1 failed to attach` /
`Killing … : start timeout`——**WebView 渲染进程从未成功创建**，所以浏览器必然白屏或闪退。

### 14.3 因果链

```
zygote 启动时持有 /sys/kernel/debug/tracing/trace_marker 的 fd
        ↓
webview_zygote 从 zygote fork，继承该 fd
        ↓
它再 fork 渲染进程时，Zygote 的 FileDescriptorTable::ReopenOrDetach
会以「子进程 uid」重新 open() 这个 fd（这是 Android 的 fd 卫生机制）
        ↓
但 /sys/kernel/debug 的目录权限是 0700 root
        ↓
非 root 的沙箱 uid 无法穿越目录 → open() 返回 EACCES
        ↓
Android 将 fd 重开失败视为致命错误 → JNI FatalError → abort()
        ↓
渲染进程无法创建 → 浏览器打不开网页 / 闪退
```

### 14.4 元凶：一条多余的 remount

```
esdfix.sh:8:  mount -o rw,remount /sys/kernel/debug
```

**remount 会把 debugfs 根目录权限重置为内核默认值 0700**，而
`init.qcom.rc:37` 明确设定的是：

```
chmod 0755 /sys/kernel/debug
```

所以在 17:12 加入该脚本之前浏览器一切正常，加入之后每次开机 WebView 必崩。

> 注意：`/sys/kernel/debug/tracing` 本身是 0755（`init.rc:421`），
> 被卡住的是**上层 `/sys/kernel/debug` 的穿越权限**。

### 14.5 修复

1. **删除 `esdfix.sh`**——V45 起 ESD 已在内核层彻底禁用
   （`0x5854CC` / `0x584350` 两处直接 `ret`），该脚本本就多余
2. 恢复权限：`chmod 0755 /sys/kernel/debug`
3. **重启**（见 14.6）
4. 强制重启浏览器进程，清掉失效状态

### 14.6 附带教训：不要 kill `webview_zygote`

它**不是 init 的服务**（`getprop init.svc.webview_zygote` 为空），
而是由主 zygote 按需 fork 的子 zygote，框架侧缓存着 socket。
`kill -9` 之后：

- `start webview_zygote` 无效
- init 不会重启它
- 框架不再重新 fork（socket 缓存已失效）

**唯一恢复方式：重启设备。**

### 14.7 验证

| 项目 | 结果 |
|---|---|
| webview_zygote 崩溃 | **0** |
| 渲染进程 | **2 个（正常创建）** |
| `net::ERR` / `failed to attach` | **0** |
| 页面渲染 | 截图颜色数 **888**、纯白仅 **3.1%**（正常网页特征） |
| `/sys/kernel/debug` | `drwxr-xr-x` ✓ |
| 显示内核 V53 | `sde_error=0` / `overflow=0` / `deadlock=0` |

### 14.8 排查方法论

1. **先分层定位**：网络层（ping / curl / DNS）→ 应用层（logcat 崩溃栈）。本次网络层全部正常，问题在应用层。
2. **`F DEBUG` / `Abort message` 是最直接的线索**，比猜测有效得多。
3. **颜色多样性判断渲染**：整屏纯白占比 >90%、颜色数 <200 基本可断定"没渲染出来"，
   正常网页通常 >500 种颜色。这是无 GUI 环境下判断"是否白屏"的实用手段。
4. **改系统行为时优先查 init 的预期值**（`init.rc` / `init.*.rc` 里的 `chmod` / `mkdir`），
   破坏它的前提是有充分理由。

---

## 15. 附：USB adb 在热重启后失效（2026-11-10 晚）

> 与 60fps 修复无关，但同属死屏设备的可用性关键问题。
> 完整分析见 `adb开机自愈方案.md` 第九章。

### 15.1 一句话结论

ROM 的 `/vendor/etc/init/hw/init.msm.usb.configfs.rc` 里，
`sys.usb.config=adb` 和 `=mtp,adb` 两条规则**只写 VID/PID，不构建 gadget**
（不清空 f1~f9、不 symlink `ffs.adb`、不绑 UDC）。真正构建 gadget 的规则
都要求 `sys.usb.ffs.ready=1` 且属于其它组合（`mtp,diag,adb`、`diag,adb` 等）。

所以 `setprop sys.usb.config adb` 在 gadget 有残留功能时，会得到
"PID 声称 adb、实际只有 MTP"的状态 → 主机看不到 adb，而 adbd 进程依然健康。

### 15.2 冷启动 vs 热重启

- 冷启动：gadget 从零构建，框架会把 f1 正确设为 `ffs.adb` → 可用
- 热重启：gadget 保留上次内容（如 `mtp.gs0`），只改 PID → **adb 失效**

### 15.3 修复

脚本里的裸 `adb` 改为 `mtp,diag,adb`：

```
/data/local/adbfix.sh:107   setprop sys.usb.config mtp,diag,adb
/data/local/usbfix.sh:66    setprop sys.usb.config mtp,diag,adb
```

该组合有完整构建规则，会先 `rm f1..f9` 再重建，天然干净。

### 15.4 排查要点

**永远不要相信 `sys.usb.config` / `sys.usb.state`**，权威来源是：

```bash
adb shell 'ls -l /config/usb_gadget/g1/configs/b.1/ | grep "^l"'
# 必须看到 ffs.adb 的 symlink，否则 ADB 接口不存在

adb shell 'cat /config/usb_gadget/g1/idProduct'
# 0x0C01 / 0x0C02 = 走了"只改PID"的危险规则
# 0x903A        = mtp,diag,adb 的完整重建规则（安全）
```

> **⚠️ 第 15 章的方案已被推翻（2026-11-11 更新）**：
> 15.3 推荐的 `setprop sys.usb.config mtp,diag,adb` 虽然能重建 gadget，
> 但实测会触发 adbd 进入 `stopping` 死锁，且 Windows 会多出 MTP + COM 口。
> **正确做法是直接操作 configfs 重建 gadget（v20）**，见第 16 章。

---

## 16. ★ 2026-11-11：USB adb 根治 + 无线 adb + GSI 兼容性实测

### 16.1 USB adb 失效的根治方案（v20）

第 15 章找到了"B 类规则不清功能"的证据，本章给出不依赖任何属性组合的根治方案。

**问题**：`sys.usb.config=adb` 走的规则只写 idVendor/idProduct（0x2A45/0x0C01），
不清空 f1~f9、不 symlink `ffs.adb`、不绑 UDC。冷启动时 gadget 先被配成 MTP，
于是出现"PID 声称 adb、实际只有 MTP"的错位状态，主机看不到 ADB 设备。

**修复：直接操作 configfs（无需重启）**

```bash
GB=/config/usb_gadget/g1
UDC=$(ls /sys/class/udc | head -1)
echo "" > $GB/UDC                                        # 断开
sleep 1
rm -f $GB/configs/b.1/f1 $GB/configs/b.1/f2 $GB/configs/b.1/f3
ln -s $GB/functions/ffs.adb $GB/configs/b.1/f1           # 链上 ADB
echo 0x2a45 > $GB/idVendor
echo 0x0c01 > $GB/idProduct
setprop sys.usb.ffs.ready 1
sleep 1
echo "$UDC" > $GB/UDC                                    # 重新挂上
```

实测：修复前 `f1 -> mtp.gs0`（`adb devices` 空），修复后 `f1 -> ffs.adb`，
主机**立刻**枚举到设备。

`adb/adbfix.sh`(v20) 与 `adb/usbfix.sh`(v3) 已内置该逻辑（`fix_gadget()`），
并把所有 `setprop sys.usb.config` 从脚本中彻底移除。

### 16.2 三条禁令（都踩过坑）

| 禁令 | 后果 |
|---|---|
| 绝不 `stop adbd` | adbd 卡内核 D 状态，`init.svc.adbd=stopping` 永久，只能重启 |
| 绝不 `setprop sys.usb.config <任意值>` | init 重建 USB 配置 → adbd 被 stop/start → 本机必卡 stopping |
| 绝不快速切换 `adb_enabled` 1→0→1 | 框架重启 adbd，同上 |

adbd 没跑时唯一正确的动作：`setprop ctl.start adbd`，再用 `fix_gadget()` 补 gadget。

### 16.3 无线 adb

需要两个属性：

```bash
setprop persist.adb.tcp.port 5555      # 持久，存于 /data/property/persistent_properties
setprop service.adb.tcp.port 5555      # 运行时，adbd 据此监听 TCP
adb connect <手机IP>:5555
```

**关键认知**：adbd 监听 `0.0.0.0:5555` 与 `wlan0` 有无 IP **无关**，
所以不要等 WiFi 拿到地址再设端口。

**启动慢的真正原因**：原 adbfix 在 `boot_completed` 后死等 `adbd=running` 最多 90 秒，
而 `adb_enabled=0` 时框架根本不会拉起 adbd，于是白等满 90 秒。v20 把无线 adb
段落提到等待之前、等待 90s→20s，实测：

```
18:01:20  adbfix 启动
18:01:26  adb_enabled 0 -> 1 + set service.adb.tcp.port=5555
18:01:28  adbd running, f1=ffs.adb
18:01:28  全部就绪            ← 从启动到双通道可用：8 秒（原 92 秒）
```

### 16.4 GSI 兼容性：三次尝试全部失败

| GSI | 版本 | 卡点 |
|---|---|---|
| LineageOS 18.1 `arm64_bvS` | Android 11 / API 30 | vendor `plat_sepolicy_vers=29.0` 与 API 30 不匹配 → 303 次 `no domain transition`，vendor HAL 全被拒 |
| LineageOS 17.1 `treble_arm64_bvS` | Android 10 / API 29 | SELinux permissive 不阻塞，SF 能起，但 `vendor.hwcomposer-2-1` 每次 `exit(1)` |
| PHH AOSP v222 `arm64-ab` | Android 10 / API 29 | 同上，崩溃服务清单完全一致 |

**共同死因链**：

```
vendor.hwcomposer-2-1 启动 ~145ms exit(1)
  → rc 含 onrestart restart surfaceflinger → init SIGKILL SurfaceFlinger
  → SF 起不来 → system_server 起不来 → boot_completed 永远 0
  → 无 adbd / USB 不枚举 → 回落 TWRP
```

**结论**：魅族 vendor 的 HWC 2.1 实现拒绝在非魅族 system 上加载。
GSI 这条路对本机不可行，必须给 vendor 二进制打补丁。

### 16.5 顺带修好的真 bug：pdx socket 目录缺失

GSI 的 `/system/etc/init/surfaceflinger.rc` 声明：

```
socket pdx/system/vr/display/client   stream 0666 ...
socket pdx/system/vr/display/manager  stream 0666 ...
socket pdx/system/vr/display/vsync    stream 0666 ...
```

AOSP init 不创建中间目录，vendor 也没有对应 `mkdir`，于是：

```
init: Failed to bind socket 'pdx/system/vr/display/client': No such file or directory
```

在 vendor rc 的 `on early-init` 建好该目录后：

```
init: Created socket '/dev/socket/pdx/system/vr/display/client', mode 666 ...
```

**但修好后 composer 仍然 exit(1)** —— 证明 pdx 不是根因。

### 16.6 设备分区与 GSI 选型参考

```
vendor   : Android 10 / SDK 29，plat_sepolicy_vers=29.0，非 VNDK vendor
HAL      : keymaster 3.0、health 2.0、composer 2.1、allocator/mapper 2.0、audio 2.0
分区     : A-only 单槽位；system=sda16(3GB ext4)、vendor=sda17(1GB ext4)、无 product
布局     : system-as-root（/init -> /system/bin/init）
GSI 变体 : 必须 system-as-root（AndyYan `b` / PHH `ab`），`aonly` 不适用
刷入注意 : GSI 是 sparse image，必须 simg2img 转 raw 再 dd
```

### 16.7 `/data` 格式化的连带损失

清 `/data` 会同时丢掉：`/data/misc/adb/adb_keys`、`/data/local/adbfix.sh`+`usbfix.sh`、
`/data/property/persistent_properties`（含 `persist.adb.tcp.port`）、
`/data/adb/modules/*`（Magisk 模块）、`/data/misc/wifi/WifiConfigStore.xml`（WiFi 密码）、
以及 `/sdcard` 全部内容。

> ⚠️ `mokee_color_profile` 被清空会导致 livedisplay HAL 崩 → watchdog 无限重启。
> adbfix 第 1 段就是修这个，务必保留在最前面。