#!/system/bin/sh
# ============================================================
# 死屏调试日志模块  tools/fpslog.sh
#
# 用途：死屏 60fps 补丁调试时抓现场。每秒记录一次状态；一旦检测到
#       显示停滞（SF 卡在 GPU 等待，或 vsync 不增长），自动抓取完整
#       现场：dmesg / SDE evtlog / SF 全部线程栈 / GPU 状态 / 截图。
#
# 安装（可选，仅调试时需要）：
#   adb push scripts/fpslog.sh /sdcard/fpslog.sh
#   adb shell su -c "mkdir -p /data/adb/service.d && \
#       cp /sdcard/fpslog.sh /data/adb/service.d/ && \
#       chmod 755 /data/adb/service.d/fpslog.sh"
#   重启后自动运行，日志在 /sdcard/fpslog/
#
# 卸载（不需要重启设备）：
#   adb shell su -c "rm -f /data/adb/service.d/fpslog.sh"
#   # 再结束内存中正在运行的实例，否则它会继续跑：
#   adb shell 'pkill -f service.d/fpslog.sh; killall dmesg'
#
# 注意：本脚本只"读" /sys/kernel/debug，绝不做 remount。
#       切勿对 /sys/kernel/debug 执行 mount -o remount —— 那会把
#       debugfs 根权限重置为 0700，导致 WebView 渲染进程无法重开
#       trace_marker 而崩溃（详见技术文档第 14 章）。
# ============================================================

D=/sdcard/fpslog
mkdir -p $D
rm -f $D/*.log $D/*.txt $D/*.png 2>/dev/null

VSF=/sys/kernel/debug/dri/0/encoder25/status
CRTC=/sys/kernel/debug/dri/0/crtc111/status
DBGD=/sys/kernel/debug/dri/0/debug/dump
LOG=$D/monitor.log
DMESG=$D/dmesg.log

echo "# fpslog 启动 $(date)" > $LOG

start_dmesg() {
  setsid sh -c "dmesg -w >> $DMESG 2>&1" < /dev/null > /dev/null 2>&1 &
  echo "# dmesg 流重启 $(date +%H:%M:%S)" >> $LOG
}
start_dmesg

prev=""; stall=0; gpu_stall=0; n=0
while true; do
  n=$((n+1))
  if [ $((n % 15)) -eq 0 ]; then
    if [ -z "$(ps -A 2>/dev/null | grep dmesg | head -1)" ]; then start_dmesg; fi
  fi

  ts=$(date +%H:%M:%S)
  up=$(cut -d' ' -f1 /proc/uptime)
  vs=$(sed -n 's/.*vsync: *\([0-9]*\).*/\1/p' $VSF 2>/dev/null)
  vb=$(grep -o 'vblank_enable:[01]' $CRTC 2>/dev/null)
  gpu=$(cat /sys/class/kgsl/kgsl-3d0/gpubusy 2>/dev/null | tr -s ' ' | tr '\n' ' ')
  wake=$(dumpsys power 2>/dev/null | grep -m1 mWakefulness= | cut -d= -f2)
  fg=$(dumpsys activity activities 2>/dev/null | grep -m1 ResumedActivity | sed 's/.*u0 //' | cut -c1-50)

  SFPID=$(pidof surfaceflinger 2>/dev/null | awk '{print $1}')
  [ -z "$SFPID" ] && SFPID=$(ps -A 2>/dev/null | grep surfaceflinger | awk '{print $2}' | head -1)
  wchan="?"
  if [ -n "$SFPID" ]; then
    wchan=$(cat /proc/$SFPID/wchan 2>/dev/null)
    [ -z "$wchan" ] && wchan=$(su -c "cat /proc/$SFPID/wchan" 2>/dev/null)
    [ -z "$wchan" ] && wchan="?"
  fi

  echo "$ts up=$up vs=$vs $vb gpu=[$gpu] sfpid=$SFPID wchan=$wchan wake=$wake fg=$fg" >> $LOG

  if [ -n "$prev" ] && [ -n "$vs" ] && [ "$vs" = "$prev" ]; then stall=$((stall+1)); else stall=0; fi
  case "$wchan" in adreno_*|kgsl_*|*drawctxt*) gpu_stall=$((gpu_stall+1)) ;; *) gpu_stall=0 ;; esac

  if { [ "$stall" -ge 2 ] || [ "$gpu_stall" -ge 2 ]; } && [ "$wake" = "Awake" ]; then
    T=$(date +%H%M%S)
    echo "" >> $LOG
    echo "########## STALL @ $ts vs=$vs stall=$stall gpu_stall=$gpu_stall wchan=$wchan" >> $LOG
    echo "  前台=$fg" >> $LOG
    dmesg | tail -800 > $D/stall_${T}_dmesg.txt 2>&1
    dmesg | grep -E "sde error|drm:|kgsl|syncpoint" | tail -300 > $D/stall_${T}_errors.txt 2>&1
    cat $DBGD > $D/stall_${T}_sdedump.txt 2>&1
    if [ -n "$SFPID" ]; then
      su -c "cat /proc/$SFPID/stack" > $D/stall_${T}_sf_stack.txt 2>&1
      for t in /proc/$SFPID/task/*; do
        echo "--- $(cat $t/comm 2>/dev/null) wchan=$(cat $t/wchan 2>/dev/null) ---" >> $D/stall_${T}_sf_stack.txt
        cat $t/stack >> $D/stall_${T}_sf_stack.txt 2>&1
      done
    fi
    dumpsys SurfaceFlinger 2>/dev/null | grep -iE "app:|powerMode|missed frame|refresh-rate|Allowed Display" > $D/stall_${T}_sf.txt 2>&1
    { echo "gpubusy: $(cat /sys/class/kgsl/kgsl-3d0/gpubusy 2>/dev/null)"; echo "gpuclk: $(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null)"; } > $D/stall_${T}_gpu.txt 2>&1
    screencap -p $D/stall_${T}.png 2>/dev/null
    echo "########## 抓取完成 ##########" >> $LOG
    stall=0; gpu_stall=0; sleep 8
  fi

  prev=$vs
  sleep 1
done