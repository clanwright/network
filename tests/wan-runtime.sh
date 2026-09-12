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
ip addr add 192.0.2.1/24 dev server0
ip link set server0 up
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
trap 'kill "$NETWORKD_PID" ${DHCP_PID:-} 2>/dev/null || true' EXIT
ready=false
for attempt in $(seq 1 100); do
  if [ "$MODE" = static ]; then
    if ip -4 addr show dev wan0 | grep -q '192.0.2.3/24' && ip -4 route show table 100 | grep -q 'default via 192.0.2.1'; then ready=true; break; fi
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
  ip -4 addr show dev wan0 | grep -q '192.0.2.2/24'
  ip -4 addr show dev wan0 | grep -q '192.0.2.3/24'
  ip rule show | grep '10010:' | grep -q 'from 192.0.2.3 lookup 100'
  ip route get 198.51.100.1 from 192.0.2.3 | tee "$out/source-route.log" | grep -q 'via 192.0.2.1 dev wan0 table 100'
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
    if ip -4 addr show dev wan0 | grep -q '192.0.2.3/24' && ip -4 route show table 100 | grep -q 'default via 192.0.2.1'; then
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
