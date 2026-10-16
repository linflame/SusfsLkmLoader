#!/system/bin/sh
# SUSFS LKM Loader - 安装: 选语言 -> 自动识别/固定版本 -> 保留全部 ko, 开机按内核匹配
# 兼容 Magisk / KernelSU / SukiSU / APatch
SKIPUNZIP=0
TIMEOUT=20

# ---------- 音量键: 0=音量+ 1=音量- 2=超时 ----------
# getevent -lc 1 输出如 "EV_KEY KEY_VOLUMEDOWN DOWN"; 只认按下 (DOWN) 忽略释放 (UP),
# 否则残留的释放事件会被下次 keycheck 读到, 一次按键跳两项
keycheck() {
  TMPF=$TMPDIR/.key_evt
  rm -f $TMPF
  ( while true; do
      E=$(getevent -lc 1 2>/dev/null)
      case "$E" in
        *KEY_VOLUMEUP*DOWN*)   echo up > $TMPF;   break ;;
        *KEY_VOLUMEDOWN*DOWN*) echo down > $TMPF; break ;;
      esac
    done ) &
  GPID=$!
  SECS=0
  while [ $SECS -lt $TIMEOUT ]; do
    [ -s $TMPF ] && break
    sleep 1
    SECS=$((SECS + 1))
  done
  kill $GPID 2>/dev/null
  grep -q up $TMPF 2>/dev/null && return 0
  grep -q down $TMPF 2>/dev/null && return 1
  return 2
}

# 双语输出: say "中文" "English" (ZH=1 中文, ZH=0 English)
ZH=1
say() { [ $ZH = 1 ] && ui_print "$1" || ui_print "$2"; }

ui_print "- SUSFS LKM Loader installer started"

# ---------- Q1: 语言 ----------
ui_print "--------------------------------"
ui_print " 选择语言 / Select language"
ui_print " 音量+ = 中文    音量- = English"
ui_print " Vol+ = Chinese  Vol- = English"
ui_print "--------------------------------"
keycheck
[ $? = 1 ] && ZH=0

# ---------- 内核清单 = kos/ 目录内容 ----------
KOLIST=""
for f in $MODPATH/kos/susfs_guard_lkm-*.ko; do
  [ -f "$f" ] && { b=${f##*susfs_guard_lkm-}; KOLIST="$KOLIST ${b%.ko}"; }
done
[ -z "$KOLIST" ] && abort "! 模块包内未找到 ko 文件 / no ko files in package"

# 生成 kmis 清单并按 osrelease 自动识别 (与开机加载共用 kmi.sh 同一套逻辑)
printf '%s\n' $KOLIST > $MODPATH/kmis
REL=$(cat /proc/sys/kernel/osrelease)
. $MODPATH/kmi.sh
DETECTED=$(select_kmi "$REL" "$MODPATH")

ui_print "--------------------------------"
say " 内核: $REL" " Kernel: $REL"
[ -n "$DETECTED" ] && say " 自动识别: $DETECTED" " Detected: $DETECTED"
ui_print "--------------------------------"

# ---------- Q2: 自动识别 or 固定版本 ----------
say "每次开机自动识别内核版本?" "Auto-detect kernel version on every boot?"
say "音量+ = 是, 自动识别 (推荐, 换内核无需重装)" "Vol+ = Yes, auto (recommended, no reinstall after OTA)"
say "音量- = 否, 固定版本安装" "Vol- = No, use a fixed version"
say "${TIMEOUT}s 无操作默认自动识别" "Timeout ${TIMEOUT}s defaults to auto"
keycheck; R=$?

if [ $R -eq 1 ]; then
  # ---------- Q3: 固定版本列表 (识别结果排第一) ----------
  ORDER=""
  REST=""
  for k in $KOLIST; do
    if [ "$k" = "$DETECTED" ]; then ORDER="$k"; else REST="$REST $k"; fi
  done
  ORDER="$ORDER$REST"
  SEL=""
  for k in $ORDER; do
    say ">>> 固定使用 $k ?" ">>> Use fixed $k ?"
    say "    音量+ = 确认    音量- = 下一个" "    Vol+ = confirm  Vol- = next"
    keycheck; R=$?
    if [ $R -eq 0 ]; then
      SEL=$k; break
    elif [ $R -eq 2 ]; then
      [ -n "$DETECTED" ] && { SEL=$DETECTED; say " 超时, 使用识别结果: $SEL" " Timeout, use detected: $SEL"; }
      break
    fi
  done
  [ -z "$SEL" ] && { say "! 未选择版本, 安装中止" "! No version selected, aborting"; abort "! install aborted"; }
  echo "$SEL" > $MODPATH/kernel_version
  say "- 模式: 固定版本 $SEL" "- Mode: fixed $SEL"
else
  [ $R -eq 2 ] && say " 超时, 默认自动识别" " Timeout, default: auto"
  rm -f $MODPATH/kernel_version
  say "- 模式: 自动识别 (每次开机按内核匹配)" "- Mode: auto-detect (match kernel on every boot)"
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

# 保存描述基座, 加载状态由 load.sh 每次开机动态写入 module.prop
sed -n 's/^description=//p' $MODPATH/module.prop > $MODPATH/description_base
set_perm $MODPATH/description_base 0 0 0644

# 纯加载器, 不做文件挂载
touch $MODPATH/skip_mount

# ---------- 注册公用 post-fs-data.d 提前加载 ----------
# 公用脚本早于所有模块脚本; 钩子只转发到模块内 load.sh, uninstall.sh 负责清除
PFD=/data/adb/post-fs-data.d
HOOK=$PFD/susfs_guard_lkm.sh
mkdir -p $PFD
if [ -f "$HOOK" ] && ! grep -q 'SUSFS_LKM' "$HOOK"; then
  say "! $HOOK 已被其他模块占用, 跳过提前加载注册 (模块阶段仍会加载)" \
      "! $HOOK is used by another module, skip early-load hook (module stage still loads)"
else
  cat > $HOOK <<'EOF'
#!/system/bin/sh
# SUSFS_LKM 提前加载 (公用阶段, 早于所有模块脚本)
MODDIR=/data/adb/modules/SUSFS_LKM
[ -f "$MODDIR/load.sh" ] && exec /system/bin/sh "$MODDIR/load.sh" early
exit 0
EOF
  chmod 755 $HOOK
  say "- 已注册公用提前加载 (post-fs-data.d)" "- Early-load hook registered (post-fs-data.d)"
fi

say "- 完成! 重启后自动加载" "- Done! Will load on reboot"
