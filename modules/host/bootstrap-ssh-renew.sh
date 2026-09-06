# shellcheck shell=bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  printf 'network bootstrap SSH renewal requires root\n' >&2
  exit 1
fi
if [ ! -e "$MARKER_PATH" ] || [ -L "$MARKER_PATH" ] || [ ! -f "$MARKER_PATH" ]; then
  printf 'network bootstrap SSH renewal refuses a missing or non-regular marker\n' >&2
  exit 1
fi
if [ "$(stat -c %u -- "$MARKER_PATH")" != 0 ]; then
  printf 'network bootstrap SSH renewal refuses a marker not owned by root\n' >&2
  exit 1
fi
marker_mode=$(stat -c %a -- "$MARKER_PATH")
if (( (8#$marker_mode & 0022) != 0 )); then
  printf 'network bootstrap SSH renewal refuses a group/world-writable marker\n' >&2
  exit 1
fi

marker_parent=$(dirname -- "$MARKER_PATH")
canonical_parent=$(realpath -e -- "$marker_parent")
if [ "$canonical_parent" != "$marker_parent" ]; then
  printf 'network bootstrap SSH renewal refuses an unsafe marker parent\n' >&2
  exit 1
fi
directory=$marker_parent
while :; do
  # `/` cannot be replaced through a parent directory.  User namespaces may
  # intentionally leave its host owner unmapped while mapping the fixture path.
  [ "$directory" = / ] && break
  directory_mode=$(stat -c %a -- "$directory")
  if [ -L "$directory" ] || [ ! -d "$directory" ] \
    || [ "$(stat -c %u -- "$directory")" != 0 ] \
    || (( (8#$directory_mode & 0022) != 0 && (8#$directory_mode & 01000) == 0 )); then
    printf 'network bootstrap SSH renewal refuses an unsafe marker parent\n' >&2
    exit 1
  fi
  directory=$(dirname -- "$directory")
done

temporary=$(mktemp --tmpdir="$marker_parent" .network-bootstrap-ssh.XXXXXX)
trap 'rm -f -- "$temporary"' EXIT
chmod 0600 "$temporary"
printf '%s\n' "$(( $(date +%s) + MAX_WINDOW_SECONDS ))" > "$temporary"
mv -fT -- "$temporary" "$MARKER_PATH"
trap - EXIT
"$REFRESH"
