#!/system/bin/sh
# 卸载 ko, 清理日志/残留 ko/公用提前加载脚本 (仅删除本模块创建的钩子)
KSUD=/data/adb/ksu/bin/ksud
[ -x "$KSUD" ] && "$KSUD" rmmod susfs_guard_lkm 2>/dev/null
rmmod susfs_guard_lkm 2>/dev/null
rm -f /data/adb/susfs_lkm.log
rm -f /data/adb/susfs_guard_lkm-android*.ko
H=/data/adb/post-fs-data.d/susfs_guard_lkm.sh
[ -f "$H" ] && grep -q 'SUSFS_LKM' "$H" && rm -f "$H"
