set -euo pipefail
if [ "${1:-}" != inner ]; then
  export WAN_TEST_SCRIPT="${BASH_SOURCE[0]}"
  unshare -Urnm bash -euo pipefail <<'ROOT'
mount --make-rprivate /
fixture_root="$PWD/network-root"
mkdir -p "$fixture_root"/{nix,dev,proc,sys,etc,run,build,tmp}
mount --rbind /nix "$fixture_root/nix"
mount --rbind /dev "$fixture_root/dev"
mount --rbind /proc "$fixture_root/proc"
mount --bind "$PWD" "$fixture_root/build"
# systemd v261.2 udev_available() requires read-only /sys in containers.
# No host sysfs or host network devices are exposed in this fixture root.
mount -t tmpfs -o ro tmpfs "$fixture_root/sys"
exec chroot "$fixture_root" bash "$WAN_TEST_SCRIPT" inner
ROOT
  exit $?
fi
cd /build
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /etc
mkdir -p /etc/systemd/network /run/systemd/netif
printf other > /run/systemd/container
printf '0123456789abcdef0123456789abcdef\n' > /etc/machine-id
printf 'root:x:0:0:root:/root:/bin/sh\nsystemd-network:x:0:0:network:/:/bin/false\n' > /etc/passwd
printf 'root:x:0:\nsystemd-network:x:0:\n' > /etc/group
cp "$NETWORK_FILE" /etc/systemd/network/40-wan0.network
cp "$NETWORKD_CONF" /etc/systemd/networkd.conf
ip link add wan0 type veth peer name server0
ip link set wan0 address 02:00:00:00:00:01
if [ "$MODE" = static ]; then
  # The provider segment lives in its own namespace: gateway G1 (primary prefix)
  # and gateway G2 (second prefix) are separate ports on one bridge. Strict
  # reverse-path filtering models provider anti-spoofing, so a reply that
  # leaves through the wrong gateway is dropped.
  unshare -n -- sleep infinity &
  UPSTREAM_PID=$!
  # Wait until unshare has left the host namespace before configuring it.
  for attempt in $(seq 1 100); do
    [ "$(readlink "/proc/$UPSTREAM_PID/ns/net")" != "$(readlink /proc/self/ns/net)" ] && break
    sleep .02
  done
  [ "$(readlink "/proc/$UPSTREAM_PID/ns/net")" != "$(readlink /proc/self/ns/net)" ]
  upstream() { nsenter -t "$UPSTREAM_PID" -n "$@"; }
  upstream ip link set lo up
  ip link set server0 netns "$UPSTREAM_PID"
  upstream ip link add br0 type bridge
  upstream ip link set server0 master br0
  for gateway in gw1 gw2; do
    upstream ip link add "$gateway" type veth peer name "${gateway}p"
    upstream ip link set "${gateway}p" master br0
    upstream ip link set "${gateway}p" up
  done
  upstream bash -c 'for conf in all gw1 gw2; do
    echo 1 > "/proc/sys/net/ipv4/conf/$conf/rp_filter"
    echo 1 > "/proc/sys/net/ipv4/conf/$conf/arp_ignore"
  done'
  upstream ip addr add 192.0.2.1/24 dev gw1
  upstream ip addr add 198.51.100.1/24 dev gw2
  upstream ip addr add 203.0.113.9/32 dev lo
  for link in br0 server0 gw1 gw2; do upstream ip link set "$link" up; done
else
  ip addr add 192.0.2.1/24 dev server0
  ip link set server0 up
fi
ip link set wan0 up
ip link set lo up
if [ "$MODE" = dhcp ]; then
  dnsmasq --no-daemon --port=0 --interface=server0 --bind-interfaces --user=root --group=root \
    --dhcp-range=192.0.2.10,192.0.2.20,255.255.255.0,1h --dhcp-option=3,192.0.2.1 \
    --dhcp-leasefile="$out/leases" --log-dhcp > "$out/dnsmasq.log" 2>&1 &
  DHCP_PID=$!
fi
SYSTEMD_LOG_LEVEL=debug "$NETWORKD" > "$out/networkd.log" 2>&1 &
NETWORKD_PID=$!
trap 'kill "$NETWORKD_PID" ${DHCP_PID:-} ${UPSTREAM_PID:-} ${HOST_SERVER_PID:-} ${UPSTREAM_SERVER_PID:-} 2>/dev/null || true' EXIT
ready=false
for attempt in $(seq 1 100); do
  if [ "$MODE" = static ]; then
    if ip -4 addr show dev wan0 | grep -q '198.51.100.5/24' && ip -4 route show table 1002 | grep -q 'default via 198.51.100.1'; then ready=true; break; fi
  elif ip -4 addr show dev wan0 | grep -q 'inet 192.0.2.1[0-9]/24'; then
    ready=true; break
  fi
  kill -0 "$NETWORKD_PID" || break
  sleep .1
