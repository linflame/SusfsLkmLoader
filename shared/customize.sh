#!/system/bin/sh
# SUSFS LKM Loader - 安装: 保留全部 ko, 默认每次开机按内核自动匹配, 音量键可固定版本
# 兼容 Magisk / KernelSU / SukiSU / APatch
SKIPUNZIP=0
TIMEOUT=20

ui_print "- SUSFS LKM Loader installer started"

# ---------- 内核清单 = kos/ 目录内容 ----------
KOLIST=""
for f in $MODPATH/kos/susfs_guard_lkm-*.ko; do
  [ -f "$f" ] && { b=${f##*susfs_guard_lkm-}; KOLIST="$KOLIST ${b%.ko}"; }
done
[ -z "$KOLIST" ] && abort "! 模块包内未找到 ko 文件"

# 生成 kmis 清单并按 osrelease 自动识别 (与开机加载共用 kmi.sh 同一套逻辑)
printf '%s\n' $KOLIST > $MODPATH/kmis
REL=$(cat /proc/sys/kernel/osrelease)
. $MODPATH/kmi.sh
DETECTED=$(select_kmi "$REL" "$MODPATH")

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

# ---------- 菜单: 第一项为自动匹配 (推荐), 其后各固定版本 (识别结果排前) ----------
ui_print "--------------------------------"
ui_print " 内核: $REL"
[ -n "$DETECTED" ] && ui_print " 自动识别: $DETECTED"
ui_print " 音量+ = 确认    音量- = 下一个"
ui_print " ${TIMEOUT}s 无操作使用第一项"
ui_print "--------------------------------"

ORDER="auto"
REST=""
for k in $KOLIST; do
  if [ "$k" = "$DETECTED" ]; then ORDER="$ORDER $k"; else REST="$REST $k"; fi
done
ORDER="$ORDER$REST"

SEL=""
for k in $ORDER; do
  if [ "$k" = auto ]; then
    ui_print ">>> 自动匹配 (每次开机按内核选择, 换内核无需重装) ?"
  else
    ui_print ">>> 固定使用 $k ?"
  fi
  keycheck; R=$?
  if [ $R -eq 0 ]; then
    SEL=$k; break
  elif [ $R -eq 2 ]; then
    SEL=auto; ui_print " 超时, 使用自动匹配"; break
  fi
done
[ -z "$SEL" ] && abort "! 未选择, 安装中止"

if [ "$SEL" = auto ]; then
  rm -f $MODPATH/kernel_version
  ui_print "- 模式: 自动匹配"
else
  echo "$SEL" > $MODPATH/kernel_version
  ui_print "- 模式: 固定 $SEL"
fi

# ---------- 校验与权限 (next 专有文件按存在性处理, 两线共用此脚本) ----------
MISSING=""
for f in kos kmis kmi.sh load.sh susfs_insmod post-fs-data.sh service.sh uninstall.sh module.prop; do
  [ -e $MODPATH/$f ] || MISSING="$MISSING $f"
done
[ -n "$MISSING" ] && { ui_print "! 模块文件不完整, 缺少:$MISSING"; abort "! 安装中止 (请反馈此日志)"; }

set_perm_recursive $MODPATH/kos 0 0 0755 0644
set_perm $MODPATH/kmis 0 0 0644
set_perm $MODPATH/susfs_insmod 0 0 0755
for f in kmi.sh load.sh post-fs-data.sh service.sh uninstall.sh action.sh updater.sh webui.sh; do
  [ -f $MODPATH/$f ] && set_perm $MODPATH/$f 0 0 0755
done
[ -f $MODPATH/upstream_version ] && set_perm $MODPATH/upstream_version 0 0 0644
[ -d $MODPATH/webroot ] && set_perm_recursive $MODPATH/webroot 0 0 0755 0644

# 纯加载器, 不做文件挂载
touch $MODPATH/skip_mount

# ---------- 注册公用 post-fs-data.d 提前加载 ----------
# 公用脚本早于所有模块脚本; 钩子只转发到模块内 load.sh, uninstall.sh 负责清除
PFD=/data/adb/post-fs-data.d
HOOK=$PFD/susfs_guard_lkm.sh
mkdir -p $PFD
if [ -f "$HOOK" ] && ! grep -q 'SUSFS_LKM' "$HOOK"; then
  ui_print "! $HOOK 已被其他模块占用, 跳过提前加载注册 (模块阶段仍会加载)"
else
  cat > $HOOK <<'EOF'
#!/system/bin/sh
# SUSFS_LKM 提前加载 (公用阶段, 早于所有模块脚本)
MODDIR=/data/adb/modules/SUSFS_LKM
[ -f "$MODDIR/load.sh" ] && exec /system/bin/sh "$MODDIR/load.sh" early
exit 0
EOF
  chmod 755 $HOOK
  ui_print "- 已注册公用提前加载 (post-fs-data.d)"
fi

ui_print "- 完成! 重启后自动加载"
