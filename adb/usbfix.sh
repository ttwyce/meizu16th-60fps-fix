#!/system/bin/sh
# ============================================================================
# USB / adb 自愈（v2）—— 严格条件 + 限流
#
# 要修的已知故障：
#   sys.usb.config 的 none 分支会 setprop sys.usb.ffs.ready 0；
#   之后 config 回到 adb 时，init 规则要求 ffs.ready=1 才写 UDC，
#   而 adbd 若没重启就不会把 ready 置回 1 → USB gadget 永不挂载（但 adbd 还活着）。
#
# 【审核要点】本脚本只做两件事，且都有严格前置条件与限流：
#   A. adbd 确实在跑 + 确实有 ffs 端点 + ffs.ready=0  → 补 ffs.ready=1
#   B. 上面修完 UDC 仍为空 + configfs=1                → 推一次 sys.usb.config mtp,diag,adb
#   * adbd=stopping 时【什么都不做】（卡 D 状态，推了只会更糟）
#   * 两次动作之间至少间隔 30 秒
#   * 不发 keyevent、不碰分区
# ============================================================================
LOG=/data/local/tmp/usbfix.log
G=/config/usb_gadget/g1
STAMP=/data/local/tmp/usbfix.last

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

ffs_ready()   { [ "$(getprop sys.usb.ffs.ready)" = "1" ]; }
udc_attached(){ [ -n "$(cat $G/UDC 2>/dev/null)" ]; }
has_ep()      { [ -e /dev/usb-ffs/adb/ep1 ]; }

# 限流：距上次动作不足 30s 就跳过
too_soon() {
  last=$(cat "$STAMP" 2>/dev/null)
  now=$(date +%s)
  if [ -n "$last" ]; then
    [ $((now - last)) -lt 30 ] && return 0
  fi
  return 1
}
mark() { date +%s > "$STAMP"; }

fix_once() {
  adbd=$(getprop init.svc.adbd)
  state=$(getprop sys.usb.state)
  cfgs=$(getprop sys.usb.configfs)

  # adbd 卡在 stopping：什么都别做
  if [ "$adbd" = "stopping" ]; then
    return 0
  fi
  # adbd 没跑：本脚本不负责启动 adbd（那是开机脚本的事）
  if [ "$adbd" != "running" ]; then
    return 0
  fi

  # A) ffs.ready 被清零
  if has_ep && ! ffs_ready; then
    if too_soon; then return 0; fi
    log "A: ffs.ready=0 but ffs ep exists -> set 1 (state=$state)"
    setprop sys.usb.ffs.ready 1
    mark
    sleep 2
  fi

  # B) UDC 没挂上
  if ! udc_attached; then
    if too_soon; then return 0; fi
    if [ "$cfgs" != "1" ]; then return 0; fi
    log "B: UDC empty (state=$state configfs=$cfgs) -> set sys.usb.config mtp,diag,adb"
    setprop sys.usb.config mtp,diag,adb
    mark
    sleep 2
  fi
}

if [ "$1" = "--watch" ]; then
  n=0
  while [ $n -lt 120 ]; do
    fix_once
    n=$((n+1)); sleep 5
  done
  log "watch finished: adbd=$(getprop init.svc.adbd) state=$(getprop sys.usb.state) ffs=$(getprop sys.usb.ffs.ready) UDC=[$(cat $G/UDC 2>/dev/null)]"
  exit 0
fi

fix_once
echo "adbd=$(getprop init.svc.adbd) state=$(getprop sys.usb.state) ffs=$(getprop sys.usb.ffs.ready) UDC=[$(cat $G/UDC 2>/dev/null)]"
