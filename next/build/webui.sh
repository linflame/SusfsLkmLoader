#!/system/bin/sh
# WebUI 后端: webui.sh info | check <源> | update <源> | set_source <源>
MODDIR=${0%/*}
. "$MODDIR/updater.sh"

case "$1" in
    info)
        V=$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1 | tr -d '\r')
        U=$(cat "$MODDIR/upstream_version" 2>/dev/null | tr -d '\r')
        K=$(cat "$MODDIR/kernel_version" 2>/dev/null | tr -d '\r')
        L=0; is_loaded && L=1
        S=$(cat "$MODDIR/update_source" 2>/dev/null | tr -d '\r')
        case "$S" in gitee|github) ;; *) S="gitee" ;; esac
        echo "VERSION=$V"
        echo "SUSFS=$U"
        echo "KERNEL=$K"
        echo "LOADED=$L"
        echo "SOURCE=$S"
        ;;
    check)      do_check "$2" ;;
    update)     do_update "$2" ;;
    set_source)
        case "$2" in
            gitee|github) echo "$2" > "$MODDIR/update_source"; echo "OK=$2" ;;
            *) echo "ERROR=非法源: $2"; exit 1 ;;
        esac ;;
    *) echo "ERROR=未知命令: $1"; exit 1 ;;
esac
