# shellcheck shell=bash
set -euo pipefail

if ! unshare -Urn true; then
  echo 'BLOCKED: builder does not support unprivileged user/network namespaces' >&2
  exit 1
fi

unshare -Urn bash -euo pipefail <<'INNER'
client_pid=
listeners=
udp_client_pid=
cleanup() {
  [ -z "$listeners" ] || kill $listeners 2>/dev/null || true
  [ -z "$udp_client_pid" ] || kill "$udp_client_pid" 2>/dev/null || true
  [ -z "$client_pid" ] || kill "$client_pid" 2>/dev/null || true
}
trap cleanup EXIT

nft -f - <<'EOF'
table inet unrelated_runtime {
  chain retained {
    counter comment "must survive private ingress lifecycle"
  }
}
table inet broad_accept {
  chain input {
    type filter hook input priority filter - 20; policy accept;
    accept comment "broad native or Tailscale-style accept"
  }
}
EOF

unshare -n -- sleep infinity &
client_pid=$!
for _ in $(seq 1 50); do
  nsenter -t "$client_pid" -n ip link set lo up 2>/dev/null && break
  sleep 0.02
done
nsenter -t "$client_pid" -n ip link show lo >/dev/null
ip link set lo up

ip link add public0 type veth peer name client0
ip link set client0 netns "$client_pid"
ip address add 192.0.2.2/24 dev public0
ip address add 203.0.113.2/32 dev public0
ip link set public0 up
nsenter -t "$client_pid" -n ip address add 192.0.2.3/24 dev client0
nsenter -t "$client_pid" -n ip link set client0 up
nsenter -t "$client_pid" -n ip route add 203.0.113.2/32 via 192.0.2.2 dev client0

ip link add fixture0 type veth peer name client1
ip link set client1 netns "$client_pid"
ip address add 198.51.100.2/24 dev fixture0
ip address add 192.0.2.2/32 dev fixture0
ip link set fixture0 up
nsenter -t "$client_pid" -n ip address add 198.51.100.3/24 dev client1
nsenter -t "$client_pid" -n ip link set client1 up
nsenter -t "$client_pid" -n ip route add 192.0.2.2/32 via 198.51.100.2 dev client1 table 100
nsenter -t "$client_pid" -n ip rule add from 198.51.100.3/32 table 100 priority 100

# Bind listeners before testing packets through both ingress paths.
for address in 192.0.2.2 198.51.100.2 203.0.113.2; do
  for port in 22 80 443 444; do
    nc -4 -l -k -s "$address" -p "$port" >/dev/null 2>&1 & listeners="$listeners $!"
  done
done
sleep 0.2

python3 -u - <<'PY' >/dev/null 2>&1 & listeners="$listeners $!"
import socket
server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
server.bind(("192.0.2.2", 443))
while True:
    message, peer = server.recvfrom(1024)
    server.sendto(message, peer)
PY
sleep 0.1

# Establish a UDP flow before installing the guard. The same socket and
# five-tuple must stop receiving responses after the guard appears.
nft -f "$LAST_RULES"
nsenter -t "$client_pid" -n python3 - <<'PY' & udp_client_pid=$!
import os
import pathlib
import socket
import time
out = pathlib.Path(os.environ["out"])
client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
client.bind(("192.0.2.3", 0))
client.settimeout(2)
client.sendto(b"before-guard", ("192.0.2.2", 443))
assert client.recvfrom(1024)[0] == b"before-guard"
(out / "established-ready").touch()
while not (out / "install-complete").exists():
    time.sleep(0.02)
client.settimeout(1)
client.sendto(b"after-guard", ("192.0.2.2", 443))
try:
    client.recvfrom(1024)
except socket.timeout:
    (out / "established-blocked").touch()
else:
    raise AssertionError("previously established UDP flow bypassed private ingress guard")
PY
for _ in $(seq 1 100); do
  [ ! -e "$out/established-ready" ] || break
  sleep 0.02
