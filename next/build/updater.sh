#!/system/bin/sh
# SUSFS LKM Loader - 更新核心库, action.sh / webui.sh 共用
# 首选更新源 gitee, 失败自动回退 github (webui 可改 update_source)
# 输出约定: "INFO=xxx" 日志, "OK=xxx"/"ERROR=xxx"/"uptodate" 结果; WebUI 依赖前缀解析
REPO="inforcqb/susfs4ksu-lkm"
UA="susfs-lkm-updater"
[ -z "$MODDIR" ] && MODDIR=${0%/*}
LOG=/data/adb/susfs_lkm.log

# ---------- 下载工具探测: curl -> wget -> busybox wget ----------
CURL=""
WGET=""
detect_tools() {
    [ -n "$CURL" ] || [ -n "$WGET" ] && return 0
    for d in "" /data/adb/ksu/bin /data/adb/ap/bin /data/adb/magisk /system/bin /system/xbin /vendor/bin; do
        p="${d:+$d/}curl"; { command -v "$p" >/dev/null 2>&1 || [ -x "$p" ]; } && { CURL="$p"; return 0; }
    done
    for d in "" /data/adb/ksu/bin /data/adb/ap/bin /data/adb/magisk /system/bin /system/xbin; do
        p="${d:+$d/}wget"; { command -v "$p" >/dev/null 2>&1 || [ -x "$p" ]; } && { WGET="$p"; return 0; }
        p="${d:+$d/}busybox"; { command -v "$p" >/dev/null 2>&1 || [ -x "$p" ]; } && { WGET="$p wget"; return 0; }
    done
    return 1
}

http_get() { # $1=url -> stdout
    if [ -n "$CURL" ]; then
        $CURL -fsSL --connect-timeout 10 -m 40 -A "$UA" "$1" 2>/dev/null
    else
        $WGET -q -T 15 -U "$UA" -O - "$1" 2>/dev/null
    fi
}

http_download() { # $1=url $2=dest
    rm -f "$2"
    if [ -n "$CURL" ]; then
        $CURL -fL --connect-timeout 15 -m 300 -A "$UA" -o "$2" "$1" 2>/dev/null
    else
        $WGET -q -T 30 -U "$UA" -O "$2" "$1" 2>/dev/null
    fi
}

# ---------- 查最新 tag (不用 API 避免限流) ----------
# 优先 releases/latest 302 跳转; 兜底解析 releases 列表页 (第一个 tag 即最新)
get_latest_tag() { # $1=gitee|github
    case "$1" in
        gitee) HOST="https://gitee.com" ;;
        github) HOST="https://github.com" ;;
        *) return 1 ;;
    esac
    t=""
    if [ -n "$CURL" ]; then
        t=$($CURL -fsSIL --connect-timeout 10 -m 30 -A "$UA" -o /dev/null -w '%{url_effective}' "$HOST/$REPO/releases/latest" 2>/dev/null)
        case "$t" in */releases/tag/*) t=${t##*/} ;; *) t="" ;; esac
    fi
    if [ -z "$t" ]; then
        t=$(http_get "$HOST/$REPO/releases" | grep -o "releases/tag/[^\"?#<]*" | head -n 1)
        t=${t#releases/tag/}
    fi
    echo "$t"
}

release_url() { # $1=source $2=tag $3=filename
    case "$1" in
        gitee) echo "https://gitee.com/$REPO/releases/download/$2/$3" ;;
        github) echo "https://github.com/$REPO/releases/download/$2/$3" ;;
    esac
}

# ---------- 加载状态 ----------
is_loaded() {
    grep -q '^susfs_guard_lkm ' /proc/modules 2>/dev/null && return 0
    [ -d /sys/module/susfs_guard_lkm ] && return 0
    for n in /proc/susfs_path /proc/susfs_kstat /proc/susfs_hide_modules /proc/susfs_enable_log; do
        [ -e "$n" ] && return 0
    done
    return 1
}

unload_ko() {
    rmmod susfs_guard_lkm 2>/dev/null
    sleep 1
}

load_ko() { # $1=ko 路径; 统一用 susfs_insmod (显式暴露 /proc/susfs_* 控制节点)
    "$MODDIR/susfs_insmod" "$1" expose_proc=1 2>&1
}

# 把状态动态写进 module.prop 描述 (与 load.sh 同一约定: 描述基座 + 状态后缀)
write_status() { # $1=状态文本 (😋加载成功~ / 😭加载失败！)
    B=$(cat "$MODDIR/description_base" 2>/dev/null)
    [ -n "$B" ] || return 0
    B=$(printf '%s' "$B" | sed 's/[&|]/\\&/g')
    sed -i "s|^description=.*|description=$1 $B|" "$MODDIR/module.prop"
}

set_module_version() { # $1=上游tag: 更新 upstream_version 与描述基座, 模块 version/versionCode 不动
    echo "$1" > "$MODDIR/upstream_version"
    echo "Auto load susfs kernel module on boot. Current version = $1" > "$MODDIR/description_base"
}

# 下载 release 附件 (带跨源重试), 成功返回 0
fetch_asset() { # $1=源顺序 $2=tag $3=文件名 $4=保存路径
    for s in $1; do
        http_download "$(release_url $s "$2" "$3")" "$4"
        [ -s "$4" ] && return 0
        echo "INFO=$s 下载失败, 换源重试"
    done
    return 1
}

# ---------- 只检查 ----------
do_check() { # $1=gitee|github
    detect_tools || { echo "ERROR=设备上没有可用的 curl/wget"; return 1; }
    echo "INFO=正在从 $1 查询最新版本 ..."
    t=$(get_latest_tag "$1")
    [ -n "$t" ] && { echo "LATEST=$t"; return 0; }
    echo "ERROR=无法从 $1 查询最新版本"
    return 1
}

