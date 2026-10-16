#!/system/bin/sh
# SUSFS LKM Loader - 核心加载逻辑, 公用钩子 / post-fs-data / service 三入口共用
# $1 = 调用阶段 (early / post-fs-data / service), early 阶段清空日志
# 加载结果动态写入 module.prop 描述 (安装时无状态, 每次开机更新)
MODDIR=${0%/*}
[ -f "$MODDIR/disable" ] && exit 0
[ -f "$MODDIR/remove" ] && exit 0
[ "$(getprop persist.sys.safemode)" != 1 ] || exit 0
[ "$(getprop ro.sys.safemode)" != 1 ] || exit 0

LOG=/data/adb/susfs_lkm.log
STAGE=$1
[ "$STAGE" = early ] && : > $LOG

write_status() { # $1=状态文本 (😋加载成功~ / 😭加载失败！)
    B=$(cat "$MODDIR/description_base" 2>/dev/null)
    [ -n "$B" ] || return 0
    B=$(printf '%s' "$B" | sed 's/[&|]/\\&/g')
    sed -i "s|^description=.*|description=$1 $B|" "$MODDIR/module.prop"
}

# 模块加载后自我隐藏, 以 /proc/susfs_* 控制节点为主要判据
is_loaded() {
    grep -q '^susfs_guard_lkm ' /proc/modules 2>/dev/null && return 0
    [ -d /sys/module/susfs_guard_lkm ] && return 0
    for n in /proc/susfs_path /proc/susfs_kstat /proc/susfs_hide_modules /proc/susfs_enable_log; do
        [ -e "$n" ] && return 0
    done
    return 1
}

if is_loaded; then
    write_status "😋加载成功~"
    exit 0
fi

# 固定版本 (安装时音量键手动选择) 优先, 否则按内核 osrelease 从 kmis 清单自动匹配
KVER=""
[ -f "$MODDIR/kernel_version" ] && KVER=$(cat "$MODDIR/kernel_version" | tr -d '\r')
if [ -z "$KVER" ]; then
    REL=$(cat /proc/sys/kernel/osrelease)
    . "$MODDIR/kmi.sh"
    KVER=$(select_kmi "$REL" "$MODDIR")
fi
[ -n "$KVER" ] || { echo "ERROR no ko matches kernel: $REL ($STAGE)" >> $LOG; write_status "😭加载失败！"; exit 0; }
KO=$MODDIR/kos/susfs_guard_lkm-$KVER.ko
[ -f "$KO" ] || { echo "ERROR ko missing: $KO ($STAGE)" >> $LOG; write_status "😭加载失败！"; exit 0; }

# 统一用上游自带的 susfs_insmod (所有管理器一套逻辑), 显式暴露 /proc/susfs_* 控制节点
[ -x "$MODDIR/susfs_insmod" ] || { echo "ERROR susfs_insmod missing ($STAGE)" >> $LOG; write_status "😭加载失败！"; exit 0; }
OUT=$("$MODDIR/susfs_insmod" "$KO" expose_proc=1 2>&1)

if is_loaded || echo "$OUT" | grep -qi 'file exists'; then
    echo "OK loaded ($KVER, $STAGE)" >> $LOG
    write_status "😋加载成功~"
else
    echo "ERROR load failed ($KVER, $STAGE): $OUT" >> $LOG
    write_status "😭加载失败！"
fi
