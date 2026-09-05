set -euo pipefail
# Private keys exist solely in the ephemeral build namespace and are never
# copied into the output artifact. Logs contain public identifiers only.
unshare -Urnm bash -euo pipefail <<'INNER'
mount --make-rprivate /
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /etc
printf "root:x:0:0:root:/:/bin/sh\nacme:x:0:0:acme:/:/bin/false\n" > /etc/passwd
printf "root:x:0:\nacme:x:0:\n" > /etc/group
printf "127.0.0.1 localhost\n" > /etc/hosts
mkdir -p /run/acme /tmp/accounts /tmp/certificates /tmp/out
ip link set lo up
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/ca.key -out /tmp/ca.crt -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
export LEGO_CA_CERTIFICATES=/tmp/ca.crt
cat > /tmp/pebble.json <<'JSON'
{"pebble":{"listenAddress":"127.0.0.1:14000","managementListenAddress":"127.0.0.1:15000","certificate":"/tmp/ca.crt","privateKey":"/tmp/ca.key","httpPort":5002,"tlsPort":5001,"strict":false}}
JSON
PEBBLE_VA_NOSLEEP=1 pebble -config /tmp/pebble.json -dnsserver 127.0.0.1:10053 > "$out/pebble.log" 2>&1 &
PEBBLE_PID=$!
dnsmasq --no-daemon --port=10053 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts --address=/fixture.invalid/127.0.0.1 --user=root --group=root > "$out/dns.log" 2>&1 &
DNS_PID=$!
trap 'kill "$PEBBLE_PID" "$DNS_PID" 2>/dev/null || true' EXIT
for attempt in $(seq 1 100); do
  if curl --silent --fail --cacert /tmp/ca.crt https://localhost:14000/dir >/dev/null; then break; fi
  sleep .1
done
# Capture the notification emitted by the unmodified native post-renew script.
# This process test does not claim a booted systemd consumer was restarted.
mkdir /tmp/bin
cat > /tmp/bin/systemctl <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$out/notifications.log"
SH
chmod +x /tmp/bin/systemctl
export PATH="/tmp/bin:$PATH"
sed "s|/var/lib/acme/fixture|/tmp/out|g" "$POST_SCRIPT" > /tmp/native-postrun
cd /tmp
bash "$ORDER_SCRIPT"
test -e out/renewed
openssl x509 -in out/cert.pem -noout -serial > "$out/initial-serial.txt"
bash /tmp/native-postrun
test ! -e out/renewed
test "$(wc -l < "$out/notifications.log")" = 1
# No renewed marker must produce no duplicate notification.
bash /tmp/native-postrun
test "$(wc -l < "$out/notifications.log")" = 1
bash "$ORDER_SCRIPT"
test -e out/renewed
openssl x509 -in out/cert.pem -noout -serial > "$out/renewed-serial.txt"
! cmp -s "$out/initial-serial.txt" "$out/renewed-serial.txt"
bash /tmp/native-postrun
test "$(wc -l < "$out/notifications.log")" = 2
grep -q '^--no-block try-reload-or-restart fixture-consumer.service$' "$out/notifications.log"
cp out/cert.pem "$out/public-certificate.pem"
INNER