done
[ -e "$out/established-ready" ]

probe_public() { nsenter -t "$client_pid" -n nc -4 -z -w 1 -s 192.0.2.3 "$1" "$2"; }
probe_trusted() { nsenter -t "$client_pid" -n nc -4 -z -w 1 -s 198.51.100.3 "$1" "$2"; }
probe_udp() {
  nsenter -t "$client_pid" -n python3 - "$1" <<'PY'
import socket
import sys
client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
client.bind((sys.argv[1], 0))
client.settimeout(1)
client.sendto(b"private-ingress-packet", ("192.0.2.2", 443))
message, _ = client.recvfrom(1024)
assert message == b"private-ingress-packet"
PY
}
expect_failure() {
  if "$@"; then
    echo "unexpected success: $*" >&2
    exit 1
  fi
}

nft -f "$APPLY_RULES"
nft -f "$APPLY_RULES"
touch "$out/install-complete"
wait "$udp_client_pid"
[ -e "$out/established-blocked" ]
udp_client_pid=
nft list table inet network-edge-policy > "$out/private-policy.nft"
grep -q 'network: private IPv4 ingress' "$out/private-policy.nft"
grep -q 'network: reject non-loopback HTTP' "$out/private-policy.nft"

expect_failure probe_public 192.0.2.2 443
expect_failure probe_public 192.0.2.2 22
probe_public 203.0.113.2 443
probe_trusted 192.0.2.2 443
probe_trusted 192.0.2.2 22
expect_failure probe_trusted 192.0.2.2 444
expect_failure probe_trusted 198.51.100.2 22
expect_failure probe_trusted 198.51.100.2 443
expect_failure probe_trusted 192.0.2.2 80
nc -4 -z -w 1 192.0.2.2 443
probe_udp 198.51.100.3
expect_failure probe_udp 192.0.2.3

guard_packets() {
  nft list chain inet network-edge-policy input_guard | awk '/ip daddr 192.0.2.2/ { for (i = 1; i <= NF; i++) if ($i == "packets") { print $(i + 1); exit } }'
}
before_icmp="$(guard_packets)"
expect_failure nsenter -t "$client_pid" -n ping -c 1 -W 1 -I 192.0.2.3 192.0.2.2
after_icmp="$(guard_packets)"
[ "$after_icmp" -gt "$before_icmp" ]

# A broad native accept at filter priority cannot override the earlier guard.
nft -f - <<'EOF'
table inet broad_stateful_accept {
  chain input {
    type filter hook input priority filter; policy accept;
    ct state established,related accept
    tcp dport 443 accept
    udp dport 443 accept
  }
}
EOF
expect_failure probe_public 192.0.2.2 443
expect_failure probe_udp 192.0.2.3

nft -f "$ONE_REMOVED_RULES"
expect_failure probe_public 192.0.2.2 443
probe_trusted 192.0.2.2 443
nft -f "$REMOVED_RULES"
probe_public 192.0.2.2 443
probe_udp 192.0.2.3
expect_failure probe_trusted 198.51.100.2 443
nft -f "$LAST_RULES"
probe_public 192.0.2.2 443
expect_failure probe_public 192.0.2.2 80
nft list table inet unrelated_runtime > "$out/unrelated-after-last-removal.nft"
nft list table inet broad_accept > "$out/broad-accept-after-last-removal.nft"

# Native nftables reload deletes tables from the previous generation when the
# last claim disappears and rejectHttp is false.
nft -f "$DEFAULT_CLAIM_RULES"
expect_failure probe_public 192.0.2.2 443
nft -f "$DEFAULT_EMPTY_RULES"
expect_failure nft list table inet network-edge-policy >/dev/null 2>&1
probe_public 192.0.2.2 443
nft list table inet unrelated_runtime > "$out/unrelated-after-table-removal.nft"
INNER
