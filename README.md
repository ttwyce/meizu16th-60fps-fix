# 魅族 16th（m1882）碎屏后 60fps 修复

> **最终定版：V53**（2026-11-10）｜镜像 md5 `f26c9525cacf934b17f74d9ac96ba874`
>
> 面板物理损坏（DSI command mode）后系统只剩 2fps。通过 8 处内核二进制补丁，
> 恢复桌面 60fps，**本次开机 `sde error` 数为 0**，实际使用丝滑。

---

## 一、结果

| 场景 | 修复前 | **V53** |
|---|---|---|
| 桌面滚动 / 日常使用 | 2 fps | **丝滑，vblank 58~60fps** |
| 画面内容 | 黑屏 | **968/968 采样点非黑** |
| 内核 `sde error` | 每帧超时 | **0** |
| retire event overflow / without kickoff | 反复出现 | **0** |
| GPU syncpoint deadlock | 导致 0fps | **0** |
| ctl_start 超时 | 每帧 84ms | **0** |
| PANEL_DEAD / timeline reset / esd check failed | 用几分钟就黑屏 | **0** |
| resource kickoff / clk control / VBIF not halting | 状态机错乱重启 | **0** |

---

## 二、根因（四个层次，缺一不可）

### 2.1 PP_TX_DONE 丢失 → fence 无人释放
面板正常时每帧回报 `PP_TX_DONE`，驱动在 `sde_encoder_phys_cmd_pp_tx_done_irq()`
里释放 retire/release fence 并递减 `pending_kickoff_cnt`。面板损坏后中断不来 →
fence 无人释放 + 每帧等满 84ms 超时 → 2fps。

### 2.2 vsync 源指向已坏的面板 TE
驱动兜底函数 `_sde_encoder_switch_to_watchdog_vsync()` 只修改了 `disp_info` 的**局部副本**，
`sde_enc->disp_info.is_te_using_watchdog_timer` 仍为 false，下一帧又设回坏面板 TE。

### 2.3 ctl_start 中断缺失 → commit 失败
`wait_for_ctl_start` 等 `pending_ctlstart_cnt`，中断不来则等满 84ms 并返回
`-ETIMEDOUT` → commit 失败 → retire 槽堆积。

### 2.4 ★ ESD 检测失败 → PANEL_DEAD → fence 时间线重置（最终真凶）
```
esd check failed report PANEL_DEAD (conn26/enc25)
  → DRM_EVENT_PANEL_DEAD
  → sde_encoder_display_failure_notification()
  → 显示管线重启 + fence timeline reset
  → GPU 等待的 fence 序号被清零 → syncpoint deadlock → 黑屏 0fps
```
坏屏下 ESD 的任何模式（`reg_read` / `te_signal_check` / `err_fg_gpio`）都必然失败，
只能彻底禁用。**这是早期版本"用几分钟就变黑"的真正原因。**

---

## 三、终极方案：守卫式完成代码洞

面板不会再回报完成，只能在 `trigger_start` 处伪造。关键在于**必须复刻驱动
`pp_tx_done_irq` 的守卫语义**——每步都用 `atomic_add_unless(…,-1,0)`，
计数器为 0 时什么都不做：

```
0x566864  代码洞（33 条指令）
  mov  x19, x0                     // phys_enc
  // 1) retire 计数 >0 才发 RETIRE
  ldaxr/stxr 递减 [x19+0x294]  →  frame_done(0x1)
  // 2) ctlstart 计数 >0 才递减
  ldaxr/stxr 递减 [x19+0x28C]
  // 3) 无条件发 DONE|RELEASE
  frame_done(0x18)
  // 4) kickoff 计数 >0 才递减
  ldaxr/stxr 递减 [x19+0x290]
  ret
```

> 早期版本是**无条件**发事件，导致记账错位（漏记/多记/队列永不释放），
> 这就是 V38~V49 全部失败的共同原因。

---

## 四、V53 补丁清单（镜像 diff 生成）

| # | 地址 | 原厂 | V53 | 作用 |
|---|---|---|---|---|
| 1 | `0x55E478` | `3940C6A4` | `52800024` | vsync 源强制改看门狗定时器 |
| 2 | `0x566864`~`0x5668E3` | — | 33 条指令 | 守卫式完成代码洞 |
| 3 | `0x56A0E8` | `97FFD76C` | `97FFF1DF` | `trigger_start` 中 `bl` 到代码洞 |
| 4 | `0x56A83C` | `52800081` | `52800061` | enable_state 4→3 |
| 5 | `0x56A94C` | `528001C2` | `52800142` | 抑制 PANEL_DEAD 事件位 |
| 6 | `0x56AE64` | `12800DB4` | `52800014` | ctl_start 超时返回 0 |
| 7 | `0x584350` | `A9BD7BFD` | `D65F03C0` | `_sde_connector_report_panel_dead` → ret |
| 8 | `0x5854CC` | `A9B87BFD` | `D65F03C0` | `sde_connector_schedule_status_work` → ret |

