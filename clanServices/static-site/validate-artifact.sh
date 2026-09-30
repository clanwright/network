#!/usr/bin/env bash
set -euo pipefail

site_artifact=$1
output=$2

if [ ! -d "$site_artifact" ] || [ -L "$site_artifact" ]; then
  echo 'Static site artifact must be a directory.' >&2
  exit 1
fi
if [ -n "$(find "$site_artifact" ! -type f ! -type d -print -quit)" ]; then
  echo 'Static site artifact contains a link or unsupported entry.' >&2
  exit 1
fi
if [ -n "$(find "$site_artifact" -type f ! -perm -444 -print -quit)" ] ||
   [ -n "$(find "$site_artifact" -type d ! -perm -111 -print -quit)" ]; then
  echo 'Static site artifact contains unreadable content.' >&2
  exit 1
fi
if [ ! -f "$site_artifact/index.html" ] || [ ! -r "$site_artifact/index.html" ] ||
   [ ! -s "$site_artifact/index.html" ]; then
  echo 'Static site artifact requires a nonempty readable regular index.html.' >&2
  exit 1
fi
if [ -e "$site_artifact/404.html" ] &&
   { [ ! -f "$site_artifact/404.html" ] || [ ! -r "$site_artifact/404.html" ] ||
     [ ! -s "$site_artifact/404.html" ]; }; then
  echo 'Static site artifact has an invalid 404.html.' >&2
  exit 1
fi

mkdir -p "$output"
cp -a "$site_artifact"/. "$output"/
if [ ! -e "$output/404.html" ]; then
  chmod u+w "$output"
  printf '404 Not Found\n' > "$output/404.html"
fi
chmod -R a+rX "$output"
