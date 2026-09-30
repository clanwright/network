#!/usr/bin/env bash
set -Eeuo pipefail

# Re-execution exposes every stage to shell syntax checks. The build supplies
# native networkd configuration and executables from its evaluated consumer.
case "${1:-}" in
  reply-tcp) printf 'tcp %s\n' "${NCAT_LOCAL_ADDR:?}"; exit ;;
  reply-peer) printf 'peer %s\n' "${NCAT_REMOTE_ADDR:?}"; exit ;;
  reply-udp)
    read -r -t 2 request
    [ "$request" = probe ]
    printf 'udp %s\n' "$2"
    exit
    ;;
  reply-udp-peer)
    read -r -t 2 request
    [ "$request" = probe ]
    printf 'peer %s\n' "${SOCAT_PEERADDR:?}"
    exit
    ;;
  root)
    mount --make-rprivate /
    fixture_root="$PWD/network-root"
    mkdir -p "$fixture_root"/{nix,dev,proc,sys,etc,run,build,tmp}
    mount --rbind /nix "$fixture_root/nix"
    mount --rbind /dev "$fixture_root/dev"
    mount --rbind /proc "$fixture_root/proc"
    mount --bind "$PWD" "$fixture_root/build"
    # Pinned systemd's udev_available() supports containers with read-only
    # sysfs. Host sysfs and host network devices are absent from this root.
    mount -t tmpfs -o ro tmpfs "$fixture_root/sys"
    exec chroot "$fixture_root" bash "$WAN_TEST_SCRIPT" inner
    ;;
  inner) ;;
  *)
    export WAN_TEST_SCRIPT="${BASH_SOURCE[0]}"
    exec timeout --kill-after=2 100 unshare -Urnm bash "$WAN_TEST_SCRIPT" root
    ;;
esac

cd /build
out=${out:?}
MODE=${MODE:?}
started_ms=$(date +%s%3N)
pids=()
failure() {
  local status=$1 line=$2 command=$3 pipeline=$4 log
  # Keep the original failure and expose only isolated, public fixture state.
  # A failed diagnostic must not replace the command that actually failed.
  trap - ERR
  set +e
  printf 'WAN fixture failure mode=%s status=%s line=%s command=%q pipeline=%s\n' \
    "$MODE" "$status" "$line" "$command" "$pipeline" >&2
  {
    printf 'WAN fixture links:\n'
    timeout --kill-after=1 3 ip -details link show
    printf 'WAN fixture IPv4 addresses:\n'
    timeout --kill-after=1 3 ip -4 address show
    printf 'WAN fixture IPv4 routes:\n'
    timeout --kill-after=1 3 ip -4 route show table all
    printf 'WAN fixture IPv4 policy:\n'
    timeout --kill-after=1 3 ip -4 rule show
    for log in generated.network generated-networkd.conf networkd.log wait-online.log \
      dhcp-server.log upstream-namespace.log private-namespace.log transport-namespace.log \
      marked-routing.log marked-socat.log; do
      if [ -f "$out/$log" ]; then
        printf 'WAN fixture log %s (last 80 lines):\n' "$log"
        tail -n 80 "$out/$log"
      fi
    done
  } 2>&1 | tee "$out/failure-state.log" >&2
  exit "$status"
}
trap 'failure "$?" "$LINENO" "$BASH_COMMAND" "${PIPESTATUS[*]}"' ERR
cleanup() {
  status=$?
  trap - EXIT
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  printf 'body elapsed_ms=%s exit=%s\n' "$(( $(date +%s%3N) - started_ms ))" "$status" | tee "$out/timing.log"
  exit "$status"
}
trap cleanup EXIT
run() { timeout --kill-after=1 5 "$@"; }
start() {
  local log=$1
  shift
  timeout --kill-after=1 90 "$@" > "$out/$log" 2>&1 &
  pids+=("$!")
  last_pid=$!
}
wait_for() {
  local label=$1
  shift
  for (( attempt=0; attempt<100; attempt++ )); do
    if "$@"; then return; fi
    if [ -n "${networkd_pid:-}" ] && ! kill -0 "$networkd_pid" 2>/dev/null; then break; fi
    sleep .1
  done
  printf 'timed out: %s\n' "$label" >&2
  [ ! -f "$out/networkd.log" ] || cat "$out/networkd.log" >&2
  return 1
}
namespace_ready() {
  [ -e "/proc/$1/ns/net" ] && [ "$(readlink "/proc/$1/ns/net")" != "$(readlink /proc/self/ns/net)" ]
}
new_namespace() {
  # unshare execs the finite holder, so this PID names the new namespace rather
  # than a timeout supervisor that remains in the original namespace.
  unshare -n sleep 90 > "$out/$1-namespace.log" 2>&1 &
  last_pid=$!
  pids+=("$last_pid")
  wait_for "$1 namespace" namespace_ready "$last_pid"
}
upstream() { run nsenter -t "$upstream_pid" -n "$@"; }
private() { run nsenter -t "$private_pid" -n "$@"; }
transport() { run nsenter -t "$transport_pid" -n "$@"; }
here() { run "$@"; }
snapshot() {
  run ip -j addr show > "$out/addresses$1.json"
  run ip -j route show table all > "$out/routes$1.json"
  run ip -j rule show > "$out/rules$1.json"
}
route_assert() {
  local label=$1 predicate=$2
  shift 2
  run ip -4 -details -j route get "$@" | tee "$out/$label.json" |
    jq -e "length == 1 and (.[0] | $predicate)"
}

mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /etc
mkdir -p /etc/systemd/network /run/systemd/netif
printf other > /run/systemd/container
printf '0123456789abcdef0123456789abcdef\n' > /etc/machine-id
printf 'root:x:0:0:root:/root:/bin/sh\nsystemd-network:x:0:0:network:/:/bin/false\n' > /etc/passwd
printf 'root:x:0:\nsystemd-network:x:0:\n' > /etc/group
cp "$NETWORK_FILE" /etc/systemd/network/40-wan0.network
cp "$NETWORKD_CONF" /etc/systemd/networkd.conf
cp "$NETWORK_FILE" "$out/generated.network"
cp "$NETWORKD_CONF" "$out/generated-networkd.conf"
bash_bin=$(command -v bash)

run ip link add wan0 type veth peer name server0
run ip link set wan0 address 02:00:00:00:00:01
run ip link set lo up
if [ "$MODE" = static ]; then
  # Strict reverse-path checks on separate gateway ports model a provider
  # refusing second-prefix replies sent through the primary gateway.
  new_namespace upstream
  upstream_pid=$last_pid
  upstream ip link set lo up
  run ip link set server0 netns "$upstream_pid"
  upstream ip link add br0 type bridge
  upstream ip link set server0 master br0
  for gateway in gw1 gw2; do
    upstream ip link add "$gateway" type veth peer name "${gateway}p"
    upstream ip link set "${gateway}p" master br0
    upstream ip link set "${gateway}p" up
  done
  upstream sysctl -qw net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.gw1.rp_filter=1 \
    net.ipv4.conf.gw2.rp_filter=1 net.ipv4.conf.all.arp_ignore=1 \
    net.ipv4.conf.gw1.arp_ignore=1 net.ipv4.conf.gw2.arp_ignore=1
  upstream ip addr add 192.0.2.1/24 dev gw1
  upstream ip addr add 198.51.100.1/24 dev gw2
  upstream ip addr add 203.0.113.9/32 dev lo
  for link in br0 server0 gw1 gw2; do upstream ip link set "$link" up; done
else
  run ip addr add 192.0.2.1/24 dev server0
  run ip link set server0 up
  start dhcp-server.log dnsmasq --no-daemon --conf-file=/dev/null --port=0 \
    --interface=server0 --bind-interfaces --user=root --group=root \
    --dhcp-range=192.0.2.10,192.0.2.20,255.255.255.0,1h --dhcp-option=3,192.0.2.1 \
    --dhcp-leasefile="$out/leases" --log-dhcp
