#!/usr/bin/env bash
set -Eeuo pipefail
: "${out:?Nix check output is required}"
if [[ "${1:-}" != --inside ]]; then
  exec timeout --signal=TERM --kill-after=2s 40s unshare -Urn bash "$0" --inside
fi
started_ms=$(date +%s%3N)
ip link set lo up
for address in 192.0.2.1 192.0.2.2 192.0.2.3 203.0.113.8 203.0.113.9; do ip address add "$address/32" dev lo; done
runtime="$PWD/static-runtime"
mkdir -p "$runtime/origin"
printf 'network proxy origin response\n' > "$runtime/origin/index.html"
export XDG_CONFIG_HOME="$runtime/config" XDG_DATA_HOME="$runtime/data"
cleanup() {
  for process in "${caddy_pid:-}" "${origin_pid:-}" "${dns_pid:-}"; do
    if [[ -n "$process" ]]; then kill "$process" 2>/dev/null || true; wait "$process" 2>/dev/null || true; fi
  done
  rm -f /tmp/network-static-site-key.pem "$runtime"/*.runtime "$runtime"/*.json
}
trap cleanup EXIT
stage=setup
failure() {
  local result=$? line=$1
  printf 'static fixture failed: stage=%s line=%s exit=%s\n' "$stage" "$line" "$result" >&2
  tail -n 8 "$out/requests.log" >&2 2>/dev/null || true
  cat "$out/route-summary.json" >&2 2>/dev/null || true
  exit "$result"
}
trap 'failure "$LINENO"' ERR
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/network-static-site-key.pem -out /tmp/network-static-site-cert.pem -days 1 -subj /CN=fixture.invalid >/dev/null 2>&1
proxy_password=$(openssl rand -hex 16)
export STATIC_PROXY_PASSWORD="$proxy_password"
prepare_config() {
  local source=$1 name=$2
  cp "$source" "$out/$name.public"
  # Native imports expand the one ephemeral environment credential. Retain
  # the actual adapted tree with credential values removed, not a renderer.
  caddy adapt --config "$source" --adapter caddyfile > "$runtime/$name.json" 2> "$out/$name.adapt.log"
  jq 'walk(if type == "object" then del(.auth_credentials) else . end)' "$runtime/$name.json" > "$out/$name.adapted.public.json"
}
prepare_config "$SHADOW_CADDY_CONFIG" Caddyfile.shadowed
prepare_config "$CADDY_CONFIG" Caddyfile
prepare_config "$REPLACEMENT_CADDY_CONFIG" Caddyfile.replacement
cp "$PROXY_POLICY" "$out/proxy-policy.public"
cp "$CONNECT_ROUTE" "$out/connect-route.public"
sha256sum "$out/"*.public > "$out/source-hashes.txt"
caddy version > "$out/caddy-version.txt"
jq '
  def proxies: [.. | objects | select(.handler? == "forward_proxy")];
  {policyCount:(proxies | length),uniquePolicyCount:(proxies | unique | length),
    guardedMethods:[.. | objects | select((.match? | type) == "array")
      | select((.handle | proxies | length) == 1) | .match],
    servers:[.apps.http.servers[] | {listen,routes:[.routes[] |
      {match,terminal,handlers:[.. | objects | .handler? // empty]}]}]}
' "$runtime/Caddyfile.json" > "$out/route-summary.json"
# All four attachments must contain the same complete authentication/ACL
# handler. Named routes remain terminal, preceding the catch-all, while their
# inner CONNECT attachment precedes content; each import has the exact guard.
jq -e '
  def proxies: [.. | objects | select(.handler? == "forward_proxy")];
  def guarded($method): [.. | objects | select((.match? | type) == "array") | select(.match[0].method? == [$method])
    | select((.handle | proxies | length) == 1)];
  [.apps.http.servers[] | select(.listen == ["192.0.2.1:443", "192.0.2.2:443"])] as $selected
  | [$selected[0].routes[] | select(.match?[0].host? == ["sibling.fixture.invalid", "sibling-alias.fixture.invalid"])] as $named
  | [$selected[0].routes[] | select(has("match") | not)] as $root
  | proxies as $policies
  | guarded("CONNECT") as $connect
  | ($selected | length) == 1 and ($named | length) == 1 and ($root | length) == 1
    and $selected[0].routes[0] == $named[0] and $named[0].terminal and $root[0].terminal
    and ($named[0] | proxies | length) == 1 and ($root[0] | proxies | length) == 2
    and ($policies | length) == 4 and ($policies | unique | length) == 1
    and all($policies[]; (.auth_credentials | length) == 1 and .hide_ip and .hide_via
      and .allowed_ports == [18081] and .probe_resistance.domain == "proxy.fixture.invalid"
      and .acl == [{subjects:["127.0.0.0/8"]},{subjects:["203.0.113.9/32"]},
        {allow:true,subjects:["203.0.113.8/32"]},{subjects:["all"]}])
    and ($connect | length) == 3
    and all($connect[]; .match[0].expression.expr == "{http.request.local.host} in [\"192.0.2.1\", \"192.0.2.2\"] && {http.request.local.port} == 443")
    and (guarded("GET") | length) == 1
    and ($named[0] | [.. | objects | .handler? // empty] | index("forward_proxy") < index("static_response"))
    and ($root[0] | [.. | objects | .handler? // empty] | index("forward_proxy") < index("file_server"))
' "$runtime/Caddyfile.json" > "$out/complete-policy-proof.json"
jq -e '
  [.apps.http.servers[] | select(.listen == ["192.0.2.1:443", "192.0.2.2:443"])][0].routes[0]
  | .match[0].host == ["sibling.fixture.invalid", "sibling-alias.fixture.invalid"] and .terminal
    and ([.. | objects | select(.handler? == "forward_proxy")] | length) == 0
    and any(.. | objects; .handler? == "static_response" and .body? == "sibling")
' "$runtime/Caddyfile.shadowed.json" > "$out/shadow-control-proof.json"
stage=shadowed
caddy run --config "$runtime/Caddyfile.shadowed.json" > "$out/process.log" 2>&1 &
caddy_pid=$!
caddy file-server --listen :18081 --root "$runtime/origin" --access-log > "$out/origin.log" 2>&1 &
origin_pid=$!
# The pinned Go resolver uses localhost:53 when this existing Nix sandbox has
# no resolv.conf. Answer only synthetic fixture names inside this namespace.
[[ ! -e /etc/resolv.conf ]]
dnsmasq --no-daemon --conf-file=/dev/null --no-resolv --no-hosts --bind-interfaces --listen-address=127.0.0.1 \
  --address=/fixture.invalid/203.0.113.8 --local=/fixture.invalid/ > "$runtime/dns.log" 2>&1 &
dns_pid=$!
request() {
  local host=$1 address=$2 method=$3 path=$4
  shift 4
  local methods=(-X "$method")
  [[ "$method" != HEAD ]] || methods=(--head)
  curl --insecure --noproxy '*' --silent --show-error --max-time 2 --resolve "$host:443:$address" "${methods[@]}" "$@" -D "$runtime/headers" -o "$runtime/body" "https://$host$path" -w '%{http_code}'
}
check() {
  local label=$1 expected=$2 host=$3 address=$4 method=$5 path=$6
  shift 6
  local actual
  actual=$(request "$host" "$address" "$method" "$path" "$@")
  printf '%s expected=%s actual=%s\n' "$label" "$expected" "$actual" >> "$out/requests.log"
  [[ "$actual" == "$expected" ]]
}
ready=false
for _ in {1..50}; do
  if request www.fixture.invalid 192.0.2.1 GET / >/dev/null 2>&1 && curl --noproxy '*' --silent --max-time 0.2 http://203.0.113.8:18081/ >/dev/null; then ready=true; break; fi
  kill -0 "$caddy_pid" "$origin_pid" "$dns_pid"
  sleep .05
done
[[ "$ready" == true ]]
origin_count() { jq -s '[.[] | select(.request.uri? != null)] | length' "$out/origin.log"; }
expect_origin() {
  local uri=$1 observed=false
  for _ in {1..20}; do
    if jq -s -e --arg uri "$uri" 'any(.[]; .request.uri? == $uri)' "$out/origin.log" >/dev/null; then observed=true; break; fi
    sleep .05
  done
  [[ "$observed" == true ]]
}
proxy_request() {
  local host=$1 address=$2 label=$3 method=$4 credential=${5:-} target=${6:-203.0.113.8:18081}
  local options=()
  [[ "$method" != CONNECT ]] || options+=(--proxytunnel)
  [[ -z "$credential" ]] || options+=(--proxy-user "$credential")
  : > "$runtime/proxy-body"
  curl --silent --show-error --max-time 2 --noproxy '' --proxy-insecure --proxy "https://$host:443" --resolve "$host:443:$address" "${options[@]}" -o "$runtime/proxy-body" "http://$target/?attempt=$label"
}
allow_origin() {
  local host=$1 address=$2 label=$3 method=${4:-CONNECT} target=${5:-203.0.113.8:18081} before
  before=$(origin_count)
  proxy_request "$host" "$address" "$label" "$method" "fixture:$proxy_password" "$target"
  cmp "$runtime/origin/index.html" "$runtime/proxy-body"
  expect_origin "/?attempt=$label"
  [[ "$(origin_count)" == "$((before + 1))" ]]
  printf 'authorized %s SNI=%s bind=%s target=%s originCount=%s->%s\n' "$method" "$host" "$address" "$target" "$before" "$((before + 1))" >> "$out/requests.log"
}
deny_origin() {
  local host=$1 address=$2 label=$3 credential=${4:-} target=${5:-203.0.113.8:18081} before
  before=$(origin_count)
  # Probe resistance can yield an empty decoy200 with curl exit0. Actual
  # origin absence, rather than HTTP/CONNECT status, proves non-admission.
  proxy_request "$host" "$address" "$label" CONNECT "$credential" "$target" 2> "$out/$label.stderr" || true
  if grep -q 'network proxy origin response' "$runtime/proxy-body"; then exit 1; fi
  [[ "$(origin_count)" == "$before" ]]
  jq -s -e --arg uri "/?attempt=$label" 'all(.[]; .request.uri? != $uri)' "$out/origin.log" >/dev/null
  printf 'denied SNI=%s bind=%s target=%s originCount=%s unchanged\n' "$host" "$address" "$target" "$before" >> "$out/requests.log"
}
# RED: native outer canonical/alias Host routes return sibling content before
# reaching root authentication. Exact response bytes and zero origin distinguish
# this shadow from a successful tunnel, for valid/missing/wrong credentials.
encoded=$(printf '%s' "fixture:$proxy_password" | base64 -w0)
shadowed_connect() {
  local address=$1 target=$2 credential=$3 before status
  local headers=(-H "Host: $target")
  before=$(origin_count)
  [[ "$credential" != correct ]] || headers+=(-H "Proxy-Authorization: Basic $encoded")
  [[ "$credential" != wrong ]] || headers+=(-H 'Proxy-Authorization: Basic aW52YWxpZDppbnZhbGlk')
  # This is the exact CONNECT authority/Host and cover SNI; ordinary response
  # decoding reads the native decoy's Content-Length without waiting on a tunnel.
  status=$(curl --http1.1 --insecure --noproxy '*' --silent --show-error --max-time 2 \
    --resolve "www.fixture.invalid:443:$address" -X CONNECT --request-target "$target" \
    "${headers[@]}" -o "$runtime/shadow-body" https://www.fixture.invalid/ -w '%{http_code}')
  printf sibling | cmp - "$runtime/shadow-body"
  [[ "$status" == 200 ]]
  [[ "$(origin_count)" == "$before" ]]
  printf 'RED shadow bind=%s target=%s auth=%s exact=sibling200 originCount=%s unchanged\n' "$address" "$target" "$credential" "$before" >> "$out/requests.log"
}
# Reachability controls make DNS and ACL negatives meaningful.
for address in 127.0.0.1 203.0.113.9; do
  curl --noproxy '*' --silent --show-error --max-time 2 "http://$address:18081/?attempt=reachable-$address" -o "$runtime/reachable-body"
  cmp "$runtime/origin/index.html" "$runtime/reachable-body"
  expect_origin "/?attempt=reachable-$address"
done
allow_origin www.fixture.invalid 192.0.2.1 dns-ready CONNECT dns-control.fixture.invalid:18081
for address in 192.0.2.1 192.0.2.2; do
  for target in sibling.fixture.invalid:18081 sibling-alias.fixture.invalid:18081; do
    for credential in correct missing wrong; do shadowed_connect "$address" "$target" "$credential"; done
  done
done
stage=corrected
caddy reload --force --address unix//tmp/network-static-admin.sock --config "$runtime/Caddyfile.json" > "$out/attachment-reload.log" 2>&1
for address in 192.0.2.1 192.0.2.2; do
  check 'canonical index' 200 www.fixture.invalid "$address" GET /
  cmp "$ORIGINAL_ARTIFACT/index.html" "$runtime/body"
  check 'canonical document' 200 www.fixture.invalid "$address" GET /docs/page.html
  cmp "$ORIGINAL_ARTIFACT/docs/page.html" "$runtime/body"
  check 'canonical HEAD' 200 www.fixture.invalid "$address" HEAD /
  check 'custom404' 404 www.fixture.invalid "$address" GET /missing
  cmp "$ORIGINAL_ARTIFACT/404.html" "$runtime/body"
  check 'publisher defeats static artifact' 200 www.fixture.invalid "$address" GET /published/payload
  [[ "$(cat "$runtime/body")" == publisher ]]
  check 'sibling remains host-specific' 200 sibling.fixture.invalid "$address" GET /published/payload
  [[ "$(cat "$runtime/body")" == sibling ]]
  for alias in alias.fixture.invalid second-alias.fixture.invalid; do
    for method in GET HEAD; do
      check 'alias redirect before publisher' 308 "$alias" "$address" "$method" '/published/payload?x=1&y=2'
      tr -d '\r' < "$runtime/headers" | grep -qiFx 'Location: https://www.fixture.invalid/published/payload?x=1&y=2'
    done
  done
  for header in 'Proxy-Authorization;' 'Proxy-Authorization: Basic invalid'; do
    [[ "$(request alias.fixture.invalid "$address" GET /docs/page.html -H "$header")" != 308 ]]
  done
  [[ "$(request alias.fixture.invalid "$address" CONNECT /docs/page.html)" != 308 ]]
  check 'unknown host does not reach artifact' 200 unknown.fixture.invalid "$address" GET /
  [[ ! -s "$runtime/body" ]]
  for host in www.fixture.invalid alias.fixture.invalid sibling.fixture.invalid; do
    allow_origin "$host" "$address" "auth-$host-$address"
    deny_origin "$host" "$address" "noauth-$host-$address"
    deny_origin "$host" "$address" "invalid-$host-$address" fixture:invalid
  done
  for target in www.fixture.invalid alias.fixture.invalid second-alias.fixture.invalid sibling.fixture.invalid sibling-alias.fixture.invalid; do
    allow_origin www.fixture.invalid "$address" "matching-$target-$address" CONNECT "$target:18081"
    deny_origin www.fixture.invalid "$address" "matching-noauth-$target-$address" '' "$target:18081"
    deny_origin www.fixture.invalid "$address" "matching-wrong-$target-$address" fixture:invalid "$target:18081"
  done
  deny_origin www.fixture.invalid "$address" "private-acl-$address" "fixture:$proxy_password" 127.0.0.1:18081
  deny_origin www.fixture.invalid "$address" "additional-deny-$address" "fixture:$proxy_password" 203.0.113.9:18081
done
allow_origin alias.fixture.invalid 192.0.2.1 absolute-form GET
allow_origin www.fixture.invalid 192.0.2.1 private-target-ready CONNECT private.fixture.invalid:18081
check 'private attached site ordinary GET' 200 private.fixture.invalid 192.0.2.3 GET /
[[ "$(cat "$runtime/body")" == private-site ]]
deny_origin private.fixture.invalid 192.0.2.3 private-bind-correct "fixture:$proxy_password" private.fixture.invalid:18081
check 'independent artifact' 200 secondary.fixture.invalid 192.0.2.3 GET /
cmp "$REPLACEMENT_ARTIFACT/index.html" "$runtime/body"
check 'independent fallback404' 404 secondary.fixture.invalid 192.0.2.3 GET /missing
printf '404 Not Found\n' | cmp - "$runtime/body"
deny_origin secondary.fixture.invalid 192.0.2.3 cover-valid "fixture:$proxy_password"
# Site-level log_skip must precede both the publisher and alias responses.
stage=logging
publisher_token=network-static-fixture-sensitive-token
for host in www.fixture.invalid alias.fixture.invalid second-alias.fixture.invalid; do
  expected=200
  [[ "$host" == www.fixture.invalid ]] || expected=308
  check 'publisher token remains unlogged' "$expected" "$host" 192.0.2.1 GET "/published/payload?token=$publisher_token"
done
check 'ordinary access log positive' 200 www.fixture.invalid 192.0.2.1 GET '/docs/page.html?logging-control'
logged=false
for _ in {1..20}; do
  if jq -s -e 'any(.[]; .request.uri? == "/docs/page.html?logging-control")' "$out/process.log" >/dev/null; then logged=true; break; fi
  sleep .05
done
[[ "$logged" == true ]]
if grep -qF "$publisher_token" "$out/process.log"; then
  echo 'publisher token reached the process sink' >&2; exit 1
fi
# Native Caddy must reject a full reload while any selected bind is absent,
# and keep the old public configuration on its still-present listener.
stage=atomic-reload
ip address del 192.0.2.2/32 dev lo
if caddy reload --force --address unix//tmp/network-static-admin.sock --config "$runtime/Caddyfile.replacement.json" > "$out/rejected-reload.log" 2>&1; then
  echo 'reload with absent listener unexpectedly succeeded' >&2; exit 1
fi
grep -F 'cannot assign requested address' "$out/rejected-reload.log"
for _ in {1..20}; do
  check 'failed reload retains old public artifact' 200 www.fixture.invalid 192.0.2.1 GET /
  cmp "$ORIGINAL_ARTIFACT/index.html" "$runtime/body"
done
ip address add 192.0.2.2/32 dev lo
caddy reload --force --address unix//tmp/network-static-admin.sock --config "$runtime/Caddyfile.replacement.json" > "$out/reload.log" 2>&1
for address in 192.0.2.1 192.0.2.2; do
  check 'same-host replacement' 200 www.fixture.invalid "$address" GET /
  cmp "$REPLACEMENT_ARTIFACT/index.html" "$runtime/body"
  check 'old document removed' 404 www.fixture.invalid "$address" GET /docs/page.html
  printf '404 Not Found\n' | cmp - "$runtime/body"
  check 'replacement alias GET redirect' 308 alias.fixture.invalid "$address" GET '/docs/page.html?x=1&y=2'
  tr -d '\r' < "$runtime/headers" | grep -qiFx 'Location: https://www.fixture.invalid/docs/page.html?x=1&y=2'
  check 'replacement alias HEAD redirect' 308 alias.fixture.invalid "$address" HEAD '/docs/page.html?x=1'
  tr -d '\r' < "$runtime/headers" | grep -qiFx 'Location: https://www.fixture.invalid/docs/page.html?x=1'
  allow_origin www.fixture.invalid "$address" "replacement-$address"
done
allow_origin alias.fixture.invalid 192.0.2.1 replacement-absolute-form GET
cleanup
caddy_pid='' origin_pid='' dns_pid=''
if grep -FRl -- "$proxy_password" "$out"; then exit 1; fi
if grep -FRl -- "$encoded" "$out"; then exit 1; fi
double_encoded=$(printf '%s' "$encoded" | base64 -w0)
if grep -FRl -- "$double_encoded" "$out"; then exit 1; fi
printf 'body_ms=%s\n' "$(( $(date +%s%3N) - started_ms ))" > "$out/timing.txt"
jq -n --arg config "$CADDY_CONFIG" --arg shadow "$SHADOW_CADDY_CONFIG" \
  --arg replacement "$REPLACEMENT_CADDY_CONFIG" \
  --arg package "$(command -v caddy)" --argjson originCount "$(origin_count)" \
  '{passed:true,caddyPackage:$package,config:$config,shadowControl:$shadow,replacement:$replacement,
    redRequests:12,matchingCanonicalAndAliasPositives:10,originCount:$originCount,
    sharedPolicy:"one native imported complete handler; root CONNECT once; named CONNECT method+local bind443 guards",
    absoluteFormHTTP:"separate root-only GET coverage using the same policy; not a VPN CONNECT API promise",
    privateBind:"matching private target reaches public origin from selected bind, but never from attached private bind with correct SNI/auth",
    limits:["ordinary process fixture; no system-manager or deployed consumer evidence"]}' > "$out/report.json"
echo 'Native CONNECT shadow RED/GREEN, full authentication/ACL, aliases, logging, exact artifacts and atomic reload passed.'
