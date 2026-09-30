# shellcheck shell=bash
set -Eeuo pipefail
out=${out:?}
fixture_failure() {
  local status=$1 line=$2 command=$3
  trap - ERR
  set +e
  printf 'Private ingress fixture failure status=%s line=%s command=%q\n' \
    "$status" "$line" "$command" >&2
  awk -v fixture_root="${FIXTURE_ROOT:-}" \
    '$5 == "/nix" || $5 == "/nix/store" || $5 == fixture_root "/nix" || $5 == fixture_root "/nix/store"' \
    /proc/self/mountinfo >&2
  nft list ruleset > "$out/failure-ruleset.nft"
  cat "$out/failure-ruleset.nft" >&2
  [ ! -f "$out/udp-listener.log" ] || tail -n 80 "$out/udp-listener.log" >&2
  exit "$status"
}
trap 'fixture_failure "$?" "$LINENO" "$BASH_COMMAND"' ERR

case "${1:-}" in
  --isolate)
    mount --make-rprivate /
    mkdir -p "$FIXTURE_ROOT"/{nix/store,dev,proc,build,run,tmp,var/lib/nftables,evidence}
    # Preserve inherited Nix package submounts, as the existing WAN fixture
    # does; a nonrecursive bind would separate the locked sandbox subtree.
    awk '$5 == "/nix/store" || index($5, "/nix/store/") == 1' /proc/self/mountinfo > "$out/store-source-mountinfo.log"
    mount --rbind /nix/store "$FIXTURE_ROOT/nix/store"
    mount -o remount,bind,ro "$FIXTURE_ROOT/nix/store"
    awk -v root="$FIXTURE_ROOT/nix/store" '$5 == root || index($5, root "/") == 1' /proc/self/mountinfo > "$out/store-fixture-mountinfo.log"
    [ "$(wc -l < "$out/store-source-mountinfo.log")" -eq "$(wc -l < "$out/store-fixture-mountinfo.log")" ]
    mount --rbind /dev "$FIXTURE_ROOT/dev"
    mount --make-rslave "$FIXTURE_ROOT/dev"
    # This fixture retains its existing PID namespace and filtered proc view.
    mount --rbind /proc "$FIXTURE_ROOT/proc"
    mount --bind "$out" "$FIXTURE_ROOT/evidence"
    export out=/evidence TMPDIR=/tmp
    exec chroot "$FIXTURE_ROOT" "$BASH" "$RUNTIME_SCRIPT" --inside
    ;;
  --inside) ;;
  "")
    if ! unshare -Urnm true; then
      echo 'BLOCKED: builder lacks user, mount or network namespaces' >&2
      exit 1
    fi
    export FIXTURE_ROOT="$TMPDIR/private-firewall-root"
    exec timeout --kill-after=2s 140s unshare -Urnm "$BASH" "$RUNTIME_SCRIPT" --isolate
    ;;
  *) echo 'unexpected fixture mode' >&2; exit 2 ;;
esac

body_started=$(date +%s%3N)
client_pid=
listeners=()
flows=()
cleanup() {
  if [ "${#flows[@]}" -gt 0 ]; then kill "${flows[@]}" 2>/dev/null || true; fi
  if [ "${#listeners[@]}" -gt 0 ]; then kill "${listeners[@]}" 2>/dev/null || true; fi
  [ -z "$client_pid" ] || kill "$client_pid" 2>/dev/null || true
}
trap cleanup EXIT
printf 'effective_uid=%s\nroot_uid=%s\n' "$(id -u)" "$(stat -c %u /)" > "$out/namespace-metadata.log"
cat /proc/self/uid_map >> "$out/namespace-metadata.log"
printf '%s\n' 'UID 0 maps the builder user; this process/net fixture does not establish production root, host boot, physical NIC or deployed connectivity.' >> "$out/namespace-metadata.log"
nft -f - <<'RULES'
table inet unrelated_runtime {
  chain retained { counter comment "must survive private ingress lifecycle"; }
}
table inet tailscale_style_accept {
  chain input {
    type filter hook input priority filter; policy accept;
    ct state established,related accept
    tcp dport 443 accept
    udp dport 443 accept
  }
}
RULES
unshare -n -- sleep 150 & client_pid=$!
for _ in $(seq 1 100); do
  if [ -e "/proc/$client_pid/ns/net" ] && [ "$(readlink "/proc/$client_pid/ns/net")" != "$(readlink /proc/self/ns/net)" ]; then
    nsenter -t "$client_pid" -n ip link set lo up && break
  fi
  sleep 0.02
