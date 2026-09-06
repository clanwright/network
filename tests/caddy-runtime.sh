#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$PWD/caddy-runtime"
mkdir -p "$runtime_dir"
config_file="$runtime_dir/Caddyfile"
port=18080

cleanup() {
  if [[ -n "${caddy_pid:-}" ]]; then
    kill "$caddy_pid" 2>/dev/null || true
    wait "$caddy_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sed "s/@PORT@/$port/g" >"$config_file" <<'EOF'
{
  admin off
  auto_https off
  servers {
    protocols h1 h2
  }
}

http://127.0.0.1:@PORT@ {
  @vaultwardenAuth path /identity/connect/token /identity/accounts/prelogin /identity/accounts/register
  route @vaultwardenAuth {
    rate_limit {
      zone vaultwarden_auth_public {
        key {remote_host}
        events 14
        window 1m
      }
    }
    respond "vaultwarden auth fixture"
  }
  respond "vaultwarden fixture"
}
EOF

caddy fmt --overwrite "$config_file"
caddy adapt --config "$config_file" --adapter caddyfile >"$runtime_dir/config.json"
caddy validate --config "$runtime_dir/config.json"
caddy run --config "$runtime_dir/config.json" >"$runtime_dir/caddy.log" 2>&1 &
caddy_pid=$!

for _ in {1..50}; do
  if curl --fail --silent --output /dev/null "http://127.0.0.1:$port/health"; then
    break
  fi
  sleep 0.1
done
kill -0 "$caddy_pid"

for _ in {1..14}; do
  actual="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/identity/accounts/prelogin")"
  printf 'vaultwarden login response: expected=200 actual=%s\n' "$actual"
  test "$actual" = 200
done

actual="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/identity/accounts/prelogin")"
printf 'vaultwarden login response: expected=429 actual=%s\n' "$actual"
test "$actual" = 429

actual="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/identity/accounts/other")"
printf 'vaultwarden non-auth response: expected=200 actual=%s\n' "$actual"
test "$actual" = 200

cp "$runtime_dir/config.json" "$out/config.json"
cp "$runtime_dir/caddy.log" "$out/caddy.log"
