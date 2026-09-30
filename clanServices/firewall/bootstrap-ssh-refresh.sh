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

fail_closed() {
  reason=$1
  printf 'network bootstrap SSH disabled: %s\n' "$reason" >&2
  # An invalid marker is a successfully converged closed state. A real nftables
  # failure still propagates through `set -e`.
  clear_set
  exit 0
}

if [ ! -e "$MARKER_PATH" ]; then
  clear_set
  exit 0
fi

if ! validate_marker_file_and_path; then
  fail_closed "$MARKER_VALIDATION_ERROR"
fi

IFS= read -r expires < "$MARKER_PATH" || fail_closed 'marker is empty'
case "$expires" in
  ''|*[!0-9]*) fail_closed 'marker deadline is not a decimal Unix epoch' ;;
  0|0*) fail_closed 'marker deadline is not canonical decimal' ;;
esac
[ "${#expires}" -le 18 ] || fail_closed 'marker deadline is outside the supported integer range'
expected_size=$(( ${#expires} + 1 ))
[ "$(stat -c %s -- "$MARKER_PATH")" -eq "$expected_size" ] \
  || fail_closed 'marker must contain exactly one newline-terminated deadline'

now=$(date +%s)
remaining=$((10#$expires - now))
if (( remaining <= 0 )); then
  clear_set
  exit 0
fi
(( remaining <= MAX_WINDOW_SECONDS )) || fail_closed 'marker deadline exceeds the configured window'

"$NFT" -f - <<EOF
flush set $table_family $table_name $set_name
add element $table_family $table_name $set_name { $PUBLIC_IPV4 timeout ${remaining}s }
EOF
