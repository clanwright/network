# shellcheck shell=bash
set -euo pipefail

table_family=inet
table_name=nixos-fw
set_name=bootstrap_ssh_v4

clear_set() {
  "$NFT" -f - <<EOF
flush set $table_family $table_name $set_name
EOF
}

deny() {
  reason=$1
  clear_set
  printf 'network bootstrap SSH disabled: %s\n' "$reason" >&2
  return 1
}

if [ ! -e "$MARKER_PATH" ]; then
  clear_set
  exit 0
fi

[ ! -L "$MARKER_PATH" ] || deny 'marker is a symlink'
[ -f "$MARKER_PATH" ] || deny 'marker is not a regular file'
[ "$(stat -c %u -- "$MARKER_PATH")" = 0 ] || deny 'marker is not owned by root'

marker_mode=$(stat -c %a -- "$MARKER_PATH")
(( (8#$marker_mode & 0022) == 0 )) || deny 'marker is group/world writable'

marker_parent=$(dirname -- "$MARKER_PATH")
canonical_parent=$(realpath -e -- "$marker_parent") || deny 'marker parent does not exist'
[ "$canonical_parent" = "$marker_parent" ] || deny 'marker parent traverses a symlink or non-canonical path'
directory=$marker_parent
while :; do
  # `/` has no parent through which it can be replaced.  Its host ownership is
  # also intentionally unmapped in the isolated user-namespace runtime check.
  [ "$directory" = / ] && break
  [ ! -L "$directory" ] && [ -d "$directory" ] || deny 'marker path contains a non-directory or symlink'
  [ "$(stat -c %u -- "$directory")" = 0 ] || deny 'marker path contains a directory not owned by root'
  directory_mode=$(stat -c %a -- "$directory")
  if (( (8#$directory_mode & 0022) != 0 && (8#$directory_mode & 01000) == 0 )); then
    deny 'marker path contains a directory writable by non-root without the sticky bit'
  fi
  directory=$(dirname -- "$directory")
done

IFS= read -r expires < "$MARKER_PATH" || deny 'marker is empty'
case "$expires" in
  ''|*[!0-9]*) deny 'marker deadline is not a decimal Unix epoch' ;;
  0|0*) deny 'marker deadline is not canonical decimal' ;;
esac
[ "${#expires}" -le 18 ] || deny 'marker deadline is outside the supported integer range'
expected_size=$(( ${#expires} + 1 ))
[ "$(stat -c %s -- "$MARKER_PATH")" -eq "$expected_size" ] \
  || deny 'marker must contain exactly one newline-terminated deadline'

now=$(date +%s)
remaining=$((10#$expires - now))
if (( remaining <= 0 )); then
  clear_set
  exit 0
fi
(( remaining <= MAX_WINDOW_SECONDS )) || deny 'marker deadline exceeds the configured window'

"$NFT" -f - <<EOF
flush set $table_family $table_name $set_name
add element $table_family $table_name $set_name { $PUBLIC_IPV4 timeout ${remaining}s }
EOF
