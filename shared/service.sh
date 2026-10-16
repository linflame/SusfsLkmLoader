#!/system/bin/sh
# service 阶段兜底: 等模块文件就绪后调用核心加载
MODDIR=${0%/*}
for i in $(seq 1 20); do
    [ -f "$MODDIR/load.sh" ] && break
    sleep 1
done
exec /system/bin/sh "$MODDIR/load.sh" service
