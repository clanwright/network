# shellcheck shell=bash disable=SC2034
# Shared private validator for bootstrap SSH marker file and path ownership.
MARKER_VALIDATION_ERROR=

marker_invalid() {
  MARKER_VALIDATION_ERROR=$1
  return 1
}

validate_marker_file_and_path() {
  if [ -L "$MARKER_PATH" ]; then
    marker_invalid 'marker is a symlink'
    return
  fi
  if [ ! -f "$MARKER_PATH" ]; then
    marker_invalid 'marker is not a regular file'
    return
  fi
  if ! marker_uid=$(stat -c %u -- "$MARKER_PATH"); then
    marker_invalid 'marker metadata cannot be read'
    return
  fi
  if [ "$marker_uid" != 0 ]; then
    marker_invalid 'marker is not owned by root'
    return
  fi

  if ! marker_mode=$(stat -c %a -- "$MARKER_PATH"); then
    marker_invalid 'marker metadata cannot be read'
    return
  fi
  if (( (8#$marker_mode & 0022) != 0 )); then
    marker_invalid 'marker is group/world writable'
    return
  fi

  marker_parent=$(dirname -- "$MARKER_PATH")
  if ! canonical_parent=$(realpath -e -- "$marker_parent"); then
    marker_invalid 'marker parent does not exist'
    return
  fi
  if [ "$canonical_parent" != "$marker_parent" ]; then
    marker_invalid 'marker parent traverses a symlink or non-canonical path'
    return
  fi

  directory=$marker_parent
  while :; do
    # `/` has no parent through which it can be replaced. Its host ownership is
    # also intentionally unmapped in the isolated user-namespace runtime check.
    [ "$directory" = / ] && break
    if [ -L "$directory" ] || [ ! -d "$directory" ]; then
      marker_invalid 'marker path contains a non-directory or symlink'
      return
    fi
    if ! directory_uid=$(stat -c %u -- "$directory"); then
      marker_invalid 'marker path metadata cannot be read'
      return
    fi
    if [ "$directory_uid" != 0 ]; then
      marker_invalid 'marker path contains a directory not owned by root'
      return
    fi
    if ! directory_mode=$(stat -c %a -- "$directory"); then
      marker_invalid 'marker path metadata cannot be read'
      return
    fi
    if (( (8#$directory_mode & 0022) != 0 && (8#$directory_mode & 01000) == 0 )); then
      marker_invalid 'marker path contains a directory writable by non-root without the sticky bit'
      return
    fi
    directory=$(dirname -- "$directory")
  done
}
