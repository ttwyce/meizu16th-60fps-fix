# 魅族 16th（m1882）死屏设备 —— ADB 开机自愈方案

> 适用场景：**屏幕物理损坏、无触摸输入**的设备。此时 ADB 是唯一交互通道，
> 一旦开机后 adb 不可用，只能依赖 TWRP + 硬件按键。
>
> 因此本方案的核心目标不是"能用"，而是**在 Magisk 出问题时也必须能用**。

---

## 一、架构总览

```
/system/etc/init/zz-adbfix.rc        ← 触发器（init 直接加载，不依赖 Magisk）
        │  on property:sys.boot_completed=1        → start adbfix
        │  on property:sys.usb.state=mtp           → start adbfix
        │  on property:sys.usb.state=mtp,adb       → start adbfix
        ↓
/system/etc/adbfix.sh                ← 149 字节的壳，只做 exec
        ↓
/data/local/adbfix.sh                ← 真正的逻辑（v18，改它不用动 /system）
        ↓
/data/local/usbfix.sh --watch        ← USB/adb 看护（由上面拉起）

/system/etc/init/mokee-adb.rc        ← 只允许 start adbd，禁止 stop（见第六节）
```

**文件清单**

| 路径 | 大小 | 作用 |
|---|---|---|
| `/system/etc/init/zz-adbfix.rc` | 285 B | init 触发器（三个触发条件） |
| `/system/etc/init/mokee-adb.rc` | 437 B | 无线 adb 端口规则；只 start 不 stop |
| `/system/etc/adbfix.sh` | 149 B | 统一入口壳 |
| `/data/local/adbfix.sh` | 5228 B | 主逻辑（颜色配置、重设定、开 adb、USB 推进、看护） |
| `/data/local/usbfix.sh` | 2731 B | USB gadget 自愈（ffs.ready / UDC） |
| `/data/local/tmp/backup/` | — | 上述 rc 与脚本的备份 |

---

## 二、触发文件内容

### 2.1 `/system/etc/init/zz-adbfix.rc`

```
service adbfix /system/bin/sh /system/etc/adbfix.sh
    class main
    user root
    group root system shell
    oneshot
    disabled

on property:sys.usb.state=mtp
    start adbfix

on property:sys.usb.state=mtp,adb
    start adbfix

on property:sys.boot_completed=1
    start adbfix
```

三个触发点的意义：

- `sys.boot_completed=1` —— 系统起来后跑一次（此时 `settings` 服务已可用）
- `sys.usb.state=mtp` / `mtp,adb` —— **USB 模式变化时重新拉起**，插拔线也能自愈

### 2.2 `/system/etc/init/mokee-adb.rc`

```
# adb over network
on property:adb.network.port=*
    setprop service.adb.tcp.port ${adb.network.port}

# [adbfix] 关键：原来这里还有 "stop adbd" 再 "start adbd"。
# adbd 一旦被 stop 就卡在内核 D 状态，init 永远停在 stopping，USB 功能再也注册不回来。
# 所以只允许 start，不允许 stop。
on property:service.adb.tcp.port=5555
    start adbd

on property:service.adb.tcp.port=-1
    start adbd
```

> ⚠️ **这是踩过的坑**：`stop adbd` 会让 adbd 卡在内核 D 状态（不可中断睡眠），
> init 永久停在 `stopping`，之后无论怎么推 `sys.usb.config` 都救不回来，只能重启。

### 2.3 `/system/etc/adbfix.sh`

```sh
#!/system/bin/sh
# 统一入口：真正的逻辑在 /data/local/adbfix.sh（改脚本不用动 /system）
exec /system/bin/sh /data/local/adbfix.sh
```

**设计意图**：`/system` 是只读分区，改一次要 remount rw；把唯一的一行壳放这里，
后续所有调整都改 `/data/local/adbfix.sh`，不需要再动系统分区。

---

## 三、主逻辑 `/data/local/adbfix.sh`（v18）

### 3.1 设计原则

**只做"必要且无害"的事，绝不主动改变屏幕电源状态。**

脚本头部明确声明「本脚本绝不做的事」：

