#!/system/bin/sh
# 模块 post-fs-data 阶段: 调用核心加载 (公用钩子已加载时 load.sh 自动跳过)
MODDIR=${0%/*}
exec /system/bin/sh "$MODDIR/load.sh" post-fs-data
