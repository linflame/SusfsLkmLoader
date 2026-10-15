#!/system/bin/sh
# 管理器 Action 入口: 检查更新 -> 下载替换 ko + susfs_insmod -> 热重载
# updater.sh 的 INFO=/OK=/ERROR= 前缀供 WebUI 解析, 这里剥掉做纯净输出
MODDIR=${0%/*}
. "$MODDIR/updater.sh"

SRC="gitee"
[ -f "$MODDIR/update_source" ] && SRC=$(cat "$MODDIR/update_source" | tr -d '\r')
case "$SRC" in gitee|github) ;; *) SRC="gitee" ;; esac

echo "== SUSFS LKM Loader 更新 (首选源: $SRC) =="
do_update "$SRC" | sed 's/^INFO=//; s/^OK=//; s/^ERROR=//'
echo "== 结束: $(date '+%Y-%m-%d %H:%M:%S') =="