- 不发 `keyevent 223`（灭屏）/ `keyevent 26`（电源键）
- 不把 `sys.usb.config` 写成 `none`
- 不碰 `/data/property/persistent_properties`
- 不碰任何分区、不刷机

### 3.2 执行流程

| 步骤 | 动作 | 说明 |
|---|---|---|
| 0 | 单实例锁 | 锁文件记录 `boot_id` + `pid`，跨重启自动失效；同一 boot 内重复执行直接退出 |
| 1 | 修 `mokee_color_profile` | 该文件为空会导致 livedisplay HAL 崩 → watchdog 无限重启 |
| 2 | 等 `settings` 就绪 | 最多 120 秒轮询 |
| 3 | 屏幕常亮 | `stay_on_while_plugged_in=7`、`screen_off_timeout=1800000`、亮度 200 |
| 4 | 打开 adb | **仅当 `adb_enabled != 1` 时写一次** |
| 5 | 等 adbd 起来 | 最多 90 秒，期间不干预 |
| 6 | 条件式 configfs 推进 | 仅在「adbd 未 running + configfs=1 + 不是 stopping」时做**一次** |
| 7 | 启动 `usbfix.sh --watch` | USB gadget 看护 |
| 8 | 唤醒看护（15 分钟） | **只发 `keyevent 224`（唤醒），绝不灭屏** |

### 3.3 三个历史教训（写在脚本注释里）

1. **删掉了 `KEYCODE_SLEEP(223)` 灭屏守护**
   那是早期为躲"开机动画→桌面"崩溃加的，但真因（color_profile 为空）早已修好。
   它把屏幕一直按在 `Dozing`，而 `Dozing` 时显示管线空闲，只有 1~5fps —— 这是"只有 10fps"的真正元凶。

2. **不发送 `KEYCODE_POWER(26)`**
   电源键 toggle 会破坏 USB gadget / 让 adbd 卡 D 状态，且效果不稳定。

3. **adb 打开改成"温和单次"**
   只在 `adb_enabled != 1` 时写一次；只在 adbd 确实没起来、且 configfs=1、
   且 adbd 不是 `stopping` 时，才做一次 configfs 推进。
   **绝不循环 `setprop sys.usb.config`**（会和框架抢 USB 配置）。

---

## 四、USB 自愈 `/data/local/usbfix.sh`

### 4.1 要修的已知故障

```
sys.usb.config 的 none 分支会 setprop sys.usb.ffs.ready 0；
之后 config 回到 adb 时，init 规则要求 ffs.ready=1 才写 UDC，
而 adbd 若没重启就不会把 ready 置回 1
→ USB gadget 永不挂载（但 adbd 进程还活着）
```

### 4.2 只做两件事（都有严格前置条件）

- **A**：`adbd=running` + 已有 ffs 端点 + `ffs.ready=0` → 补 `ffs.ready=1`
- **B**：上面修完 UDC 仍为空 + `configfs=1` → 推一次 `sys.usb.config=adb`

### 4.3 安全约束

- `adbd=stopping` 时**什么都不做**（D 状态，推了只会更糟）
- 两次动作至少间隔 **30 秒**（限流）
- 不发 keyevent、不碰分区

---

## 五、为什么用 init rc，而不是做成 Magisk 模块

这是本方案最重要的设计决策。

| 维度 | init rc（当前方案） | Magisk 模块 |
|---|---|---|
| 依赖 Magisk | **不依赖**，init 直接加载 | 依赖 Magisk 正常运行 |
| bootloop 保护 | 不受影响 | **Magisk 会自动禁用"可疑模块"** |
| 触发时机 | 三个条件，USB 变化会重拉 | 仅开机跑一次（`service.sh`） |
| 修改难度 | 需 remount rw；但逻辑在 `/data` 所以很少要改 | 易装易卸 |
| 抗 OTA / 刷机 | 会被覆盖（已有备份） | 保留 |

**核心原因**：这台机器没有屏幕、没有触摸，**adb 断了就只能拆机上 TWRP**。
把生命线交给一个"检测到开机循环就会自动禁用模块"的机制，风险不可接受。

