#!/system/bin/sh
# service 阶段兜底: 前两个阶段都失败时最后补一次
MODDIR=${0%/*}
KO=$MODDIR/susfs_guard_lkm.ko
KSUD=/data/adb/ksu/bin/ksud
LOG=/data/adb/susfs_lkm.log
KVER=""
[ -f $MODDIR/kernel_version ] && KVER=$(cat $MODDIR/kernel_version)

is_loaded() {
    grep -q '^susfs_guard_lkm ' /proc/modules 2>/dev/null && return 0
    for n in /proc/susfs_path /proc/susfs_kstat /proc/susfs_hide_modules /proc/susfs_enable_log; do
        [ -e "$n" ] && return 0
    done
    return 1
}

is_loaded && exit 0

# 等 ko 文件就绪
for i in $(seq 1 20); do
    [ -f "$KO" ] && break
    sleep 1
done
[ -f "$KO" ] || { echo "ERROR ko missing: $KO (fallback)" >> $LOG; exit 0; }

if [ -x "$KSUD" ]; then
    OUT=$("$KSUD" insmod "$KO" 2>&1)
elif [ -x "$MODDIR/susfs_insmod" ]; then
    OUT=$("$MODDIR/susfs_insmod" "$KO" 2>&1)
fi

if is_loaded || echo "$OUT" | grep -qi 'file exists'; then
    echo "OK loaded by fallback ($KVER)" >> $LOG
else
    echo "ERROR load failed (fallback): $OUT" >> $LOG
fi