fi
run ip link set wan0 up
start networkd.log env SYSTEMD_LOG_LEVEL=debug "$NETWORKD"
networkd_pid=$last_pid
configured() {
  if [ "$MODE" = static ]; then
    ip -4 addr show dev wan0 | grep -q 'inet 198.51.100.5/24 ' &&
      ip -4 route show table 1002 | grep -q 'default via 198.51.100.1'
  else
    ip -4 addr show dev wan0 | grep -q 'inet 192.0.2.1[0-9]/24 ' &&
      ip -4 route show default | grep -q 'via 192.0.2.1 dev wan0'
  fi
}
wait_for 'native networkd configuration' configured
snapshot ''

# Connected sockets accept only the contacted response source. TCP peer
# responders additionally report the source address observed by the server.
tcp_probe() {
  local runner=$1 source=$2 destination=$3 port=$4 expected=$5 response
  response=$("$runner" ncat --recv-only --source "$source" --wait 2 --idle-timeout 2 "$destination" "$port")
  [ "$response" = "$expected" ] || {
    printf 'TCP %s -> %s:%s: got <%s>, want <%s>\n' "$source" "$destination" "$port" "$response" "$expected" >&2
    return 1
  }
  printf 'TCP %s -> %s:%s: %s\n' "$source" "$destination" "$port" "$response"
}
udp_probe() {
  local runner=$1 source=$2 destination=$3 port=$4 expected=$5 response
  response=$(printf 'probe\n' | "$runner" socat -t .3 -T 2 - "UDP4:$destination:$port,bind=$source")
  [ "$response" = "$expected" ] || {
    printf 'UDP %s -> %s:%s: got <%s>, want <%s>\n' "$source" "$destination" "$port" "$response" "$expected" >&2
    return 1
  }
  printf 'UDP %s -> %s:%s: %s\n' "$source" "$destination" "$port" "$response"
}
dns_probe() {
  local destination=$1 response
  response=$(upstream dig -b 203.0.113.9 "@$destination" -p 5353 wan.fixture.test A +time=1 +tries=1 +noall +answer +stats)
  printf '%s\n' "$response"
  printf '%s\n' "$response" | grep -Eq '^wan\.fixture\.test\.[[:space:]]+[0-9]+[[:space:]]+IN[[:space:]]+A[[:space:]]+192\.0\.2\.99$' || return 1
  printf '%s\n' "$response" | grep -Fq ";; SERVER: $destination#5353($destination) (UDP)"
}
tcp_listener() {
  local runner=$1 address=$2 port=$3 mode=$4 log=$5
  listen "$runner" "$log" ncat --listen --keep-open --max-conns 8 --idle-timeout 3 \
    --exec "$bash_bin $WAN_TEST_SCRIPT $mode" "$address" "$port"
}
udp_listener() {
  local runner=$1 address=$2 port=$3 mode=$4 log=$5
  listen "$runner" "$log" socat -T 3 "UDP4-RECVFROM:$port,bind=$address,reuseaddr,fork" \
    "EXEC:$bash_bin $WAN_TEST_SCRIPT $mode $address"
}
# Listeners have a 90-second lifetime bound rather than the request wrapper's
# five-second bound. All child processes are also terminated by cleanup.
listen() {
  local runner=$1 log=$2
  shift 2
  case "$runner" in
    host_listener) start "$log" "$@" ;;
    upstream_listener) start "$log" nsenter -t "$upstream_pid" -n "$@" ;;
    private_listener) start "$log" nsenter -t "$private_pid" -n "$@" ;;
    transport_listener) start "$log" nsenter -t "$transport_pid" -n "$@" ;;
  esac
}