done
[ "$(readlink "/proc/$client_pid/ns/net")" != "$(readlink /proc/self/ns/net)" ]
printf 'server_netns=%s client_netns=%s\n' "$(readlink /proc/self/ns/net)" "$(readlink "/proc/$client_pid/ns/net")" >> "$out/namespace-metadata.log"
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
ip link set fixture0 up
nsenter -t "$client_pid" -n ip address add 198.51.100.3/24 dev client1
nsenter -t "$client_pid" -n ip link set client1 up
nsenter -t "$client_pid" -n ip route add 192.0.2.2/32 via 198.51.100.2 dev client1 table 100
nsenter -t "$client_pid" -n ip rule add from 198.51.100.3/32 table 100 priority 100
# Keep IPv4 reverse-path validation permissive for the explicit same-source
# route-switch fixture. The native consumer firewall itself remains unchanged.
for name in all default public0 fixture0; do printf '0\n' > "/proc/sys/net/ipv4/conf/$name/rp_filter"; done

for address in 192.0.2.2 198.51.100.2 203.0.113.2; do
  for port in 22 80 443 444; do
    socat "TCP4-LISTEN:$port,bind=$address,reuseaddr,fork" "EXEC:$(command -v cat)" >/dev/null 2>&1 & listeners+=("$!")
  done
done
socat -d -d UDP4-RECVFROM:443,bind=192.0.2.2,reuseaddr,fork "EXEC:$(command -v cat)" > "$out/udp-listener.log" 2>&1 & listeners+=("$!")
for _ in $(seq 1 100); do
  [ "$(ss -H -lnt | wc -l)" -ge 12 ] && [ "$(ss -H -lnu | wc -l)" -ge 1 ] && break
  sleep 0.02
done
ss -lntu > "$out/listeners.log"
[ "$(ss -H -lnt | wc -l)" -ge 12 ]

scan_id=0
expect_state() {
  local source=$1 address=$2 port=$3 expected=$4 state xml errors
  scan_id=$((scan_id + 1))
  xml="$out/tcp-$scan_id.xml"
  errors="$out/tcp-$scan_id.err"
  # Nmap's connect scan binds its local -S address before connect(); fail if
  # binding fails, since its native fallback would otherwise scan unbound.
  nsenter -t "$client_pid" -n nmap -n -Pn -sT -S "$source" --max-retries 0 --host-timeout 5s --initial-rtt-timeout 300ms --max-rtt-timeout 500ms -p "$port" -oX "$xml" "$address" >/dev/null 2> "$errors"
  if grep -q 'Problem binding source address' "$errors"; then
    cat "$errors" >&2
    return 1
  fi
  state=$(sed -n 's/.*<state state="\([^"]*\)".*/\1/p' "$xml")
  printf '%s -> %s:%s expected=%s actual=%s\n' "$source" "$address" "$port" "$expected" "$state" | tee -a "$out/packet-states.log"
  [ "$state" = "$expected" ]
}
udp_echo() {
  local source=$1 token=$2 reply
  # Suppress Socat 1.8.1's implicit empty UDP EOF packet: a RECVFROM child
  # ignores it and then consumes traffic intended for the next packet child.
  reply=$(printf '%s\n' "$token" | nsenter -t "$client_pid" -n timeout 2 socat -T 1 - "UDP4:192.0.2.2:443,bind=$source,shut-none")
  printf 'UDP source=%s token=%s reply=%s\n' "$source" "$token" "$reply" | tee -a "$out/udp-packet-states.log"
  [ "$reply" = "$token" ]
}
expect_failure() { if "$@"; then echo "unexpected success: $*" >&2; exit 1; fi; }
wait_token() {
  local log=$1 token=$2
  for _ in $(seq 1 100); do grep -q "^$token$" "$log" && return; sleep 0.02; done
  echo "missing persistent-flow token $token in $log" >&2
  return 1
}
assert_blocked_token() {
  local log=$1 token=$2 deadline
  deadline=$(( $(date +%s%3N) + 1200 ))
  while [ "$(date +%s%3N)" -lt "$deadline" ]; do
    if grep -q "^$token$" "$log"; then echo "guard leaked persistent token $token" >&2; return 1; fi
    sleep 0.05
  done
}