# ---------- 更新 + 热重载 ----------
do_update() { # $1=首选源 gitee|github
    echo "INFO=正在检测下载工具 ..."
    detect_tools || { echo "ERROR=设备上没有可用的 curl/wget"; return 1; }
    echo "INFO=下载工具: ${CURL:-$WGET}"

    CUR=$(cat "$MODDIR/upstream_version" 2>/dev/null | tr -d '\r')

    # 内核变体: kernel_version 为固定模式 (只更新该变体), 否则自动匹配当前内核 (全量更新所有变体)
    KVAR=$(cat "$MODDIR/kernel_version" 2>/dev/null | tr -d '\r')
    if [ -n "$KVAR" ]; then
        echo "INFO=固定内核变体: $KVAR"
        UPKMIS="$KVAR"
    else
        REL=$(cat /proc/sys/kernel/osrelease)
        . "$MODDIR/kmi.sh"
        KVAR=$(select_kmi "$REL" "$MODDIR")
        [ -z "$KVAR" ] && { echo "ERROR=当前内核 $REL 无匹配 ko"; return 1; }
        echo "INFO=自动匹配内核变体: $KVAR (更新全部变体)"
        UPKMIS=$(cat "$MODDIR/kmis")
    fi

    [ "$1" = "github" ] && ORDER="github gitee" || ORDER="gitee github"

    TAG=""; SRC=""
    for s in $ORDER; do
        echo "INFO=正在从 $s 查询最新版本 ..."
        t=$(get_latest_tag "$s")
        [ -n "$t" ] && { TAG="$t"; SRC="$s"; break; }
        echo "INFO=$s 查询失败, 尝试下一个源"
    done
    [ -z "$TAG" ] && { echo "ERROR=所有更新源均不可用"; return 1; }
    echo "INFO=当前版本 $CUR, 上游最新 $TAG [$SRC]"

    [ "$TAG" = "$CUR" ] && { echo "uptodate"; return 0; }

    TMP="$MODDIR/.update_tmp"
    rm -rf "$TMP"; mkdir -p "$TMP/old"

    for k in $UPKMIS; do
        KONAME="susfs_guard_lkm-$k.ko"
        echo "INFO=下载 $KONAME"
        if ! fetch_asset "$ORDER" "$TAG" "$KONAME" "$TMP/$KONAME" \
           || [ $(wc -c < "$TMP/$KONAME" | tr -d ' ') -lt 10000 ]; then
            echo "ERROR=$KONAME 下载失败 (上游可能未提供该内核的 ko)"
            rm -rf "$TMP"; return 1
        fi
    done
    echo "INFO=下载 susfs_insmod"
    if ! fetch_asset "$ORDER" "$TAG" susfs_insmod "$TMP/susfs_insmod" \
       || [ $(wc -c < "$TMP/susfs_insmod" | tr -d ' ') -lt 10000 ]; then
        echo "ERROR=susfs_insmod 下载失败"
        rm -rf "$TMP"; return 1
    fi

    # 热重载: 备份 -> 卸载 -> 换文件 -> 加载
    for k in $UPKMIS; do
        cp -f "$MODDIR/kos/susfs_guard_lkm-$k.ko" "$TMP/old/" 2>/dev/null
    done
    cp -f "$MODDIR/susfs_insmod" "$TMP/old/susfs_insmod" 2>/dev/null
    echo "INFO=热重载 susfs_guard_lkm ($KVAR)"
    unload_ko
    is_loaded && echo "INFO=旧模块未能卸载, 文件已替换, 重启后生效"
    for k in $UPKMIS; do
        mv -f "$TMP/susfs_guard_lkm-$k.ko" "$MODDIR/kos/susfs_guard_lkm-$k.ko"
        chmod 644 "$MODDIR/kos/susfs_guard_lkm-$k.ko"
    done
    mv -f "$TMP/susfs_insmod" "$MODDIR/susfs_insmod"; chmod 755 "$MODDIR/susfs_insmod"
    is_loaded || OUT=$(load_ko "$MODDIR/kos/susfs_guard_lkm-$KVAR.ko" 2>&1)

    if is_loaded; then
        set_module_version "$TAG"
        write_status "😋加载成功~"
        echo "$(date '+%m-%d %H:%M:%S') OK hot-updated to $TAG ($KVAR, $SRC)" >> "$LOG"
        echo "OK=已更新到 $TAG 并完成热重载 ($KVAR)"
        rm -rf "$TMP"
        return 0
    fi

    # 加载失败: 回滚旧文件并尝试恢复
    echo "INFO=新 ko 加载失败: $OUT"
    echo "INFO=回滚到旧版本 $CUR"
    for f in "$TMP/old"/*; do
        [ -f "$f" ] || continue
        b=${f##*/}
        case "$b" in
            susfs_insmod) mv -f "$f" "$MODDIR/susfs_insmod"; chmod 755 "$MODDIR/susfs_insmod" ;;
            *.ko) mv -f "$f" "$MODDIR/kos/$b"; chmod 644 "$MODDIR/kos/$b" ;;
        esac
    done
    load_ko "$MODDIR/kos/susfs_guard_lkm-$KVAR.ko" >/dev/null 2>&1
    if is_loaded; then
        write_status "😋加载成功~"
        echo "ERROR=更新失败, 已回滚到 $CUR 并恢复加载"
    else
        write_status "😭加载失败！"
        echo "ERROR=更新失败且回滚失败, 请重启手机"
    fi
    echo "$(date '+%m-%d %H:%M:%S') ERROR hot-update to $TAG failed, rolled back" >> "$LOG"
    rm -rf "$TMP"
    return 1
}
