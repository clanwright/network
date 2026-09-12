#!/usr/bin/env bash
set -euo pipefail

if ! unshare -Urn true; then
  echo 'BLOCKED: builder does not support unprivileged user/network namespaces' >&2
  exit 1
fi

unshare -Urn bash -euo pipefail <<'INNER'
ip link set lo up

runtime_dir="$PWD/caddy-runtime"
config_file="$runtime_dir/Caddyfile"
cert_file=/tmp/network-caddy-runtime-cert.pem
key_file=/tmp/network-caddy-runtime-key.pem
port=18080
origin="https://vaultwarden.fixture.invalid:$port"
mkdir -p "$runtime_dir"
cp "$CADDY_CONFIG" "$config_file"
export XDG_CONFIG_HOME="$runtime_dir/xdg-config"
export XDG_DATA_HOME="$runtime_dir/xdg-data"
curl_args=(--insecure --noproxy '*' --resolve "vaultwarden.fixture.invalid:$port:127.0.0.1" --silent)

cleanup() {
  if [[ -n "${caddy_pid:-}" ]]; then
    kill "$caddy_pid" 2>/dev/null || true
    wait "$caddy_pid" 2>/dev/null || true
  fi
  if [[ -s "$runtime_dir/caddy.log" ]]; then
    cat "$runtime_dir/caddy.log"
  fi
  rm -f "$cert_file" "$key_file"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key_file" -out "$cert_file" -days 1 -subj /CN=vaultwarden.fixture.invalid >/dev/null 2>&1
caddy adapt --config "$config_file" --adapter caddyfile >"$runtime_dir/config.json"
grep -qF '"handler":"forward_proxy"' "$runtime_dir/config.json"
grep -qF '"handler":"rate_limit"' "$runtime_dir/config.json"
caddy validate --config "$runtime_dir/config.json"
caddy run --config "$runtime_dir/config.json" >"$runtime_dir/caddy.log" 2>&1 &
caddy_pid=$!

for _ in {1..50}; do
  if curl "${curl_args[@]}" --fail --output /dev/null "$origin/health"; then
    break
  fi
  sleep 0.1
done
kill -0 "$caddy_pid"

auth_paths=(
  /identity/connect/token
  /identity/accounts/prelogin
  /identity/accounts/register
)
for path in "${auth_paths[@]}"; do
  response="$(curl "${curl_args[@]}" --write-out $'\n%{http_code}' "$origin$path")"
  body="${response%$'\n'*}"
  actual="${response##*$'\n'}"
  printf 'vaultwarden auth response: path=%s expected=200 actual=%s\n' "$path" "$actual"
  test "$actual" = 200
  test "$body" = "vaultwarden auth fixture"
done

for _ in {1..11}; do
  actual="$(curl "${curl_args[@]}" --output /dev/null --write-out '%{http_code}' "$origin/identity/accounts/prelogin")"
  printf 'vaultwarden auth response: path=/identity/accounts/prelogin expected=200 actual=%s\n' "$actual"
  test "$actual" = 200
done

for path in "${auth_paths[@]}"; do
  actual="$(curl "${curl_args[@]}" --output /dev/null --write-out '%{http_code}' "$origin$path")"
  printf 'vaultwarden limited response: path=%s expected=429 actual=%s\n' "$path" "$actual"
  test "$actual" = 429
done

actual="$(curl "${curl_args[@]}" --output /dev/null --write-out '%{http_code}' "$origin/identity/accounts/other")"
printf 'vaultwarden non-auth response: expected=200 actual=%s\n' "$actual"
test "$actual" = 200

cp "$runtime_dir/config.json" "$out/config.json"
cp "$runtime_dir/caddy.log" "$out/caddy.log"
cp "$config_file" "$out/Caddyfile"
INNER
