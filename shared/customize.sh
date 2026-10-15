#!/system/bin/sh
# SUSFS LKM Loader - 安装时用音量键选择内核版本
# 兼容 Magisk / KernelSU / SukiSU / APatch
SKIPUNZIP=0
TIMEOUT=20

ui_print "- SUSFS LKM Loader installer started"

# ---------- 内核列表 = kos/ 目录内容 ----------
KOLIST=""
for f in $MODPATH/kos/susfs_guard_lkm-*.ko; do
  [ -f "$f" ] && { b=${f##*susfs_guard_lkm-}; KOLIST="$KOLIST ${b%.ko}"; }
done
[ -z "$KOLIST" ] && abort "! 模块包内未找到 ko 文件"

# ---------- 自动识别: 先按 安卓版本+内核版本 匹配, 再仅按内核版本 ----------
KVER=$(uname -r)
AVER=$(getprop ro.build.version.release 2>/dev/null | cut -d. -f1)
DETECTED=""
for round in 1 2; do
  for k in $KOLIST; do
    v=${k##*-}
    [ $round -eq 1 ] && { case "$k" in *android$AVER-*) ;; *) continue ;; esac; }
    case "$KVER" in
      "$v".* | "$v"-*) DETECTED=$k; break ;;
    esac
  done
  [ -n "$DETECTED" ] && break
done

# ---------- 音量键: 0=音量+ 1=音量- 2=超时 ----------
keycheck() {
  TMPF=$TMPDIR/.key_evt
  rm -f $TMPF
  ( getevent -qlc 1 2>/dev/null | grep -m1 -E 'KEY_VOLUME(UP|DOWN)' > $TMPF ) &
  GPID=$!
  SECS=0
  while [ $SECS -lt $TIMEOUT ]; do
    [ -s $TMPF ] && break
    sleep 1
    SECS=$((SECS + 1))
  done
  kill $GPID 2>/dev/null
  grep -q 'KEY_VOLUMEUP' $TMPF 2>/dev/null && return 0
  grep -q 'KEY_VOLUMEDOWN' $TMPF 2>/dev/null && return 1
  return 2
}

# ---------- 菜单 (识别版本排第一) ----------
ui_print "--------------------------------"
ui_print " 系统: Android $AVER    内核: $KVER"
[ -n "$DETECTED" ] && ui_print " 自动识别: $DETECTED"
ui_print " 音量+ = 确认    音量- = 下一个"
ui_print " ${TIMEOUT}s 无操作使用识别结果"
ui_print "--------------------------------"

ORDER=""
for k in $KOLIST; do
  [ "$k" = "$DETECTED" ] && ORDER="$k $ORDER" || ORDER="$ORDER $k"
done

SEL=""
for k in $ORDER; do
  ui_print ">>> 安装 susfs_guard_lkm-$k.ko ?"
  keycheck; R=$?
  if [ $R -eq 0 ]; then
    SEL=$k; break
  elif [ $R -eq 2 ]; then
    [ -n "$DETECTED" ] && { SEL=$DETECTED; ui_print " 超时, 使用识别结果: $SEL"; }
    break
  fi
done
[ -z "$SEL" ] && abort "! 未选择内核版本, 安装中止"

# ---------- 安装选中的 ko ----------
mv -f $MODPATH/kos/susfs_guard_lkm-$SEL.ko $MODPATH/susfs_guard_lkm.ko
rm -rf $MODPATH/kos
echo "$SEL" > $MODPATH/kernel_version

# ---------- 校验与权限 (next 专有文件按存在性处理, 两线共用此脚本) ----------
MISSING=""
for f in susfs_guard_lkm.ko susfs_insmod post-fs-data.sh service.sh uninstall.sh module.prop; do
  [ -f $MODPATH/$f ] || MISSING="$MISSING $f"
done
[ -n "$MISSING" ] && { ui_print "! 模块文件不完整, 缺少:$MISSING"; abort "! 安装中止 (请反馈此日志)"; }

set_perm $MODPATH/susfs_guard_lkm.ko 0 0 0644
set_perm $MODPATH/susfs_insmod 0 0 0755
for f in post-fs-data.sh service.sh uninstall.sh action.sh updater.sh webui.sh; do
  [ -f $MODPATH/$f ] && set_perm $MODPATH/$f 0 0 0755
done
[ -f $MODPATH/upstream_version ] && set_perm $MODPATH/upstream_version 0 0 0644
[ -d $MODPATH/webroot ] && set_perm_recursive $MODPATH/webroot 0 0 0755 0644

# ---------- 注册公用 post-fs-data.d 提前加载 ----------
# 公用脚本早于所有模块脚本 (含模块挂载), 加载逻辑独立内嵌, uninstall.sh 负责清除
PFD=/data/adb/post-fs-data.d
mkdir -p $PFD
cat > $PFD/susfs_guard_lkm.sh <<'EOF'
#!/system/bin/sh
# SUSFS_LKM 提前加载 (公用阶段, 早于所有模块脚本)
MODDIR=/data/adb/modules/SUSFS_LKM
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

: > $LOG
is_loaded && { echo "OK already loaded ($KVER)" >> $LOG; exit 0; }
[ -f "$KO" ] || { echo "ERROR ko missing: $KO" >> $LOG; exit 0; }

if [ -x "$KSUD" ]; then
    OUT=$("$KSUD" insmod "$KO" 2>&1)
elif [ -x "$MODDIR/susfs_insmod" ]; then
    OUT=$("$MODDIR/susfs_insmod" "$KO" 2>&1)
fi

if is_loaded || echo "$OUT" | grep -qi 'file exists'; then
    echo "OK loaded early ($KVER)" >> $LOG
else
    echo "ERROR load failed (early): $OUT" >> $LOG
fi
EOF
chmod 755 $PFD/susfs_guard_lkm.sh
ui_print "- 已注册公用提前加载 (post-fs-data.d)"

ui_print "- 完成! 重启后自动加载 ($SEL)"
