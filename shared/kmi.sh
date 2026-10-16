# SPDX-License-Identifier: GPL-2.0-only
# 来自上游 susfs4ksu-lkm: 按内核 osrelease 从 kmis 清单选择匹配 KMI
# 清单在 "$2/kmis" (每行一个 <android版本>-<内核版本>), 新增 KMI 只需加一行
select_kmi() {
  rel="$1"
  while IFS= read -r kmi; do
    [ -n "$kmi" ] || continue
    os="${kmi%-*}"
    kver="${kmi#*-}"
    case "$rel" in
      "$kver".*-"$os"-*) echo "$kmi"; return 0 ;;
    esac
  done < "$2/kmis"
  # 内核串里有 android 标签但不匹配 = 真的不匹配, 不能当无标签处理
  case "$rel" in *android[0-9]*) return 1 ;; esac
  # 无标签内核: 仅当版本号唯一对应一个 KMI 才匹配 (5.10 / 5.15 有共享则拒绝)
  match=""
  n=0
  while IFS= read -r kmi; do
    [ -n "$kmi" ] || continue
    kver="${kmi#*-}"
    case "$rel" in "$kver".*) ;; *) continue ;; esac
    patch="${rel#"$kver".}"; patch="${patch%%-*}"
    case "$patch" in ''|*[!0-9]*) continue ;; esac
    match="$kmi"; n=$((n + 1))
  done < "$2/kmis"
  [ "$n" = 1 ] && { echo "$match"; return 0; }
  return 1
}
