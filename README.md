# 魅族 16th（m1882）碎屏后桌面 60fps 修复

> **最终定版：V45**（2026-11-10）｜镜像 md5 `565d5a9e78fca3b16661ef73a3a219e1`
>
> 碎屏（DSI command mode 面板损坏）导致系统只有 2fps。
> 通过 6 处内核二进制补丁 + 1 个 ESD 脚本，恢复桌面 60fps，画面正常、内核零错误。

---

## 一、结果

| 场景 | 修复前 | **V45** |
|---|---|---|
| 桌面持续滚动 | 2 fps | **峰值 60~66 fps**（平均 40~50，含手势间隙） |
| 停止后再滑动 | 20~28 fps（卡） | 流畅 |
| 打开浏览器 / 日历 | 0 fps / 黑屏 / GPU 死锁 | 正常 |
| 画面内容 | 黑屏 | **968/968 采样点非黑 ✓** |
| PANEL_DEAD / timeline reset / ctl 超时 / GPU deadlock | 反复出现 | **全部 0** |
| 连续运行 | 几分钟后变黑 | **420 秒零错误**（持续验证中） |

---

## 二、根因（多因叠加，必须全部解决）

### 2.1 PP_TX_DONE 丢失 → fence 不释放

command mode 面板正常时每帧回报 `PP_TX_DONE`，驱动在
`sde_encoder_phys_cmd_pp_tx_done_irq()` 里释放 retire/release fence 并递减
`pending_kickoff_cnt`。面板损坏后中断不来 → fence 无人释放 + 每帧等满超时 → 2fps。

### 2.2 vsync 源指向已坏的面板 TE

```c
vsync_cfg.vsync_source = cur_master->hw_pp->caps->te_source;   /* 面板TE，已坏 */
if (disp_info->is_te_using_watchdog_timer)
    vsync_cfg.vsync_source = SDE_VSYNC_SOURCE_WD_TIMER_0;      /* 看门狗定时器 */
```

驱动的兜底 `_sde_encoder_switch_to_watchdog_vsync()` 只改了**局部副本**
（`memcpy` 到 `disp_info` 后改），`sde_enc->disp_info` 仍为 false，
下一帧又设回坏面板 → 每帧烧 200ms。

### 2.3 ctl_start 中断缺失 → commit 失败 → retire 记账错乱

`wait_for_ctl_start` 等 `pending_ctlstart_cnt`，中断不来则等满 84ms 并返回 `-ETIMEDOUT`
→ commit 失败 → retire event 槽堆积 → `retire event overflow`。

### 2.4 ★ ESD 检测失败 → PANEL_DEAD → fence 时间线重置（最终真凶）

```
esd check failed report PANEL_DEAD (conn26/enc25)
  → DRM_EVENT_PANEL_DEAD
  → sde_encoder_display_failure_notification()
  → 显示管线重启 + fence timeline reset
  → GPU 等待的 fence 序号被清零 → syncpoint deadlock
  → vblank 被关闭 → SF 停止合成 → 黑屏 / 0fps
```

坏屏下 ESD 的**任何模式**（`reg_read` / `te_signal_check` / `err_fg_gpio`）都必然失败，
只能彻底禁用。这是之前 V38~V44「用一会儿就变黑」的真正原因。

---

## 三、V45 补丁清单（6 处）

| # | 地址 | 改动 | 作用 |
|---|---|---|---|
| 1 | `0x56A94C` / `0x56A83C` | `0x528001C2→0x52800142` / `0x52800081→0x52800061` | 抑制 PANEL_DEAD 事件位、防状态机降级 |
| 2 | `0x55E478` | `ldrb w4,[x21,#0x31] → mov w4,#1` | vsync 源强制改为 MDP 看门狗定时器 |
| 3 | `0x566864` + `0x56A0E8` | 代码洞（17 条）+ `bl` | 合成 `frame_done(0x9)` 并递减 `pending_kickoff_cnt` |
| 4 | `0x56AE64` | `movn w20,#0x6d → movz w20,#0` | ctl_start 超时后 commit 继续，避免 retire 槽溢出 |
| 5 | `0x5854CC` | `stp → ret` | **`sde_connector_schedule_status_work` 直接返回，ESD 检查永不调度** |
| 6 | `0x584350` | `stp → ret` | **`_sde_connector_report_panel_dead` 直接返回，PANEL_DEAD 不上报** |

> 第 3 处代码洞覆盖的是 `_sde_encoder_phys_vid_wait_for_vblank`（**video mode** 函数）。
> 本机为 command mode 面板，该路径永不执行，因此安全。

另附 `scripts/esdfix.sh`：Magisk `service.d` 脚本，把 debugfs `esd_check_mode` 设为
`te_signal_check`，作为第三层保险。

---

## 四、⚠️ 排查中最大的坑：测量方法

**不要用 `encoder25/status` 的 vsync 计数判断帧率。**

该计数器由看门狗定时器以 60Hz 独立驱动，**即使在黑屏、SF 完全不合成时也显示 60**。
本项目曾因此连续多个版本"测量通过"实为黑屏，误判了很久。

正确验证必须同时满足：

```bash
# 1) 真实帧率（最接近人眼观感）
scrcpy --print-fps --no-audio

# 2) 画面内容（判断黑屏的唯一可靠手段）
adb shell screencap -p /sdcard/x.png && adb pull /sdcard/x.png
#    然后检查像素是否全黑

# 3) 内核错误必须为 0
adb shell 'dmesg | grep -cE "PANEL_DEAD|timeline reset|ctl start|syncpoint deadlock|retire event overflow"'
```

---

## 五、使用

```bash
# 1. 刷入内核
adb push images/boot_v45.img /sdcard/boot_v45.img
adb shell su -c "dd if=/sdcard/boot_v45.img of=/dev/block/bootdevice/by-name/boot bs=4096"
adb shell su -c sync
adb reboot

# 2.（可选，双保险）安装 ESD 脚本
adb push scripts/esdfix.sh /sdcard/esdfix.sh
adb shell su -c "mkdir -p /data/adb/service.d && cp /sdcard/esdfix.sh /data/adb/service.d/ && chmod 755 /data/adb/service.d/esdfix.sh"
```

**回退**：刷回原厂 `boot.img` 即可（请自备备份，且确认能进 TWRP）。

---

## 六、仓库结构

```
README.md
docs/魅族16th死屏60fps修复_完整技术文档.md   ← 12 章完整技术文档（含根因、验证、测量陷阱）
docs/尝试追踪链.md                            ← 41 节逐版本调试史（V3~V45 全部记录）
docs/目录结构说明.md
patch/patch_v38.py                            ← 补丁生成脚本（V38 基线，路径需按本地调整）
scripts/esdfix.sh                             ← ESD 检查模式修复脚本（Magisk service.d）
images/boot_v45.img                           ← ★ 最终可刷镜像
images/Image_v45.img                          ← 最终内核 Image
```

---

## 七、免责声明

- 仅针对**屏幕已物理损坏**、已解锁引导、已 root 的设备。正常设备无需也无益。
- 刷写 boot 分区有风险，请先备份原厂 `boot.img` / `dtbo`，确认能进 TWRP。
- 静止时帧率降到个位数属 Android 正常省电行为（SurfaceFlinger Idle），有动画/滑动即回升。
- 本方案在魅族 16th（m1882 / MoKee 10 / 内核 4.9.65-perf+）上验证，其他机型不保证适用。