if [ "$MODE" = static ]; then
  : "${WAIT_COMMAND:?generated static wait-online ExecStart is required}"
  read -r -a wait_command <<< "$WAIT_COMMAND"
  timeout --kill-after=1 65 "${wait_command[@]}" > "$out/wait-online.log" 2>&1
  for address in 192.0.2.2/24 192.0.2.3/24 192.0.2.4/24 198.51.100.5/24; do
    run ip -4 addr show dev wan0 | grep -q "inet $address "
  done
  run ip -4 rule show > "$out/rules.log"
  # Native rule metadata includes proto static. Assert the actual JSON fields
  # rather than depending on the order or end of a human-readable line.
  jq -e '
    ([.[] | select(.priority == 10012)] | length == 1) and
    ([.[] | select(.priority == 10012 and .src == "198.51.100.5" and
      .table == "1002" and .protocol == "static")] | length == 1) and
    ([.[] | select(.priority == 10000)] | length == 1) and
    ([.[] | select(.priority == 10000 and .src == "all" and
      .table == "main" and .suppress_prefixlen == 0 and .protocol == "static")] | length == 1) and
    all(.[]; .src != "192.0.2.2" and .src != "192.0.2.3" and .src != "192.0.2.4")
  ' "$out/rules.json"
  run ip -4 -j route show default | tee "$out/default-route.json" | jq -e '
    length == 1 and (.[0] | .dst == "default" and .gateway == "192.0.2.1" and
      .dev == "wan0" and .prefsrc == "192.0.2.2" and .protocol == "static")
  '
  route_assert egress-route '.dst == "203.0.113.9" and .gateway == "192.0.2.1" and .dev == "wan0" and .table == "main" and .prefsrc == "192.0.2.2"' 203.0.113.9
  route_assert primary-prefix-route '.dst == "203.0.113.9" and .from == "192.0.2.3" and .gateway == "192.0.2.1" and .dev == "wan0" and .table == "main"' 203.0.113.9 from 192.0.2.3
  route_assert source-route '.dst == "203.0.113.9" and .from == "198.51.100.5" and .gateway == "198.51.100.1" and .dev == "wan0" and .table == "1002"' 203.0.113.9 from 198.51.100.5
  route_assert local-route '.type == "local" and .dst == "198.51.100.5" and .table == "local"' 198.51.100.5 from 198.51.100.5

  for address in 192.0.2.3 198.51.100.5; do tcp_listener host_listener "$address" 443 reply-tcp "tcp-$address.log"; done
  for address in 192.0.2.4 198.51.100.5; do udp_listener host_listener "$address" 443 reply-udp "udp-$address.log"; done
  tcp_listener upstream_listener 203.0.113.9 8080 reply-peer upstream-tcp.log
  udp_listener upstream_listener 203.0.113.9 8443 reply-udp-peer upstream-udp.log
  # No interface/listen-address binding: native wildcard UDP replies must use
  # the destination address contacted by the request's connected dig socket.
  start wildcard-dns.log dnsmasq --no-daemon --conf-file=/dev/null --port=5353 \
    --no-hosts --no-resolv --user=root --group=root --address=/wan.fixture.test/192.0.2.99 --log-queries
  sockets_ready() {
    ss -lnut | grep -q '0.0.0.0:5353 ' && ss -lnt | grep -q '198.51.100.5:443 ' &&
      ss -lnu | grep -q '198.51.100.5:443 ' && upstream ss -lnt | grep -q '203.0.113.9:8080 ' &&
      upstream ss -lnu | grep -q '203.0.113.9:8443 '
  }
  wait_for 'packaged socket responders' sockets_ready
  traffic() {
    tcp_probe upstream 203.0.113.9 192.0.2.3 443 'tcp 192.0.2.3'
    tcp_probe upstream 203.0.113.9 198.51.100.5 443 'tcp 198.51.100.5'
    udp_probe upstream 203.0.113.9 192.0.2.4 443 'udp 192.0.2.4'
    udp_probe upstream 203.0.113.9 198.51.100.5 443 'udp 198.51.100.5'
    dns_probe 192.0.2.4
    dns_probe 198.51.100.5
    tcp_probe here 0.0.0.0 203.0.113.9 8080 'peer 192.0.2.2'
    udp_probe here 0.0.0.0 203.0.113.9 8443 'peer 192.0.2.2'
  }
  traffic 2>&1 | tee "$out/traffic.log"
  tcp_probe here 198.51.100.5 198.51.100.5 443 'tcp 198.51.100.5' | tee "$out/local-traffic.log"

  # Explicit routes/selectors represent consumer private and transport paths;
  # no address-range bypass is invented by this fixture or the production API.
  new_namespace private
  private_pid=$last_pid
  new_namespace transport
  transport_pid=$last_pid
  for peer in private transport; do
    pid_name="${peer}_pid"
    run ip link add "${peer}0" type veth peer name "${peer}p"
    run ip link set "${peer}p" netns "${!pid_name}"
    run ip link set "${peer}0" up
    "$peer" ip link set "${peer}p" up
    "$peer" ip link set lo up
    "$peer" ip route add 198.51.100.5/32 dev "${peer}p"
    "$peer" sysctl -qw net.ipv4.conf.all.rp_filter=0
  done
  run sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.private0.rp_filter=0 net.ipv4.conf.transport0.rp_filter=0
  private ip addr add 10.77.0.9/32 dev lo
  transport ip addr add 100.100.0.9/32 dev lo
  transport ip addr add 203.0.113.9/32 dev lo
  run ip route add 10.77.0.9/32 dev private0
  run ip route add 100.100.0.9/32 dev transport0 table 52
  # Standard Linux Tailscale selectors (base 5200 + 10/30/50/70). Marked
  # transport bypasses table 52; applicable unmarked selectors precede WAN.
  run ip rule add priority 5210 fwmark 0x80000/0xff0000 lookup main
  run ip rule add priority 5230 fwmark 0x80000/0xff0000 lookup default
  run ip rule add priority 5250 fwmark 0x80000/0xff0000 type unreachable
  run ip rule add priority 5270 lookup 52
  tcp_listener private_listener 10.77.0.9 8080 reply-peer private-tcp.log
  tcp_listener transport_listener 100.100.0.9 8080 reply-peer transport-tcp.log
  tcp_listener transport_listener 203.0.113.9 8080 reply-peer transport-public-tcp.log
  selectors_ready() {
    private ss -lnt | grep -q '10.77.0.9:8080 ' && transport ss -lnt | grep -q '100.100.0.9:8080 ' &&
      transport ss -lnt | grep -q '203.0.113.9:8080 '
  }
  wait_for 'private and transport responders' selectors_ready
  run ip -4 rule show > "$out/selector-rules.log"
  route_assert private-route '.dst == "10.77.0.9" and .from == "198.51.100.5" and .dev == "private0" and .table == "main"' 10.77.0.9 from 198.51.100.5
  route_assert transport-route '.dst == "100.100.0.9" and .from == "198.51.100.5" and .dev == "transport0" and .table == "52"' 100.100.0.9 from 198.51.100.5
  {
    tcp_probe here 198.51.100.5 10.77.0.9 8080 'peer 198.51.100.5'
    tcp_probe here 198.51.100.5 100.100.0.9 8080 'peer 198.51.100.5'
    run ip route add 203.0.113.9/32 dev transport0 table 52
    tcp_probe here 198.51.100.5 203.0.113.9 8080 'peer 198.51.100.5'
    route_assert marked-route '.dst == "203.0.113.9" and .gateway == "192.0.2.1" and .dev == "wan0" and .table == "main" and .prefsrc == "192.0.2.2" and .mark == 524288' 203.0.113.9 mark 0x80000
    {
      run sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter \
        net.ipv4.conf.wan0.rp_filter net.ipv4.conf.all.src_valid_mark \
        net.ipv4.conf.wan0.src_valid_mark
      run ip route get 203.0.113.9 from 192.0.2.2
      upstream ip route get 192.0.2.2 from 203.0.113.9
    } | tee "$out/marked-routing.log"
    # Pinned Socat's setsockopt-int runs after connect. Set SOL_SOCKET/SO_MARK
    # (1/36) in its pre-connect socket phase; DALAN i encodes a native integer.
    marked=$(run socat -d -d -d -d -T 2 - \
      'TCP4:203.0.113.9:8080,connect-timeout=2,setsockopt-socket=1:36:i524288' \
      </dev/null 2> "$out/marked-socat.log")
    [ "$marked" = 'peer 192.0.2.2' ]
    printf 'marked transport TCP: %s\n' "$marked"
    run ip route del 203.0.113.9/32 dev transport0 table 52
    tcp_probe here 198.51.100.5 203.0.113.9 8080 'peer 198.51.100.5'
  } 2>&1 | tee "$out/selector-traffic.log"