done
ip -j addr show > "$out/addresses.json"
ip -j route show table all > "$out/routes.json"
ip -j rule show > "$out/rules.json"
if [ "$ready" != true ]; then cat "$out/networkd.log" >&2; exit 1; fi
if [ "$MODE" = static ]; then
  "$WAIT_ONLINE" --interface="$WAIT_INTERFACE" --timeout="$WAIT_TIMEOUT" \
    > "$out/wait-online.log" 2>&1
  for address in 192.0.2.2/24 192.0.2.3/24 192.0.2.4/24 198.51.100.5/24; do
    ip -4 addr show dev wan0 | grep -q "inet $address "
  done
  ip rule show | tee "$out/rules.log" | grep '10012:' | grep -q 'from 198.51.100.5 lookup 1002'
  if ip rule show | grep -Eq 'from 192\.0\.2\.[234] '; then
    echo 'unexpected policy rule for a primary-prefix address' >&2
    exit 1
  fi
  ip -4 route show default | tee "$out/default-route.log" | grep -q 'default via 192.0.2.1 dev wan0 .*src 192.0.2.2'
  ip route get 203.0.113.9 | tee "$out/egress-route.log" | grep -q 'via 192.0.2.1 dev wan0 src 192.0.2.2'
  ip route get 203.0.113.9 from 192.0.2.3 | tee "$out/primary-prefix-route.log" | grep -q 'via 192.0.2.1 dev wan0'
  ip route get 203.0.113.9 from 198.51.100.5 | tee "$out/source-route.log" | grep -q 'via 198.51.100.1 dev wan0 table 1002'

  python3 "$WAN_TRAFFIC" serve "$out/host-ready" \
    tcp:192.0.2.3:443 tcp:198.51.100.5:443 udp:192.0.2.4:443 udp:198.51.100.5:443 udp-pktinfo:51820 \
    > "$out/host-server.log" 2>&1 &
  HOST_SERVER_PID=$!
  upstream python3 "$WAN_TRAFFIC" serve "$out/upstream-ready" tcp-peer:203.0.113.9:8080 \
    > "$out/upstream-server.log" 2>&1 &
  UPSTREAM_SERVER_PID=$!
  for attempt in $(seq 1 100); do
    [ -e "$out/host-ready" ] && [ -e "$out/upstream-ready" ] && break
    sleep .02
  done
  if [ ! -e "$out/host-ready" ] || [ ! -e "$out/upstream-ready" ]; then
    cat "$out/host-server.log" "$out/upstream-server.log" >&2
    exit 1
  fi
  probe() { upstream python3 "$WAN_TRAFFIC" "$1" 203.0.113.9 "$2" "$3" "$4"; }
  {
    probe tcp 192.0.2.3 443 'tcp 192.0.2.3'
    probe tcp 198.51.100.5 443 'tcp 198.51.100.5'
    probe udp 192.0.2.4 443 'udp 192.0.2.4'
    probe udp 198.51.100.5 443 'udp 198.51.100.5'
    probe udp 192.0.2.4 51820 'pktinfo 192.0.2.4'
    probe udp 198.51.100.5 51820 'pktinfo 198.51.100.5'
    python3 "$WAN_TRAFFIC" tcp 0.0.0.0 203.0.113.9 8080 'peer 192.0.2.2'
  } 2>&1 | tee "$out/traffic.log"
else
  ip -4 route show default | grep -q 'via 192.0.2.1 dev wan0'
fi

printf 'carrier cycle: down\n' | tee "$out/carrier-cycle.log"
ip link set wan0 down
if [ "$MODE" = dhcp ]; then
  ip -4 addr flush dev wan0
fi
ip link set wan0 up
printf 'carrier cycle: up\n' | tee -a "$out/carrier-cycle.log"

recovered=false
for attempt in $(seq 1 100); do
  if [ "$MODE" = static ]; then
    if ip -4 addr show dev wan0 | grep -q '198.51.100.5/24' && ip -4 route show table 1002 | grep -q 'default via 198.51.100.1'; then
      recovered=true
      break
    fi
  elif ip -4 addr show dev wan0 | grep -q 'inet 192.0.2.1[0-9]/24' && ip -4 route show default | grep -q 'via 192.0.2.1 dev wan0'; then
    recovered=true
    break
  fi
  kill -0 "$NETWORKD_PID" || break
  sleep .1
done
ip -j addr show > "$out/addresses-after-carrier-cycle.json"
ip -j route show table all > "$out/routes-after-carrier-cycle.json"
if [ "$recovered" != true ]; then
  cat "$out/networkd.log" >&2
  exit 1
fi
printf 'carrier cycle: recovered\n' | tee -a "$out/carrier-cycle.log"

if [ "$MODE" = static ]; then
  # Negative control: without the source rule, second-prefix replies leave
  # through G1 and the provider segment drops them. Positive probes before and
  # during the control keep an unrelated failure from reading as a pass.
  {
    probe tcp 198.51.100.5 443 'tcp 198.51.100.5'
    probe udp 198.51.100.5 51820 'pktinfo 198.51.100.5'
  } 2>&1 | tee "$out/traffic-after-carrier-cycle.log"
  ip rule del from 198.51.100.5 lookup 1002 priority 10012
  probe tcp 192.0.2.3 443 'tcp 192.0.2.3' 2>&1 | tee -a "$out/negative-control.log"
  for check in "tcp 198.51.100.5 443 tcp 198.51.100.5" "udp 198.51.100.5 51820 pktinfo 198.51.100.5"; do
    read -r kind address port reply <<< "$check"
    if probe "$kind" "$address" "$port" "$reply" >> "$out/negative-control.log" 2>&1; then
      echo "reply without the source rule unexpectedly succeeded: $check" >&2
      exit 1
    fi
  done
  printf 'negative control: second-prefix replies dropped without the source rule\n' | tee -a "$out/negative-control.log"
  ip rule add from 198.51.100.5 lookup 1002 priority 10012
  probe tcp 198.51.100.5 443 'tcp 198.51.100.5' 2>&1 | tee -a "$out/negative-control.log"
fi