> 代码洞覆盖的是 `_sde_encoder_phys_vid_wait_for_vblank`（**video 模式**专用函数）。
> 本机为 command mode 面板，该路径永不执行，因此安全。

---

## 五、⚠️ 三条踩过的坑（给后来者）

**① 不要用 vsync 计数器当帧率。**
`/sys/kernel/debug/dri/0/encoder25/status` 的 vsync 计数由看门狗定时器独立驱动，
**黑屏时照样显示 60**。本项目因此连续多个版本"测试通过"实为黑屏。
正确验证：`scrcpy --print-fps` + `screencap` 像素采样 + `dmesg` 零错误，三者缺一不可。

**② 不要在持锁区调用会再次取同一把锁的函数。**
`sde_encoder_kickoff` 持有 `&sde_enc->enc_spinlock` 调用 `trigger_start`；
而 `phys_enc->enc_spinlock` 就是**同一把锁**（sde_encoder.c:4783）。
在 hook 点调用 `pp_tx_done_irq` 会自死锁 → 无限重启。

**③ 不要对资源控制状态机撒谎。**
把 `wait_for_idle` 改成恒返回 0 会让它以为硬件已空闲、提前进入 IDLE 态，
之后 KICKOFF 撞 `EBUSY`、VBIF 无法 halt（`not halting. TIMEDOUT`）。

---

## 六、使用

```bash
adb push images/boot_v53.img /sdcard/boot_v53.img
adb shell su -c "dd if=/sdcard/boot_v53.img of=/dev/block/bootdevice/by-name/boot bs=4096"
adb shell su -c sync
adb reboot
```

验证：
```bash
adb shell 'dmesg | grep -c "sde error"'          # 应为 0
adb shell 'cat /sys/kernel/debug/dri/0/crtc111/status | grep "vblank fps"'   # 58~60
```

**回退**：刷回原厂 `boot.img`（请自备备份，确认能进 TWRP）。

---

## 七、仓库结构

```
README.md
docs/魅族16th死屏60fps修复_完整技术文档.md   ← 14 章完整技术文档（含排错附录）
docs/尝试追踪链.md                            ← 43 节逐版本调试史（V3~V53）
docs/目录结构说明.md
patch/patch_v38.py                            ← 早期补丁生成脚本（历史参考）
images/boot_v53.img                           ← ★ 最终可刷镜像
images/Image_v53.img                          ← 最终内核 Image
```

---

#---

## 八、常见问题

### Q1. 浏览器能上网但打不开网页 / 直接闪退

**不是网络问题。** 检查是不是 `/sys/kernel/debug` 的权限被改坏了：

```bash
adb shell ls -ld /sys/kernel/debug
# 正确应为 drwxr-xr-x (0755)，即 init.qcom.rc 里 chmod 0755 的设定
# 若为 drwx------ (0700)：WebView 渲染进程必然崩溃
adb shell 'logcat -d | grep "Abort message"'   # 会看到 trace_marker Permission denied
adb shell su -c "chmod 0755 /sys/kernel/debug"
```

**根源**：任何对 `/sys/kernel/debug` 执行 `mount -o rw,remount` 的操作，都会把
debugfs 根目录权限重置为内核默认的 `0700`。随后 zygote fork WebView 渲染进程时，
需要按子进程 uid 重新 open 已继承的 `/sys/kernel/debug/tracing/trace_marker`，
0700 导致 EACCES → Android 视为致命错误（`JNI FatalError`）→ abort →
渲染进程建不起来 → 浏览器白屏/闪退。

> 因此：**不要 remount debugfs**。本方案不需要任何额外开机脚本。

### Q2. 误杀了 `webview_zygote` 怎么办

它**不是 init 服务**，是主 zygote 按需 fork 的子 zygote。`kill -9` 之后
`start webview_zygote` 无效、init 不会重启它、框架 socket 缓存也已失效 ——
**只能重启设备**。重启后再 `am force-stop` 一次浏览器进程清掉残留状态。

### Q3. 判断"是不是白屏"

无 GUI 时可截图做颜色统计：整屏纯白占比 >90%、颜色种类 <200 基本可断定没渲染出来；
正常网页通常 >500 种颜色。

# 九、免责声明

- 仅针对**屏幕已物理损坏**、已解锁引导、已 root 的设备。正常设备无需也无益。
- 刷写 boot 分区有风险，请先备份原厂 `boot.img` / `dtbo`，确认能进 TWRP。
- 静止时帧率下降属 Android 正常省电行为（SurfaceFlinger Idle），有动画/滑动即回升。
- 在魅族 16th（m1882 / MoKee 10 / 内核 4.9.65-perf+）验证，其他机型不保证适用。