fi

printf 'carrier cycle: peer down\n' | tee "$out/carrier-cycle.log"
if [ "$MODE" = static ]; then upstream ip link set server0 down; else run ip link set server0 down; fi
withdrawn() {
  # wan0 stays administratively up. Only native withdrawal after observed peer
  # carrier loss can pass; there is no manual address flush or fast local cycle.
  ! ip -o link show wan0 | grep -q 'LOWER_UP' && ! ip -4 addr show dev wan0 | grep -q 'inet ' &&
    ! ip -4 route show default | grep -q 'dev wan0' &&
    { [ "$MODE" != static ] || ! ip -4 route show table 1002 | grep -q 'default'; }
}
wait_for 'carrier loss and native address/route withdrawal' withdrawn
snapshot '-carrier-down'
printf 'carrier cycle: carrier absent, addresses and defaults withdrawn\n' | tee -a "$out/carrier-cycle.log"
if [ "$MODE" = static ]; then upstream ip link set server0 up; else run ip link set server0 up; fi
wait_for 'native networkd carrier recovery' configured
snapshot '-after-carrier-cycle'
printf 'carrier cycle: native configuration recovered\n' | tee -a "$out/carrier-cycle.log"
if [ "$MODE" = static ]; then
  timeout --kill-after=1 65 "${wait_command[@]}" > "$out/wait-online-after-carrier-cycle.log" 2>&1
  traffic 2>&1 | tee "$out/traffic-after-carrier-cycle.log"
  # Positive checks around actual source-rule removal distinguish provider
  # anti-spoofing from an unrelated responder/network failure.
  run ip rule del from 198.51.100.5 lookup 1002 priority 10012
  route_assert negative-route '.dst == "203.0.113.9" and .from == "198.51.100.5" and .gateway == "192.0.2.1" and .dev == "wan0" and .table == "main"' 203.0.113.9 from 198.51.100.5
  tcp_probe upstream 203.0.113.9 192.0.2.3 443 'tcp 192.0.2.3' | tee "$out/negative-control.log"
  if tcp_probe upstream 203.0.113.9 198.51.100.5 443 'tcp 198.51.100.5' >> "$out/negative-control.log" 2>&1; then
    echo 'second-prefix TCP reply succeeded without its source rule' >&2
    exit 1
  fi
  if dns_probe 198.51.100.5 >> "$out/negative-control.log" 2>&1; then
    echo 'second-prefix wildcard UDP reply succeeded without its source rule' >&2
    exit 1
  fi
  run ip rule add from 198.51.100.5 lookup 1002 priority 10012
  tcp_probe upstream 203.0.113.9 198.51.100.5 443 'tcp 198.51.100.5' | tee -a "$out/negative-control.log"
  dns_probe 198.51.100.5 | tee -a "$out/negative-control.log"
  printf 'negative control: provider dropped second-prefix replies only while source rule absent\n' | tee -a "$out/negative-control.log"
else
  # Two completed native DHCP exchanges demonstrate post-loss reacquisition.
  [ "$(grep -c 'DHCPACK(server0)' "$out/dhcp-server.log")" -ge 2 ]
  cp "$out/leases" "$out/leases-after-carrier-cycle"
fi