**实证**：某次启动 `adbd=stopped usb=none`、`adb_enabled=0`，当时
`/data/adb/service.d/` 是**空的**、`EnableADB` 模块是**禁用的**——
完全是 init rc 在 19:44:36 把 `adb_enabled` 从 0 改回 1、19:44:38 拉起 adbd。

> `EnableADB` 模块是早期遗留的废弃包装（内容只有一行 `exec /data/local/adbfix.sh`），
> 保持禁用或删除均可，不影响功能。

### 可选冗余

如需额外保险，可加 `/data/adb/service.d/adbfix-fallback.sh`：

```sh
#!/system/bin/sh
exec /system/bin/sh /data/local/adbfix.sh
```

`adbfix.sh` 自带 `boot_id` 单实例锁，同一 boot 内重复执行第二次会直接退出，**不会冲突**。
作用：万一 `/system` 被刷机覆盖，Magisk 这边还能兜底。

---

## 六、故障排查手册

### 症状 1：重启后 adb 完全没了（USB 也不通）

按顺序查：

```sh
# 1. USB 配置是否被设为 none（这会整体关掉 USB，adb 一起没了）
adb shell getprop persist.sys.usb.config      # 正常应为 adb

# 2. adb 开关
adb shell settings get global adb_enabled     # 正常应为 1

# 3. adbd 是否在跑
adb shell getprop init.svc.adbd               # 正常应为 running

# 4. USB 状态
adb shell getprop sys.usb.state               # 正常应为 adb
```

- `persist.sys.usb.config=none`：在系统里把 USB 用途改为"传输文件"，
  或 `setprop persist.sys.usb.config adb`，然后重新插线
- `adb_enabled=0`：`settings put global adb_enabled 1`
- `init.svc.adbd=stopping`：**不要 `stop adbd`**，卡 D 状态只能重启

**查看自愈脚本是否执行过**：

```sh
adb shell su -c "tail -30 /data/local/tmp/adbfix.log"
```

正常日志形如：

```
=== start bootid=... persist=adb adbd= usb=mtp boot= ===
mokee_color_profile ok: [0]
settings ready after 4s
stayon: stay_on=7 timeout=1800000
adb_enabled: 0 -> 1
adbd running after 2s, usb=adb
usbfix watch started
```

### 症状 2：adb 在跑，但 USB 插上无反应

说明 USB gadget 没挂上（ffs.ready 被清零 / UDC 为空）：

```sh
adb shell su -c "cat /sys/class/udc/*/state 2>/dev/null; cat /config/usb-gadget/g1/UDC"
adb shell sh /data/local/usbfix.sh          # 手动跑一次（脚本自带 30 秒限流）
```

### 症状 3：无线 adb（5555）连不上

```sh
adb shell getprop service.adb.tcp.port      # 应为 5555
adb shell getprop persist.adb.tcp.port
```

`mokee-adb.rc` 会在 `service.adb.tcp.port=5555` 时 `start adbd`（**不会 stop**）。

### 症状 4：`/system` 被刷机覆盖，触发器丢失

从备份还原：

```sh
adb shell su -c "mount -o rw,remount /system"
adb shell su -c "cp /data/local/tmp/backup/zz-adbfix.rc   /system/etc/init/"
adb shell su -c "cp /data/local/tmp/backup/mokee-adb.rc   /system/etc/init/"
adb shell su -c "cp /data/local/tmp/backup/adbfix.sh      /system/etc/"
adb shell su -c "chmod 644 /system/etc/init/zz-adbfix.rc /system/etc/init/mokee-adb.rc"
adb shell su -c "chmod 755 /system/etc/adbfix.sh"
adb shell su -c "mount -o ro,remount /system"
adb reboot
```

备用副本：`/data/local/tmp/adbfix_v18.sh`

---

## 七、附：Zygisk / LSPosed 注意

LSPosed（`zygisk_lsposed` v2.2.0）的 `module.prop` 明确写着 **"Requires Zygisk enabled"**。

检查是否真的生效：

```sh
adb shell 'ps -A | grep lspd'                       # 应有 lspd 进程
adb shell su -c "magisk --sqlite \"SELECT * FROM settings\""   # zygisk|value=1
```

