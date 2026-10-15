#!/system/bin/sh
# 兜底加载: 公用 post-fs-data.d 脚本已提前加载时直接退出
MODDIR=${0%/*}
KO=$MODDIR/susfs_guard_lkm.ko
KSUD=/data/adb/ksu/bin/ksud
LOG=/data/adb/susfs_lkm.log
KVER=""
[ -f $MODDIR/kernel_version ] && KVER=$(cat $MODDIR/kernel_version)

# 模块加载后自我隐藏, 以 /proc/susfs_* 控制节点为判据
is_loaded() {
    grep -q '^susfs_guard_lkm ' /proc/modules 2>/dev/null && return 0
    for n in /proc/susfs_path /proc/susfs_kstat /proc/susfs_hide_modules /proc/susfs_enable_log; do
        [ -e "$n" ] && return 0
    done
    return 1
}

# 已被公用 .d 脚本加载: 保留其日志并退出
is_loaded && { echo "OK already loaded ($KVER)" >> $LOG; exit 0; }

: > $LOG
[ -f "$KO" ] || { echo "ERROR ko missing: $KO" >> $LOG; exit 0; }

# KernelSU 用 ksud; 其他 root 用模块内置 susfs_insmod
if [ -x "$KSUD" ]; then
    OUT=$("$KSUD" insmod "$KO" 2>&1)
elif [ -x "$MODDIR/susfs_insmod" ]; then
    OUT=$("$MODDIR/susfs_insmod" "$KO" 2>&1)
fi

if is_loaded || echo "$OUT" | grep -qi 'file exists'; then
    echo "OK loaded ($KVER)" >> $LOG
else
    echo "ERROR load failed: $OUT" >> $LOG
fi
