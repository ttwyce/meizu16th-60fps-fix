# 魅族 16th（m1882）碎屏后桌面 60fps 修复

> **最终定版：V43**（2026-11-10）｜镜像 md5 `d03680624bcbb14f755317a15d907156`

碎屏（DSI command mode 面板不再返回 PP_TX_DONE / TE 中断）导致 2fps，
通过修改内核二进制让 vsync 改由 MDP 硬件看门狗定时器按 60Hz 生成，恢复桌面 60fps。

## 结果

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 桌面持续滚动 | 2 fps | **60 fps** |
| 停止后再滑动 | 20~28 fps（卡） | **61~62 fps** |
| 浏览器（Via）滚动 | 0 fps / 死锁 | **53~60 fps** |
| 内核错误 | 每帧超时 | **全 0** |

## 关键补丁（4 类，均在原厂 Image 上二进制修改）

| 地址 | 改动 | 作用 |
|---|---|---|
| `0x56A94C` / `0x56A83C` | V20 两点 | 抑制 PANEL_DEAD / 降级 |
| `0x55E478` | `ldrb→mov w4,#1` | vsync 源改看门狗定时器（不依赖坏面板 TE） |
| `0x566864`+`0x56A0E8` | 代码洞 | 合成 frame_done(0x9) + 递减 kickoff 计数 |
| `0x56AE64` | `movn w20,#-110 → movz w20,#0` | ctl_start 超时后 commit 继续，避免 retire 槽溢出 |

> 三层根因、V3~V43 全部版本演进、失败原因、验证数据、测量陷阱
> 详见 `docs/魅族16th死屏60fps修复_完整技术文档.md` 与 `docs/尝试追踪链.md`。

## 使用

```bash
adb push images/boot_v43.img /sdcard/boot_v43.img
adb shell su -c "dd if=/sdcard/boot_v43.img of=/dev/block/bootdevice/by-name/boot bs=4096"
adb shell su -c sync && adb reboot
```

验证：`dmesg | grep -c "wait for vblank failed"` 应为 0；滑动时 vsync 计数 ≈60/s。

## 注意

- 仅针对**屏幕已物理损坏**、已解锁、已 root 的设备。
- 刷 boot 有风险，先备份原厂 `boot.img` / `dtbo`，确认能进 TWRP。
- 静止时 SF 进 Idle 属正常省电行为，有动画/滑动即回 60fps。
- 详见 `docs/魅族16th死屏60fps修复_完整技术文档.md` 第 11 章（V38→V43 迭代）与 11.5 测量陷阱。

## 结构

```
README.md
docs/魅族16th死屏60fps修复_完整技术文档.md   ← 完整技术文档（11章）
docs/尝试追踪链.md                            ← 40节完整调试史
docs/目录结构说明.md
patch/patch_v38.py                            ← 补丁生成脚本（V38 基线，路径按本地结构调整）
images/boot_v43.img                           ← 最终可刷镜像
images/Image_v43.img                          ← 补丁后内核 Image
```