若 `zygisk|value=0` 则 LSPosed **装了也完全不工作**，需在 Magisk 设置里开启 Zygisk 再重启。

> 开启 Zygisk 会改变 system_server 的加载方式，有一定概率导致启动异常。
> Magisk 自带 bootloop 保护（`key=bootloop`）会自动禁用可疑模块，
> 但请注意本方案的生命线（adb）不依赖 Magisk，因此即使 Zygisk 出问题，adb 仍然可用。

---

## 八、快速自检清单

```sh
# 一键检查（全部正常应输出全绿）
adb shell '
  echo "usb.config = $(getprop persist.sys.usb.config)"
  echo "adb_enabled = $(settings get global adb_enabled)"
  echo "adbd        = $(getprop init.svc.adbd)"
  echo "usb.state   = $(getprop sys.usb.state)"
  echo "trigger     = $(ls /system/etc/init/zz-adbfix.rc 2>/dev/null || echo MISSING)"
  echo "logic       = $(ls -l /data/local/adbfix.sh 2>/dev/null | awk "{print \$5}")B"
'
```

期望：

```
usb.config = adb
adb_enabled = 1
adbd        = running
usb.state   = adb
trigger     = /system/etc/init/zz-adbfix.rc
logic       = 5228B
```
---

## 九、★ 深挖：USB adb 为什么会失效（2026-11-10 晚）

> 这是本方案最隐蔽的一个坑，症状是：**无线 adb 正常，USB adb 却没有**。

### 9.1 症状

```
adb devices  →  只有 192.168.31.212:5555 device，没有 USB 序列号
设备端 adbd 进程健康（持有 /dev/usb-ffs/adb/ep0,ep1,ep2）
设备端 sys.usb.config / sys.usb.state 都写着 "adb"
但 Windows 只认到 WPD「16th」（MTP），没有 ADB 接口
```

### 9.2 真正的机制：`adb` 配置规则是"半残"的

配置文件 `/vendor/etc/init/hw/init.msm.usb.configfs.rc` 里有**两类**规则。

**A 类 —— 真正构建 gadget**（条件含 `sys.usb.ffs.ready=1`），例如 `mtp,diag,adb`：

```
on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,diag,adb && property:sys.usb.configfs=1
    write .../configs/b.1/strings/0x409/configuration "mtp_diag_adb"
    rm .../configs/b.1/f1  ...  f9          ← 先清空所有功能
    write .../idVendor  0x05C6
    write .../idProduct 0x903A
    symlink .../functions/mtp.gs0   .../f1
    symlink .../functions/diag.diag .../f2
    symlink .../functions/ffs.adb   .../f3   ← 关键：ADB 功能
    write .../UDC ${sys.usb.controller}
    setprop sys.usb.state ${sys.usb.config}
```

**B 类 —— 只改 VID/PID，什么都不构建**（第 1034、1043 行）：

```
on property:sys.usb.config=adb && property:sys.usb.configfs=1
    write .../idVendor  0x2A45
    write .../idProduct 0x0C01
    ← 到此结束：不清空 f1~f9、不 symlink ffs.adb、不写 UDC、不设 state

on property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1
    write .../idVendor  0x2A45
    write .../idProduct 0x0C02
    ← 同样只有两行
```

**关键事实**：把全系统 rc 里所有 `symlink .../functions/ffs.adb` 都列出来（共 24 处），
**没有任何一处属于 `adb` 或 `mtp,adb`**。它们都属于 `mtp,diag,adb`、`diag,adb`、
`ccid,adb`、`mass_storage,adb`、`rndis,...` 等组合。

### 9.3 于是失效是这样发生的

```
setprop sys.usb.config adb
   ↓
只触发 B 类规则 → idProduct 变成 0x0C01（对外"声称"是 adb）
   ↓
但 B 类规则不清空 f1~f9
   ↓
如果之前残留着 mtp.gs0（例如刚用过 MTP），它就留在 f1
   ↓
最终描述符 = PID 0x0C01 + MTP 接口，没有 ADB 接口
   ↓
主机看不到 adb；而 adbd 进程仍健康，端点也在
```

**这就是"看起来一切正常、但 USB adb 就是不通"的原因。**

