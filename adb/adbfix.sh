#!/system/bin/sh
# ============================================================================
# 魅族16th 死屏 —— 开机自愈脚本（v18）
#
# 【设计原则】只做"必要且无害"的事，绝不主动改变屏幕电源状态。
#
# 【本版相对历史版本的关键修正】
#  1) 彻底删除 KEYCODE_SLEEP(223) 灭屏守护
#     —— 那是我 11-03 自己加的（为躲"开机动画->桌面"崩溃），
#        但该崩溃真因（color_profile 为空）早已修好。
#        它把屏幕一直按在 Dozing，而 Dozing 时显示管线空闲，只有 1~5fps。
#        这是"帧率只有 10fps"的真正元凶。用户从未要求过这个功能。
#  2) 不发送 KEYCODE_POWER(26)
#     —— 电源键 toggle 会破坏 USB gadget / 让 adbd 卡 D 状态，且效果不稳定。
#  3) adb 打开改成"温和单次"：
#     —— 只在 adb_enabled != 1 时写一次；只在 adbd 确实没起来、
#        且 configfs=1、且 adbd 不是 stopping 时，才做一次 configfs 推进。
#        绝不循环 setprop sys.usb.config（那会和框架抢 USB 配置）。
#  4) 锁用 boot_id 判重，跨重启自动失效（修掉 v15 的"陈旧锁"导致脚本不执行）。
#  5) 只唤醒(224)，绝不灭屏；屏幕常亮靠 stay_on_while_plugged_in。
#
# 【本脚本绝不做的事】（便于审核）
#   - 不发 keyevent 223 / 26
#   - 不写 sys.usb.config 到 none
#   - 不碰 /data/property/persistent_properties
#   - 不碰任何分区、不刷机
# ============================================================================
LOG=/data/local/tmp/adbfix.log
LOCK=/data/local/tmp/adbfix.lock

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

BOOTID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)

# ---- 单实例锁（同一 boot 内才判重）----
if ! mkdir "$LOCK" 2>/dev/null; then
  lpid=$(cat "$LOCK/pid" 2>/dev/null)
  lboot=$(cat "$LOCK/boot" 2>/dev/null)
  if [ -n "$lpid" ] && [ "$lboot" = "$BOOTID" ] && kill -0 "$lpid" 2>/dev/null; then
    log "dup instance in same boot (pid $lpid), exit"; exit 0
  fi
  log "stale lock (pid=$lpid boot=$lboot), taking over"
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"
echo "$BOOTID" > "$LOCK/boot"
trap 'rm -rf "$LOCK"' EXIT

log "=== start bootid=$BOOTID persist=$(getprop persist.sys.usb.config) adbd=$(getprop init.svc.adbd) usb=$(getprop sys.usb.state) boot=$(getprop sys.boot_completed) ==="

# ---- 1) color_profile 不能为空（空 -> livedisplay HAL 崩 -> watchdog 无限重启）----
P=/data/vendor/display/mokee_color_profile
mkdir -p /data/vendor/display 2>/dev/null
if [ ! -s "$P" ]; then
  echo 0 > "$P"
  chown system:system "$P" 2>/dev/null
  chmod 600 "$P" 2>/dev/null
  log "FIX: mokee_color_profile empty -> wrote 0"
else
  log "mokee_color_profile ok: [$(head -c 20 "$P" | tr -d '\n')]"
fi

# ---- 2) 等 settings 服务就绪（最多 120s）----
i=0
while [ $i -lt 60 ]; do
  settings get global adb_enabled >/dev/null 2>&1 && break
  sleep 2; i=$((i+1))
done
log "settings ready after $((i*2))s"

# ---- 3) 屏幕常亮设置（不灭屏，只保持亮）----
# 注意：设置里屏幕超时最高只有 30 分钟，所以真正保底靠 stay_on_while_plugged_in=7
settings put global stay_on_while_plugged_in 7
settings put system screen_off_timeout 1800000
settings put system screen_brightness_mode 0
settings put system screen_brightness 200
svc power stayon true
log "stayon: stay_on=$(settings get global stay_on_while_plugged_in) timeout=$(settings get system screen_off_timeout)"

# ---- 4) 打开 adb（温和、单次、有条件）----
cur_adb=$(settings get global adb_enabled 2>/dev/null)
if [ "$cur_adb" != "1" ]; then
  settings put global adb_enabled 1
  log "adb_enabled: $cur_adb -> 1"
else
  log "adb_enabled already 1"
fi

# 等 adbd 起来（最多 90s，不干预）
n=0
while [ $n -lt 45 ]; do
  if [ "$(getprop init.svc.adbd)" = "running" ]; then
    log "adbd running after $((n*2))s, usb=$(getprop sys.usb.state)"
    break
  fi
  sleep 2; n=$((n+1))
done

# 只有满足【全部】条件才做一次 configfs 推进，且只做一次：
#   adbd 仍未 running  且  configfs=1  且  adbd 不是 stopping（stopping 说明卡死了，推也没用，别动）
if [ "$(getprop init.svc.adbd)" != "running" ] \
   && [ "$(getprop sys.usb.configfs)" = "1" ] \
   && [ "$(getprop init.svc.adbd)" != "stopping" ]; then
  log "adbd not running (not stopping) -> one-shot configfs nudge"
  setprop sys.usb.ffs.ready 1
  sleep 1
  setprop sys.usb.config adb
  sleep 4
  log "after nudge: adbd=$(getprop init.svc.adbd) usb=$(getprop sys.usb.state)"
fi

# ---- 5) USB 自愈看护（严格条件、限流）----
( sh /data/local/usbfix.sh --watch ) &
log "usbfix watch started"

# ---- 6) 只唤醒、绝不灭屏的看护（15 分钟）----
n=0
while [ $n -lt 180 ]; do
  wl=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=')
  case "$wl" in
    *Asleep*) input keyevent 224 2>/dev/null; log "woke from Asleep" ;;
    *Dozing*) input keyevent 224 2>/dev/null; log "woke from Dozing" ;;
  esac
  n=$((n+1)); sleep 5
done
log "keep-awake guard done: $(dumpsys power 2>/dev/null | grep -m1 mWakefulness=)"
log "=== done ==="
