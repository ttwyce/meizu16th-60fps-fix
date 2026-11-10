#!/system/bin/sh
# 统一入口：真正的逻辑在 /data/local/adbfix.sh（改脚本不用动 /system）
exec /system/bin/sh /data/local/adbfix.sh
