#!/usr/bin/env bash
set -euo pipefail
: "${out:?Nix check output is required}"
# The recording systemctl entry point reuses this parseable script. It invokes
# an actual Caddy reload, while preserving the exact native notification args.
if [[ "${1:-}" == --systemctl ]]; then
  shift
  printf '%s\n' "$*" >> "$out/notifications.log"
  case " $* " in
    *' caddy.service '*) caddy reload --address unix//tmp/network-acme-admin.sock --config /tmp/Caddyfile --force >> "$out/caddy-reload.log" 2>&1 ;;
  esac
  exit 0
fi
if [[ "${1:-}" != --inside ]]; then
  exec timeout --signal=TERM --kill-after=2s 40s unshare -Urnm bash "$0" --inside
fi
started_ms=$(date +%s%3N)
mount --make-rprivate /
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /etc
printf 'root:x:0:0:root:/:/bin/sh\nacme:x:0:0:acme:/:/bin/false\ncaddy:x:0:0:caddy:/:/bin/false\n' > /etc/passwd
printf 'root:x:0:\nacme:x:0:caddy\ncaddy:x:0:\n' > /etc/group
printf '127.0.0.1 localhost\n' > /etc/hosts
mkdir -p /run/acme /tmp/accounts /tmp/certificates /tmp/out /tmp/bin
ip link set lo up
cleanup() {
  for process in "${pebble_pid:-}" "${dns_pid:-}" "${caddy_pid:-}"; do
    if [[ -n "$process" ]]; then kill "$process" 2>/dev/null || true; wait "$process" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT
# Private keys remain solely in the disposable mount namespace. Only public
# certificate/serial evidence and operation logs are copied to the result.
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/ca.key -out /tmp/ca.crt -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
export LEGO_CA_CERTIFICATES=/tmp/ca.crt
printf '%s\n' '{"pebble":{"listenAddress":"127.0.0.1:14000","managementListenAddress":"127.0.0.1:15000","certificate":"/tmp/ca.crt","privateKey":"/tmp/ca.key","httpPort":5002,"tlsPort":5001,"strict":false}}' > /tmp/pebble.json
PEBBLE_VA_NOSLEEP=1 pebble -config /tmp/pebble.json -dnsserver 127.0.0.1:10053 > "$out/pebble.log" 2>&1 &
pebble_pid=$!
dnsmasq --no-daemon --port=10053 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts --address=/fixture.invalid/127.0.0.1 --user=root --group=root > "$out/dns.log" 2>&1 &
dns_pid=$!
ready=false
for _ in {1..100}; do
  if curl --silent --fail --max-time 0.2 --cacert /tmp/ca.crt https://localhost:14000/dir >/dev/null; then ready=true; break; fi
  kill -0 "$pebble_pid" "$dns_pid"
  sleep .05
done
[[ "$ready" == true ]]
curl --silent --fail --max-time 2 --cacert /tmp/ca.crt https://localhost:15000/roots/0 > /tmp/issued-ca.crt
openssl x509 -in /tmp/issued-ca.crt -noout -subject >/dev/null
printf '#!%s\nexec %s %q --systemctl "$@"\n' "$BASH" "$BASH" "$0" > /tmp/bin/systemctl
chmod +x /tmp/bin/systemctl
export PATH="/tmp/bin:$PATH"
sed 's|/var/lib/acme/stable-id|/tmp/out|g' "$POST_SCRIPT" > /tmp/native-postrun
sed 's|/var/lib/acme/stable-id|/tmp/out|g' "$CADDY_CONFIG" > /tmp/Caddyfile
cp /tmp/Caddyfile "$out/Caddyfile"
cd /tmp
bash "$ORDER_SCRIPT"
[[ -e out/renewed ]]
openssl x509 -in out/cert.pem -noout -serial > "$out/initial-serial.txt"
caddy run --config /tmp/Caddyfile > "$out/caddy.log" 2>&1 &
caddy_pid=$!
ready=false
for _ in {1..100}; do
  if curl --silent --fail --max-time 0.2 --noproxy '*' --resolve fixture.invalid:8443:127.0.0.1 --cacert /tmp/issued-ca.crt https://fixture.invalid:8443/ >/dev/null; then ready=true; break; fi
  kill -0 "$caddy_pid"
  sleep .05
done
[[ "$ready" == true ]]
served_serial() {
  timeout --kill-after=1s 3s openssl s_client -connect 127.0.0.1:8443 -servername fixture.invalid -CAfile /tmp/issued-ca.crt </dev/null 2>/dev/null | openssl x509 -noout -serial
}
served_serial > "$out/served-initial-serial.txt"
cmp "$out/initial-serial.txt" "$out/served-initial-serial.txt"
bash /tmp/native-postrun
[[ ! -e out/renewed ]]
[[ "$(wc -l < "$out/notifications.log")" == 1 ]]
bash /tmp/native-postrun
[[ "$(wc -l < "$out/notifications.log")" == 1 ]]
# Renew the current native account directly. No historical layout conversion
# or certificate-state compatibility adapter is recreated by this fixture.
bash "$ORDER_SCRIPT"
[[ -e out/renewed ]]
openssl x509 -in out/cert.pem -noout -serial > "$out/renewed-serial.txt"
if cmp -s "$out/initial-serial.txt" "$out/renewed-serial.txt"; then exit 1; fi
bash /tmp/native-postrun
[[ ! -e out/renewed ]]
[[ "$(wc -l < "$out/notifications.log")" == 2 ]]
grep -Fxq -- "--no-block try-reload-or-restart $EXPECTED_RELOADS" "$out/notifications.log"
served_serial > "$out/served-renewed-serial.txt"
cmp "$out/renewed-serial.txt" "$out/served-renewed-serial.txt"
if cmp -s "$out/served-initial-serial.txt" "$out/served-renewed-serial.txt"; then exit 1; fi
bash /tmp/native-postrun
[[ "$(wc -l < "$out/notifications.log")" == 2 ]]
cp out/cert.pem "$out/public-certificate.pem"
printf 'body_ms=%s\n' "$(( $(date +%s%3N) - started_ms ))" > "$out/timing.txt"
echo 'Native issuance, renewal marker lifecycle, exact notification and renewed served TLS passed.'
