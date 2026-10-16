#!/system/bin/sh
# SUSFS LKM Loader - 核心加载逻辑, 公用钩子 / post-fs-data / service 三入口共用
# $1 = 调用阶段 (early / post-fs-data / service), early 阶段清空日志
MODDIR=${0%/*}
[ -f "$MODDIR/disable" ] && exit 0
[ -f "$MODDIR/remove" ] && exit 0
[ "$(getprop persist.sys.safemode)" != 1 ] || exit 0
[ "$(getprop ro.sys.safemode)" != 1 ] || exit 0

LOG=/data/adb/susfs_lkm.log
KSUD=/data/adb/ksu/bin/ksud
STAGE=$1
[ "$STAGE" = early ] && : > $LOG

# 模块加载后自我隐藏, 以 /proc/susfs_* 控制节点为主要判据
is_loaded() {
    grep -q '^susfs_guard_lkm ' /proc/modules 2>/dev/null && return 0
    [ -d /sys/module/susfs_guard_lkm ] && return 0
    for n in /proc/susfs_path /proc/susfs_kstat /proc/susfs_hide_modules /proc/susfs_enable_log; do
        [ -e "$n" ] && return 0
    done
    return 1
}

is_loaded && exit 0

# 固定版本 (安装时音量键手动选择) 优先, 否则按内核 osrelease 从 kmis 清单自动匹配
KVER=""
[ -f "$MODDIR/kernel_version" ] && KVER=$(cat "$MODDIR/kernel_version" | tr -d '\r')
if [ -z "$KVER" ]; then
    REL=$(cat /proc/sys/kernel/osrelease)
    . "$MODDIR/kmi.sh"
    KVER=$(select_kmi "$REL" "$MODDIR")
fi
[ -n "$KVER" ] || { echo "$(date '+%m-%d %H:%M:%S') ERROR no ko matches kernel: $REL ($STAGE)" >> $LOG; exit 0; }
KO=$MODDIR/kos/susfs_guard_lkm-$KVER.ko
[ -f "$KO" ] || { echo "$(date '+%m-%d %H:%M:%S') ERROR ko missing: $KO ($STAGE)" >> $LOG; exit 0; }

# KernelSU 优先用 ksud, 失败回退模块内置 susfs_insmod (显式暴露 /proc/susfs_* 控制节点)
OUT=""
if [ -x "$KSUD" ]; then
    OUT=$("$KSUD" insmod "$KO" 2>&1)
fi
if ! is_loaded && [ -x "$MODDIR/susfs_insmod" ]; then
    OUT=$("$MODDIR/susfs_insmod" "$KO" expose_proc=1 2>&1)
fi

if is_loaded || echo "$OUT" | grep -qi 'file exists'; then
    echo "$(date '+%m-%d %H:%M:%S') OK loaded ($KVER, $STAGE)" >> $LOG
else
    echo "$(date '+%m-%d %H:%M:%S') ERROR load failed ($KVER, $STAGE): $OUT" >> $LOG
fi