# Both packaged clients keep their sockets and source ports throughout guard
# installation. Payloads are unique; no application traffic server is authored.
"$LAST_START"
mkfifo /tmp/public-tcp /tmp/public-udp /tmp/trusted-udp
exec 9<> /tmp/public-tcp
exec 8<> /tmp/public-udp
exec 7<> /tmp/trusted-udp
nsenter -t "$client_pid" -n socat - TCP4:192.0.2.2:443,bind=192.0.2.3:46001 < /tmp/public-tcp > "$out/established-public-tcp.log" 2> "$out/established-public-tcp.err" & flows+=("$!")
nsenter -t "$client_pid" -n socat - UDP4:192.0.2.2:443,bind=192.0.2.3:46002 < /tmp/public-udp > "$out/established-public-udp.log" 2> "$out/established-public-udp.err" & flows+=("$!")
printf 'tcp-before-guard\n' >&9
printf 'udp-before-guard\n' >&8
wait_token "$out/established-public-tcp.log" tcp-before-guard
wait_token "$out/established-public-udp.log" udp-before-guard
expect_state 192.0.2.3 192.0.2.2 443 open
udp_echo 192.0.2.3 before-guard-control
"$NATIVE_RELOAD"
"$NATIVE_RELOAD"
printf 'tcp-after-guard\n' >&9
printf 'udp-after-guard\n' >&8
assert_blocked_token "$out/established-public-tcp.log" tcp-after-guard
assert_blocked_token "$out/established-public-udp.log" udp-after-guard
nft list table inet network-edge-policy > "$out/private-policy.nft"
grep -q 'network: private IPv4 ingress' "$out/private-policy.nft"
grep -q 'priority filter - 10' "$out/private-policy.nft"
grep -q 'network: reject non-loopback HTTP' "$out/private-policy.nft"
cp /var/lib/nftables/deletions.nft "$out/native-deletions.nft"

expect_state 192.0.2.3 192.0.2.2 443 filtered
expect_state 192.0.2.3 192.0.2.2 22 filtered
expect_state 192.0.2.3 203.0.113.2 443 open
expect_state 198.51.100.3 192.0.2.2 443 open
expect_state 198.51.100.3 192.0.2.2 22 open
expect_state 198.51.100.3 192.0.2.2 444 filtered
expect_state 198.51.100.3 198.51.100.2 22 filtered
expect_state 198.51.100.3 198.51.100.2 443 filtered
expect_state 198.51.100.3 192.0.2.2 80 filtered
# Implicit loopback trust still works when all external paths are private.
printf 'loopback-control\n' | timeout 2 socat -T 1 - TCP4:192.0.2.2:443 | grep -q loopback-control
udp_echo 198.51.100.3 trusted-control
expect_failure udp_echo 192.0.2.3 public-blocked

guard_packets() {
  nft -j list chain inet network-edge-policy private_ingress_guard | jq '[.. | objects | .counter? // empty | .packets] | add'
}
before_icmp=$(guard_packets)
expect_failure nsenter -t "$client_pid" -n ping -c 1 -W 1 -I 192.0.2.3 192.0.2.2
[ "$(guard_packets)" -gt "$before_icmp" ]

