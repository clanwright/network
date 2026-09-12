# shellcheck shell=bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  printf 'network bootstrap SSH renewal requires root\n' >&2
  exit 1
fi
if [ ! -e "$MARKER_PATH" ]; then
  printf 'network bootstrap SSH renewal refuses a missing or non-regular marker\n' >&2
  exit 1
fi
if ! validate_marker_file_and_path; then
  printf 'network bootstrap SSH renewal refuses unsafe marker: %s\n' "$MARKER_VALIDATION_ERROR" >&2
  exit 1
fi

temporary=$(mktemp --tmpdir="$marker_parent" .network-bootstrap-ssh.XXXXXX)
trap 'rm -f -- "$temporary"' EXIT
chmod 0600 "$temporary"
printf '%s\n' "$(( $(date +%s) + MAX_WINDOW_SECONDS ))" > "$temporary"
mv -fT -- "$temporary" "$MARKER_PATH"
trap - EXIT
"$REFRESH"
