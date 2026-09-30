#!/usr/bin/env bash
set -Eeuo pipefail
: "${out:?Nix check output is required}"
if [[ "${1:-}" != --inside ]]; then
  exec timeout --signal=TERM --kill-after=2s 35s unshare -Urn bash "$0" --inside
fi
started_ms=$(date +%s%3N)
ip link set lo up
ip address add 127.0.0.2/32 dev lo
runtime="$PWD/caddy-runtime"
mkdir -p "$runtime"
stage=namespace phase=unset failed_line=unset failed_command=unset
export XDG_CONFIG_HOME="$runtime/config" XDG_DATA_HOME="$runtime/data"
cleanup() {
  if [[ -n "${caddy_pid:-}" ]]; then
    kill "$caddy_pid" 2>/dev/null || true
    wait "$caddy_pid" 2>/dev/null || true
  fi
  rm -f /tmp/network-caddy-runtime-key.pem
}
on_exit() {
  local result=$?
  if [[ "$result" != 0 ]]; then
    printf 'FAIL phase=%s stage=%s exit=%s line=%s command=%s elapsed_ms=%s\n' "$phase" "$stage" "$result" "$failed_line" "$failed_command" "$(( $(date +%s%3N) - started_ms ))" >&2
    printf 'request host=%s expected=%s actual=%s body_bytes=%s\n' "${host:-unset}" "${expected:-unset}" "${status:-unset}" "$(wc -c < "$runtime/body" 2>/dev/null || printf 0)" >&2
    for diagnostic in "$out/adapt.log" "$out/validate.log" "${dir:-$runtime}/reload.log" "${dir:-$runtime}/requests.log" "${dir:-$runtime}/error.log" "${dir:-$runtime}/access.log" "$runtime/process.log"; do
      if [[ -f "$diagnostic" ]]; then
        printf 'diagnostic: %s (last 12 lines)\n' "$diagnostic" >&2
        tail -n 12 "$diagnostic" >&2
      fi
    done
    if [[ -f "${dir:-$out}/config.json" ]]; then
      printf 'diagnostic: actual native logging configuration\n' >&2
      jq -c '.logging' "${dir:-$out}/config.json" >&2 || true
    fi
  fi
  cleanup
  return "$result"
}
trap 'failed_command=$BASH_COMMAND; failed_line=$LINENO' ERR
trap on_exit EXIT
stage=adapt
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/network-caddy-runtime-key.pem -out /tmp/network-caddy-runtime-cert.pem -days 1 -subj /CN=fixture.invalid >/dev/null 2>&1
cp "$CADDY_CONFIG" "$out/Caddyfile"
caddy adapt --config "$CADDY_CONFIG" --adapter caddyfile > "$out/config.json" 2> "$out/adapt.log"
jq -e '[.apps.http.servers[].protocols] | all(. == ["h1","h2"])' "$out/config.json" >/dev/null
jq -e '.apps.http.servers | length == 2 and any(.[]; (.errors.routes // [] | length) == 0) and any(.[]; (.errors.routes // [] | length) > 0)' "$out/config.json" >/dev/null
jq -e '.. | objects | select(.handler? == "rate_limit")' "$out/config.json" >/dev/null
jq -e '.logging.logs.default.exclude | index("http.log.error") != null' "$out/config.json" >/dev/null
caddy validate --config "$out/config.json" > "$out/validate.log" 2>&1
stage=start
caddy run --config "$out/config.json" > "$runtime/process.log" 2>&1 &
caddy_pid=$!
request() {
  local host=$1 path=$2
  local address=127.0.0.1
  [[ "$host" != nested.fixture.invalid ]] || address=127.0.0.2
  local headers=()
  if [[ "$path" == /fail/* || "$path" == /ok/* ]]; then headers=(-H 'X-Synthetic-Audit: RAW_HEADER_AUDIT'); fi
  curl --insecure --noproxy '*' --silent --show-error --max-time 2 --path-as-is --resolve "$host:443:$address" "${headers[@]}" -o "$runtime/body" -w '%{http_code}' "https://$host$path"
}
ready=false
for _ in {1..40}; do
  if request vaultwarden.fixture.invalid /health >/dev/null 2>&1; then ready=true; break; fi
  kill -0 "$caddy_pid"
  sleep .05
done
[[ "$ready" == true ]]
auth_paths=(/identity/connect/token /identity/accounts/prelogin /identity/accounts/register)
stage=rate-limit
for path in "${auth_paths[@]}"; do
  [[ "$(request vaultwarden.fixture.invalid "$path")" == 200 ]]
  [[ "$(cat "$runtime/body")" == 'vaultwarden auth fixture' ]]
done
for _ in {1..11}; do [[ "$(request vaultwarden.fixture.invalid /identity/accounts/prelogin)" == 200 ]]; done
for path in "${auth_paths[@]}"; do [[ "$(request vaultwarden.fixture.invalid "$path")" == 429 ]]; done
[[ "$(request vaultwarden.fixture.invalid /identity/accounts/other)" == 200 ]]
echo 'Shared bucket: fourteen successes, all three paths limited; adjacent route succeeds.'
# Controls change only native encoder/writer settings in the actual adapted
# configuration. Handler routes and the production sanitized encoder remain
# authoritative; no reconstructed Caddyfile or independent redactor is used.
for phase in baseline query sanitized; do
  dir="$runtime/$phase"
  mkdir -p "$dir"
  stage=encoder-control
  jq --arg phase "$phase" --arg dir "$dir" '
    .logging.logs |= with_entries(
      if (.key == "sanitized_http_errors") then
        .value.writer = {output:"file",filename:($dir+"/error.log")} |
        if $phase == "baseline" then .value.encoder = {format:"json"}
        elif $phase == "query" then .value.encoder = {format:"filter",wrap:{format:"json"},fields:{"request>uri":{filter:"query",actions:[{type:"replace",parameter:"q",value:"REDACTED"}]}}}
        else . end
      elif any(.value.include[]?; startswith("http.log.access")) then
        .value.writer = {output:"file",filename:($dir+"/access.log")}
      else . end)
  ' "$out/config.json" > "$dir/config.json"
  stage=reload
  caddy reload --address unix//tmp/network-caddy-admin.sock --config "$dir/config.json" > "$dir/reload.log" 2>&1
  stage=requests
  for host in vaultwarden.fixture.invalid nested.fixture.invalid; do
    for uri in '/fail/RAW_PATH_AUDIT?q=RAW_QUERY_AUDIT' '/fail/ENC%4FDED_PATH_AUDIT?q=ENC%4FDED_QUERY_AUDIT' '/ok/RAW_PATH_AUDIT?q=RAW_QUERY_AUDIT'; do
      status=$(request "$host" "$uri")
      expected=500
      [[ "$uri" != /ok/* ]] || expected=200
      printf '%s expected=%s actual=%s body_bytes=%s\n' "$host" "$expected" "$status" "$(wc -c < "$runtime/body")" >> "$dir/requests.log"
      [[ "$status" == "$expected" ]]
      if [[ "$status" == 200 ]]; then [[ "$(cat "$runtime/body")" == ok ]]; else [[ ! -s "$runtime/body" ]]; fi
    done
  done
  # This ordinary public response proves access logging still records useful
  # traffic, while the synthetic private successes and errors skip access logs.
  curl --insecure --noproxy '*' --silent --show-error --fail --max-time 2 --resolve vaultwarden.fixture.invalid:443:127.0.0.1 https://vaultwarden.fixture.invalid/public > "$dir/public-body"
  [[ "$(cat "$dir/public-body")" == 'vaultwarden fixture' ]]
  stage=error-records
  for _ in {1..20}; do
    if jq -s -e 'length == 4' "$dir/error.log" >/dev/null 2>&1; then break; fi
    sleep .05
  done
  jq -s -e 'length == 4 and all(.[]; .logger | startswith("http.log.error"))' "$dir/error.log" >/dev/null
  stage=access-records
  jq -s -e 'length == 1 and .[0].request.uri == "/public" and .[0].status == 200' "$dir/access.log" >/dev/null
  if [[ "$phase" == sanitized ]]; then
    stage=sanitized-marker
    if grep -Ei 'RAW_(PATH|QUERY|HEADER)_AUDIT|ENC(%4F|O)DED_(PATH|QUERY)_AUDIT' "$dir/error.log" "$dir/access.log" "$dir/reload.log" "$dir/public-body"; then exit 1; fi
    stage=sanitized-shape
    jq -s -e 'all(.[]; (has("msg")|not) and (.request|has("uri")|not) and (.request|has("headers")|not) and (has("error")|not) and ((.first_error // {})|has("msg")|not)) and any(.[]; .status == 500 and (.err_id|length>0) and (.err_trace|length>0) and .request.method == "GET" and .request.host == "vaultwarden.fixture.invalid") and any(.[]; .first_error.status == 500 and (.first_error.err_id|length>0) and (.first_error.err_trace|length>0))' "$dir/error.log" >/dev/null
  else
    stage=control-markers
    grep -q RAW_PATH_AUDIT "$dir/error.log"
    grep -q RAW_QUERY_AUDIT "$dir/error.log"
    grep -q 'ENC%4FDED_PATH_AUDIT' "$dir/error.log"
    jq -s -e 'any(.[]; (.msg // "")|contains("/fail/RAW_PATH_AUDIT?q=RAW_QUERY_AUDIT")) and any(.[]; ((.error // "")|contains("/fail/RAW_PATH_AUDIT?q=RAW_QUERY_AUDIT")) and ((.first_error.msg // "")|contains("/fail/RAW_PATH_AUDIT?q=RAW_QUERY_AUDIT"))) and all(.[]; .request.headers["X-Synthetic-Audit"] == ["RAW_HEADER_AUDIT"])' "$dir/error.log" >/dev/null
    if [[ "$phase" == query ]]; then
      stage=query-field
      jq -s -e 'all(.[]; (.request.uri|contains("q=REDACTED")) and (.request.uri|contains("RAW_QUERY_AUDIT")|not))' "$dir/error.log" >/dev/null
    fi
  fi
  mkdir "$out/$phase"
  cp "$dir/config.json" "$dir"/*.log "$dir/public-body" "$out/$phase/"
done
cleanup
caddy_pid=
stage=complete-process-sink
if grep -Ei 'RAW_(PATH|QUERY|HEADER)_AUDIT|ENC(%4F|O)DED_(PATH|QUERY)_AUDIT' "$runtime/process.log"; then exit 1; fi
cp "$runtime/process.log" "$out/process.log"
printf 'body_ms=%s\n' "$(( $(date +%s%3N) - started_ms ))" > "$out/timing.txt"
echo 'Actual native HTTP-error policy: baseline/query leak controls; sanitized structured diagnostics pass.'