# One UDP socket retains the exact source/destination tuple while its route
# crosses trusted and untrusted ingress, including disappearance of the address.
nsenter -t "$client_pid" -n ip route replace 192.0.2.2/32 via 198.51.100.2 dev client1
nsenter -t "$client_pid" -n socat - UDP4:192.0.2.2:443,bind=192.0.2.3:46003 < /tmp/trusted-udp > "$out/established-route-udp.log" 2> "$out/established-route-udp.err" & flows+=("$!")
printf 'udp-trusted-before-switch\n' >&7
wait_token "$out/established-route-udp.log" udp-trusted-before-switch
nsenter -t "$client_pid" -n ip route replace 192.0.2.2/32 dev client0
printf 'udp-untrusted-after-switch\n' >&7
assert_blocked_token "$out/established-route-udp.log" udp-untrusted-after-switch
nsenter -t "$client_pid" -n ip route replace 192.0.2.2/32 via 198.51.100.2 dev client1
printf 'udp-trusted-after-switch\n' >&7
wait_token "$out/established-route-udp.log" udp-trusted-after-switch
ip address del 192.0.2.2/24 dev public0
# Retain local packet delivery explicitly after address removal so this checks
# the destination guard itself, rather than accidentally testing missing routing.
ip route add local 192.0.2.2/32 dev lo table local
ip route add 192.0.2.3/32 dev public0
ip address show dev public0 > "$out/address-loss.log"
ip route show table local >> "$out/address-loss.log"
printf 'udp-trusted-after-address-loss\n' >&7
wait_token "$out/established-route-udp.log" udp-trusted-after-address-loss
nsenter -t "$client_pid" -n ip route replace 192.0.2.2/32 dev client0
# Preserve neighbor reachability when the address no longer answers ARP.
server_mac=$(ip -j link show public0 | jq -r '.[0].address')
nsenter -t "$client_pid" -n ip neighbor replace 192.0.2.2 lladdr "$server_mac" dev client0 nud permanent
printf 'udp-untrusted-after-address-loss\n' >&7
assert_blocked_token "$out/established-route-udp.log" udp-untrusted-after-address-loss
ip route del local 192.0.2.2/32 dev lo table local
ip address add 192.0.2.2/24 dev public0
ip route del 192.0.2.3/32 dev public0
nsenter -t "$client_pid" -n ip neighbor del 192.0.2.2 dev client0

"$ONE_REMOVED_RELOAD"
expect_state 192.0.2.3 192.0.2.2 443 filtered
expect_state 198.51.100.3 192.0.2.2 443 open
"$UPDATED_RELOAD"
expect_state 192.0.2.3 192.0.2.2 443 open
expect_state 198.51.100.3 192.0.2.2 443 filtered
"$NATIVE_RELOAD"
expect_state 192.0.2.3 192.0.2.2 443 filtered
expect_state 198.51.100.3 192.0.2.2 443 open
"$REMOVED_RELOAD"
expect_state 192.0.2.3 192.0.2.2 443 open
udp_echo 192.0.2.3 after-claim-removal
expect_state 198.51.100.3 198.51.100.2 443 filtered
"$LAST_RELOAD"
expect_state 192.0.2.3 192.0.2.2 443 open
expect_state 192.0.2.3 192.0.2.2 80 filtered
nft list table inet unrelated_runtime > "$out/unrelated-after-last-claim-removal.nft"
nft list table inet tailscale_style_accept > "$out/tailscale-accept-after-last-claim-removal.nft"
"$DEFAULT_CLAIM_RELOAD"
expect_state 192.0.2.3 192.0.2.2 443 filtered
"$DEFAULT_EMPTY_RELOAD"
expect_failure nft list table inet network-edge-policy >/dev/null 2>&1
expect_state 192.0.2.3 192.0.2.2 443 open
nft list table inet unrelated_runtime > "$out/unrelated-after-table-removal.nft"
# Stop uses the persisted deletion list of the final native generation.
"$NATIVE_STOP"
expect_failure nft list table inet nixos-fw >/dev/null 2>&1
[ ! -e /var/lib/nftables/deletions.nft ]
nft list table inet unrelated_runtime > "$out/unrelated-after-stop.nft"
nft list table inet tailscale_style_accept > "$out/tailscale-after-stop.nft"
"$NATIVE_START"
expect_state 192.0.2.3 192.0.2.2 443 filtered
expect_state 198.51.100.3 192.0.2.2 443 open
nft list table inet unrelated_runtime > "$out/unrelated-after-private-start.nft"
"$NATIVE_STOP"
printf 'body_elapsed_ms=%s\n' "$(( $(date +%s%3N) - body_started ))" | tee "$out/timing.log"
