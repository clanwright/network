#!/usr/bin/env bash
set -euo pipefail

if ! unshare -Urn true; then
  echo 'BLOCKED: builder does not support unprivileged user/network namespaces' >&2
  exit 1
fi

unshare -Urn bash -euo pipefail <<'INNER'
ip link set lo up

runtime_dir="$PWD/static-site-runtime"
mkdir -p "$runtime_dir"
export XDG_CONFIG_HOME="$runtime_dir/xdg-config"
export XDG_DATA_HOME="$runtime_dir/xdg-data"
cert_file=/tmp/network-static-site-cert.pem
key_file=/tmp/network-static-site-key.pem
main_host=www.fixture.invalid
alias_host=alias.fixture.invalid
secondary_host=secondary.fixture.invalid
main_origin="https://$main_host"
alias_origin="https://$alias_host"
secondary_origin="https://$secondary_host"
curl_args=(--insecure --noproxy '*' --silent --show-error)

cleanup() {
  if [[ -n "${caddy_pid:-}" ]]; then
    kill "$caddy_pid" 2>/dev/null || true
    wait "$caddy_pid" 2>/dev/null || true
  fi
  if [[ -n "${origin_pid:-}" ]]; then
    kill "$origin_pid" 2>/dev/null || true
    wait "$origin_pid" 2>/dev/null || true
  fi
  rm -f "$cert_file" "$key_file"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key_file" -out "$cert_file" -days 1 -subj /CN=fixture.invalid >/dev/null 2>&1
sed \
  -e "s#/var/log/caddy/main-site.log#$runtime_dir/main.log#g" \
  -e "s#/var/log/caddy/secondary-site.log#$runtime_dir/secondary.log#g" \
  "$CADDY_CONFIG" > "$runtime_dir/Caddyfile.public"

# The proxy credential exists only in the disposable build directory. Neither
# this Caddyfile nor its adapted JSON is copied into the check output.
proxy_password="$(openssl rand -hex 16)"
awk -v password="$proxy_password" '
  { print }
  /^[[:space:]]*forward_proxy[[:space:]]*\{[[:space:]]*$/ {
    print "    basic_auth fixture " password
    print "    probe_resistance proxy-fixture.invalid"
    print "    ports 18081"
    print "    disable_insecure_upstreams_check"
    print "    acl {"
    print "        allow 127.0.0.1/32"
    print "        deny all"
    print "    }"
    found = 1
  }
  END { if (!found) exit 1 }
' "$runtime_dir/Caddyfile.public" > "$runtime_dir/Caddyfile.runtime"
caddy adapt --config "$runtime_dir/Caddyfile.runtime" --adapter caddyfile > "$runtime_dir/config.runtime.json"
caddy validate --config "$runtime_dir/config.runtime.json"
caddy run --config "$runtime_dir/config.runtime.json" > "$runtime_dir/caddy.log" 2>&1 &
caddy_pid=$!

request() {
  local host="$1" method="$2" path="$3"
  shift 3
  local method_args=(-X "$method")
  if [[ "$method" = HEAD ]]; then
    method_args=(--head)
  fi
  curl "${curl_args[@]}" --resolve "$host:443:127.0.0.1" "${method_args[@]}" -D "$runtime_dir/headers" -o "$runtime_dir/body" "$@" "https://$host$path" -w '%{http_code}'
}
expect_request() {
  local label="$1" expected="$2" host="$3" method="$4" path="$5"
  shift 5
  local actual
  actual="$(request "$host" "$method" "$path" "$@")"
  printf '%s: expected=%s actual=%s\n' "$label" "$expected" "$actual"
  test "$actual" = "$expected"
}
for _ in {1..50}; do
  if curl "${curl_args[@]}" --resolve "$main_host:443:127.0.0.1" --fail -o /dev/null "$main_origin/" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
kill -0 "$caddy_pid"

expect_request 'main index' 200 "$main_host" GET /
test "$(cat "$runtime_dir/body")" = 'network static index v1'
expect_request 'main document' 200 "$main_host" GET /docs/page.html
test "$(cat "$runtime_dir/body")" = 'network static document v1'
expect_request 'main HEAD' 200 "$main_host" HEAD /
expect_request 'custom missing page' 404 "$main_host" GET /missing
test "$(cat "$runtime_dir/body")" = 'network custom missing page'

expect_request 'alias redirect' 308 "$alias_host" GET '/docs/page.html?x=1&y=2'
tr -d '\r' < "$runtime_dir/headers" | grep -qiFx "Location: https://$main_host/docs/page.html?x=1&y=2"
expect_request 'alias HEAD redirect' 308 "$alias_host" HEAD '/docs/page.html?x=1'
tr -d '\r' < "$runtime_dir/headers" | grep -qiFx "Location: https://$main_host/docs/page.html?x=1"
for header in 'Proxy-Authorization;' 'Proxy-Authorization: Basic invalid'; do
  actual="$(request "$alias_host" GET /docs/page.html -H "$header")"
  printf 'alias proxy header bypass: status=%s\n' "$actual"
  test "$actual" != 308
done
actual="$(request "$alias_host" CONNECT /docs/page.html)"
printf 'alias CONNECT bypass: status=%s\n' "$actual"
test "$actual" != 308

expect_request 'secondary replacement index' 200 "$secondary_host" GET /
test "$(cat "$runtime_dir/body")" = 'network static index v2'
expect_request 'secondary fallback missing page' 404 "$secondary_host" GET /missing
test "$(cat "$runtime_dir/body")" = '404 Not Found'
actual="$(request unknown.fixture.invalid GET /)"
printf 'unknown host isolation: status=%s\n' "$actual"
! grep -q 'network static index' "$runtime_dir/body"

mkdir -p "$runtime_dir/origin"
printf '%s\n' 'network proxy origin response' > "$runtime_dir/origin/index.html"
python3 -u -m http.server 18081 --bind 127.0.0.1 --directory "$runtime_dir/origin" > "$runtime_dir/origin.log" 2>&1 &
origin_pid=$!
for _ in {1..50}; do
  if curl --noproxy '*' --silent --fail -o /dev/null http://127.0.0.1:18081/; then
    break
  fi
  sleep 0.1
done
kill -0 "$origin_pid"
origin_requests_before="$(wc -l < "$runtime_dir/origin.log")"
proxy_options=(
  --silent --show-error --proxy-insecure --max-time 5
  --proxy "https://$alias_host:443"
  --resolve "$alias_host:443:127.0.0.1"
  --noproxy ''
)
for auth_case in missing invalid; do
  auth_options=()
  if [[ "$auth_case" = invalid ]]; then
    auth_options=(--proxy-user 'fixture:invalid')
  fi
  : > "$runtime_dir/unauthorized-body"
  if curl "${proxy_options[@]}" --proxytunnel "${auth_options[@]}" \
      -o "$runtime_dir/unauthorized-body" \
      http://127.0.0.1:18081/ > /dev/null 2> "$runtime_dir/unauthorized-error"; then
    :
  fi
  ! grep -q 'network proxy origin response' "$runtime_dir/unauthorized-body"
  test "$(wc -l < "$runtime_dir/origin.log")" = "$origin_requests_before"
  printf '%s proxy credentials did not reach origin\n' "$auth_case"
done
proxy_body="$(curl --silent --show-error --fail --proxy-insecure --proxytunnel \
  --proxy "https://127.0.0.1:443" --proxy-user "fixture:$proxy_password" \
  --noproxy '' http://127.0.0.1:18081/)"
test "$proxy_body" = 'network proxy origin response'
echo 'authenticated CONNECT reached local origin'
proxy_body="$(curl "${proxy_options[@]}" --fail --proxy-user "fixture:$proxy_password" \
  http://127.0.0.1:18081/)"
test "$proxy_body" = 'network proxy origin response'
echo 'authenticated absolute-form GET through alias endpoint reached local origin'

# Retain the public generated declaration and operation logs. Runtime files
# with the ephemeral proxy credential stay in the disposable build directory.
cp "$runtime_dir/Caddyfile.public" "$out/Caddyfile.public"
cp "$runtime_dir/caddy.log" "$out/caddy.log"
cp "$runtime_dir/origin.log" "$out/origin.log"
INNER
