#!/system/bin/sh
# 死屏修复：把 ESD 检查从 reg_read(DCS读,坏屏必失败) 改为 te_signal_check
# reg_read 失败会导致 PANEL_DEAD -> fence timeline reset -> 黑屏/0fps
P=/sys/kernel/debug/dsi_sofef00m_amoled_cmd_display/esd_check_mode
i=0
while [ $i -lt 120 ]; do
  if [ -f "$P" ]; then
    mount -o rw,remount /sys/kernel/debug 2>/dev/null
    echo te_signal_check > "$P" 2>/dev/null
    cur=$(cat "$P" 2>/dev/null)
    log -t ESD_FIX "esd_check_mode=$cur"
    break
  fi
  i=$((i+1))
  sleep 1
done