### 9.4 为什么冷启动有时能通、热重启不通

- **干净冷启动**：gadget 从零构建，框架/HAL 会把 `f1` 正确设成 `ffs.adb` → adb 可用
- **热重启后**：gadget 里可能残留上次的 `mtp.gs0`，此时再 `setprop sys.usb.config adb`
  只改 PID 不清功能 → 变成"声称 adb、实际 MTP" → adb 失效

### 9.5 修复：改用带完整构建规则的组合

`mtp,diag,adb` 是**唯一同时含 MTP 和 ADB、且有完整 A 类规则**的组合：

```
setprop sys.usb.ffs.ready 1
setprop sys.usb.config mtp,diag,adb
   ↓
rm f1..f9 → symlink mtp.gs0/ diag.diag / ffs.adb → 写 UDC
   ↓
VID/PID = 0x05C6 / 0x903A，配置名 mtp_diag_adb
   ↓
Windows 同时认到三个接口：
  MI_00  WPD「16th」                      (MTP)
  MI_01  Qualcomm HS-USB Diagnostics 903A (COM3, diag)
  MI_02  Android Composite ADB Interface   (ADB)
```

已把两个脚本里的裸 `adb` 全部改为 `mtp,diag,adb`：

| 文件 | 行 | 原值 | 现值 |
|---|---|---|---|
| `/data/local/adbfix.sh` | 107 | `setprop sys.usb.config adb` | `setprop sys.usb.config mtp,diag,adb` |
| `/data/local/usbfix.sh` | 66 | `setprop sys.usb.config adb` | `setprop sys.usb.config mtp,diag,adb` |

备份：`/sdcard/adbfix_backup/adbfix_v18_before_usbfix.sh`、`usbfix_v2_before_usbfix.sh`

### 9.6 附带发现：MTP 控制打不开

实测热重启后框架日志：

```
UsbDeviceManager: Failed to open control for mtp
UsbDeviceManager: Failed to open control for ptp
UsbDeviceManager: Setting USB config to adb
```

MTP/PTP 的 HAL 控制端打开失败，框架因此退回 `adb` 单功能配置。
结果是 **ADB 可用、MTP 不可用**（Windows 里看不到 WPD 设备）。

> 若需要 MTP，可手动 `setprop sys.usb.config mtp,diag,adb`
> （该组合会强制清空并重建 gadget，三者同时具备）。

### 9.7 排查命令速查

```bash
# 1) 看属性（注意：属性可能与实际不一致，必须看 gadget）
adb shell 'getprop sys.usb.config; getprop sys.usb.state'

# 2) 看 gadget 真实内容（权威）
adb shell 'ls -l /config/usb_gadget/g1/configs/b.1/ | grep "^l"'
#   期望看到 ffs.adb 的 symlink；若只有 mtp.gs0 → ADB 接口不存在

# 3) 看 VID/PID 判断走了哪条规则
adb shell 'cat /config/usb_gadget/g1/idVendor; cat /config/usb_gadget/g1/idProduct'
#   0x2A45/0x0C01 = adb 的 B 类规则（危险，不清功能）
#   0x2A45/0x0C02 = mtp,adb 的 B 类规则（同样危险）
#   0x05C6/0x903A = mtp,diag,adb 的 A 类规则（完整重建，安全）

# 4) 看 UDC 是否绑定
adb shell 'cat /config/usb_gadget/g1/UDC; cat /sys/class/udc/*/state'
#   应为 a600000.dwc3 且 state=configured
```

### 9.8 教训

1. **不要相信 `sys.usb.config` / `sys.usb.state` 属性**——它们可能只反映"想配什么"，
   不反映 gadget 里"实际有什么"。**权威来源永远是 configfs 里的 symlink。**
2. **改 USB 配置前先看该配置有没有"完整构建规则"**。
   只有"设 VID/PID"两行的配置（`adb`、`mtp,adb`）依赖 gadget 已有正确功能，
   在残留状态下会把 USB 弄坏。
3. **热重启和冷启动的 USB 初始化路径不同**。热重启会保留 gadget 状态，
   冷启动从零开始。这类差异要单独测。
