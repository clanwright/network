# shellcheck shell=bash
set -Eeuo pipefail
out=${out:?}
fixture_failure() {
  local status=$1 line=$2 command=$3
  trap - ERR
  set +e
  printf 'Firewall fixture failure status=%s line=%s command=%q\n' \
    "$status" "$line" "$command" >&2
  awk -v fixture_root="${FIXTURE_ROOT:-}" \
    '$5 == "/nix" || $5 == "/nix/store" || $5 == fixture_root "/nix" || $5 == fixture_root "/nix/store"' \
    /proc/self/mountinfo >&2
  nft list ruleset > "$out/failure-ruleset.nft"
  cat "$out/failure-ruleset.nft" >&2
  for log in "$out"/udp-listener-*.log; do
    [ ! -f "$log" ] || tail -n 50 "$log" >&2
  done
  exit "$status"
}
trap 'fixture_failure "$?" "$LINENO" "$BASH_COMMAND"' ERR

# Real native commands need their absolute StateDirectory. Bind only immutable
# tools and public evidence into a fresh chroot in a private mount/net namespace.
case "${1:-}" in
  --isolate)
    mount --make-rprivate /
    mkdir -p "$FIXTURE_ROOT"/{nix/store,dev,proc,build,run,tmp,var/lib/nftables,evidence,foreign-tmp}
    # Nix's sandbox store contains inherited package submounts. A recursive
    # bind preserves them; a plain bind is rejected in this user namespace.
    awk '$5 == "/nix/store" || index($5, "/nix/store/") == 1' /proc/self/mountinfo > "$out/store-source-mountinfo.log"
    mount --rbind /nix/store "$FIXTURE_ROOT/nix/store"
    mount -o remount,bind,ro "$FIXTURE_ROOT/nix/store"
    awk -v root="$FIXTURE_ROOT/nix/store" '$5 == root || index($5, root "/") == 1' /proc/self/mountinfo > "$out/store-fixture-mountinfo.log"
    [ "$(wc -l < "$out/store-source-mountinfo.log")" -eq "$(wc -l < "$out/store-fixture-mountinfo.log")" ]
    mount --rbind /dev "$FIXTURE_ROOT/dev"
    mount --make-rslave "$FIXTURE_ROOT/dev"
    # Keep the existing PID/proc view and its sandbox submount restrictions,
    # using the same ordinary bind pattern as the passing WAN fixture.
    mount --rbind /proc "$FIXTURE_ROOT/proc"
    mount --bind "$out" "$FIXTURE_ROOT/evidence"
    mount --bind /tmp "$FIXTURE_ROOT/foreign-tmp"
    export out=/evidence TMPDIR=/tmp
    exec chroot "$FIXTURE_ROOT" "$BASH" "$RUNTIME_SCRIPT" --inside
    ;;
  --inside) ;;
  "")
    if ! unshare -Urnm true; then
      echo 'BLOCKED: builder lacks user, mount or network namespaces' >&2
      exit 1
    fi
    mkdir -p /tmp/network-bootstrap
    printf '%s\n' "$(( $(date +%s) + 60 ))" > /tmp/network-bootstrap/allow-wan-ssh
    chmod 0700 /tmp/network-bootstrap
    chmod 0600 /tmp/network-bootstrap/allow-wan-ssh
    export FIXTURE_ROOT="$TMPDIR/firewall-root"
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
printf 'effective_uid=%s\nroot_uid=%s\nforeign_tmp_uid=%s\n' "$(id -u)" "$(stat -c %u /)" "$(stat -c %u /foreign-tmp)" > "$out/namespace-metadata.log"
cat /proc/self/uid_map >> "$out/namespace-metadata.log"
printf '%s\n' 'UID 0 here maps the builder user, not production host root; chroot ancestors are fixture-owned. Foreign host-root objects map to an unmapped UID.' >> "$out/namespace-metadata.log"
mkdir -p "$(dirname -- "$MARKER_PATH")"
chmod 0700 "$(dirname -- "$MARKER_PATH")"

nft -f - <<'RULES'
table inet unrelated_runtime {
  chain retained { counter comment "must survive native start reload stop"; }
}
RULES
"$NATIVE_START"
"$NATIVE_RELOAD"
cp /var/lib/nftables/deletions.nft "$out/native-deletions.nft"
nft list table inet nixos-fw > "$out/native-firewall.nft"
nft list table inet network-edge-policy > "$out/network-edge-policy.nft"
grep -q 'network: active bootstrap SSH' "$out/native-firewall.nft"
grep -q 'network: public destination ingress' "$out/native-firewall.nft"
nft list table inet unrelated_runtime > "$out/unrelated-after-start-reload.nft"

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
ip link add server0 type veth peer name client0
ip link set client0 netns "$client_pid"
ip address add 192.0.2.2/24 dev server0
ip address add 192.0.2.4/24 dev server0
ip -6 address add 2001:db8:1::2/64 dev server0 nodad
ip link set server0 up
nsenter -t "$client_pid" -n ip address add 192.0.2.3/24 dev client0
nsenter -t "$client_pid" -n ip -6 address add 2001:db8:1::3/64 dev client0 nodad
nsenter -t "$client_pid" -n ip link set client0 up
ip link add fixture0 type veth peer name client1
ip link set client1 netns "$client_pid"
ip address add 198.51.100.2/24 dev fixture0
ip -6 address add 2001:db8:2::2/64 dev fixture0 nodad
ip link set fixture0 up
nsenter -t "$client_pid" -n ip address add 198.51.100.3/24 dev client1
nsenter -t "$client_pid" -n ip -6 address add 2001:db8:2::3/64 dev client1 nodad
nsenter -t "$client_pid" -n ip link set client1 up

for address in 192.0.2.2 198.51.100.2; do
  for port in 22 80 443; do
    socat "TCP4-LISTEN:$port,bind=$address,reuseaddr,fork" "EXEC:$(command -v cat)" >/dev/null 2>&1 & listeners+=("$!")
  done
done
for address in 2001:db8:1::2 2001:db8:2::2; do
  for port in 22 80 443; do
    socat "TCP6-LISTEN:$port,bind=[$address],ipv6only=1,reuseaddr,fork" "EXEC:$(command -v cat)" >/dev/null 2>&1 & listeners+=("$!")
  done
done
socat TCP4-LISTEN:8443,bind=192.0.2.2,reuseaddr,fork "EXEC:$(command -v cat)" >/dev/null 2>&1 & listeners+=("$!")
for address in 192.0.2.2 192.0.2.4; do
  socat -d -d "UDP4-RECVFROM:8443,bind=$address,reuseaddr,fork" "EXEC:$(command -v cat)" > "$out/udp-listener-$address.log" 2>&1 & listeners+=("$!")
done
# An open probe is the readiness check; ss also proves the expected listeners.
for _ in $(seq 1 100); do
  [ "$(ss -H -lnt | wc -l)" -ge 13 ] && [ "$(ss -H -lnu | wc -l)" -ge 2 ] && break
  sleep 0.02
done
ss -lntu > "$out/listeners.log"
[ "$(ss -H -lnt | wc -l)" -ge 13 ]
[ "$(ss -H -lnu | wc -l)" -ge 2 ]

scan_id=0
udp_id=0
expect_state() {
  local address=$1 port=$2 expected=$3 state xml ipv6=
  scan_id=$((scan_id + 1))
  xml="$out/tcp-$scan_id.xml"
  [[ $address != *:* ]] || ipv6=-6
  nsenter -t "$client_pid" -n nmap $ipv6 -n -Pn -sT --max-retries 0 --host-timeout 5s --initial-rtt-timeout 300ms --max-rtt-timeout 500ms -p "$port" -oX "$xml" "$address" >/dev/null
  state=$(sed -n 's/.*<state state="\([^"]*\)".*/\1/p' "$xml")
  printf '%s:%s expected=%s actual=%s\n' "$address" "$port" "$expected" "$state" | tee -a "$out/packet-states.log"
  [ "$state" = "$expected" ]
}
udp_echo() {
  local address=$1 token=$2 reply source_port
  # Fresh explicit source ports keep a previous accepted control flow from
  # passing via native established-conntrack acceptance after scoped reload.
  udp_id=$((udp_id + 1))
  source_port=$((47000 + udp_id))
  # Socat 1.8.1 sends an empty datagram on UDP EOF by default. A RECVFROM
  # child ignores it and stalls the parent's per-packet handshake; only the
  # explicit payload belongs to this one-shot probe.
  reply=$(printf '%s\n' "$token" | nsenter -t "$client_pid" -n timeout 2 socat -T 1 - "UDP4:$address:8443,bind=192.0.2.3:$source_port,shut-none")
  printf 'UDP source_port=%s destination=%s token=%s reply=%s\n' "$source_port" "$address" "$token" "$reply" | tee -a "$out/udp-packet-states.log"
  [ "$reply" = "$token" ]
}
expect_failure() { if "$@"; then echo "unexpected success: $*" >&2; exit 1; fi; }

expect_state 192.0.2.2 443 open
expect_state 2001:db8:1::2 443 open
expect_state 198.51.100.2 22 open
expect_state 2001:db8:2::2 22 open
expect_state 192.0.2.2 22 filtered
expect_state 2001:db8:1::2 22 filtered
expect_state 192.0.2.2 8443 open
expect_state 192.0.2.4 8443 filtered
expect_state 192.0.2.4 443 closed
# Both destination addresses have real responders. A broader native generation
# proves the otherwise negative address answers before scoped rules reject it.
"$UDP_POSITIVE_RELOAD"
udp_echo 192.0.2.2 broad-positive-primary
udp_echo 192.0.2.4 broad-positive-other
"$NATIVE_RELOAD"
udp_echo 192.0.2.2 scoped-positive
expect_failure udp_echo 192.0.2.4 scoped-negative
# Both addresses can serve HTTP while port 80 is allowed. The actual early
# guard then blocks IPv4 and IPv6 despite the same native port declaration.
"$HTTP_POSITIVE_RELOAD"
expect_state 192.0.2.2 80 open
expect_state 2001:db8:1::2 80 open
"$HTTP_GUARD_RELOAD"
expect_state 192.0.2.2 80 filtered
expect_state 2001:db8:1::2 80 filtered
"$NATIVE_RELOAD"

marker_write() { printf '%s\n' "$1" > "$MARKER_PATH"; chmod 0600 "$MARKER_PATH"; }
assert_deadline_remaining() {
  local epoch=$1 sample_started sample_finished remaining_start remaining_end expires
  [ "$(cat "$MARKER_PATH")" = "$epoch" ]
  sample_started=$(date +%s)
  remaining_start=$(( epoch - sample_started ))
  nft -j list set inet nixos-fw bootstrap_ssh_v4 > "$out/bootstrap-$2.json"
  sample_finished=$(date +%s)
  remaining_end=$(( epoch - sample_finished ))
  expires=$(jq '[.. | objects | .expires? // empty] | first' "$out/bootstrap-$2.json")
  [ "$expires" != null ] && [ "$expires" -gt 0 ]
  # Native nft JSON timeout/expires values are seconds, rounded down. Sampling
  # brackets the query; one second permits that rounding without accepting an
  # extended deadline or a materially shortened timeout.
  [ "$expires" -le "$remaining_start" ]
  [ "$expires" -ge "$(( remaining_end - 1 ))" ]
  printf '%s deadline=%s sample_start=%s sample_end=%s remaining_start_seconds=%s remaining_end_seconds=%s kernel_expires_seconds=%s\n' \
    "$2" "$epoch" "$sample_started" "$sample_finished" "$remaining_start" "$remaining_end" "$expires" >> "$out/deadlines.log"
}
# A generous deterministic window isolates deadline semantics from slow scans.
deadline=$(( $(date +%s) + 60 ))
marker_write "$deadline"
"$REFRESH"
assert_deadline_remaining "$deadline" refresh
expect_state 192.0.2.2 22 open
expect_state 2001:db8:1::2 22 filtered
nft -f - <<'RULES'
table inet later_security_drop {
  chain input { type filter hook input priority filter + 10; policy accept; tcp dport 22 drop; }
}
RULES
expect_state 192.0.2.2 22 filtered
nft delete table inet later_security_drop
"$NATIVE_RELOAD"
assert_deadline_remaining "$deadline" reload
expect_state 192.0.2.2 22 open
"$NATIVE_STOP"
[ ! -e /var/lib/nftables/deletions.nft ]
nft list table inet unrelated_runtime > "$out/unrelated-after-stop.nft"
"$NATIVE_START"
assert_deadline_remaining "$deadline" reboot-state-restart
expect_state 192.0.2.2 22 open

fail_closed_case() {
  local label=$1
  "$REFRESH" 2> "$out/marker-$label.log"
  nft -j list set inet nixos-fw bootstrap_ssh_v4 > "$out/marker-$label.json"
  [ "$(jq '[.. | objects | .elem? // empty] | flatten | length' "$out/marker-$label.json")" -eq 0 ]
  expect_state 192.0.2.2 22 filtered
}
for malformed in '' invalid 09 0 9999999999999999999; do
  marker_write "$malformed"
  fail_closed_case "malformed-${#malformed}-$scan_id"
done
: > "$MARKER_PATH"
fail_closed_case empty-file
rm "$MARKER_PATH"
mkdir "$MARKER_PATH"
fail_closed_case directory-marker
expect_failure "$RENEW" 2> "$out/renew-directory-marker.log"
rmdir "$MARKER_PATH"
mkfifo "$MARKER_PATH"
fail_closed_case fifo-marker
expect_failure "$RENEW" 2> "$out/renew-fifo-marker.log"
rm "$MARKER_PATH"
printf '%s' "$(( $(date +%s) + 60 ))" > "$MARKER_PATH"
chmod 0600 "$MARKER_PATH"
fail_closed_case unterminated
printf '%s\n%s\n' "$(( $(date +%s) + 60 ))" trailing > "$MARKER_PATH"
fail_closed_case extra-line
marker_write "$(( $(date +%s) - 1 ))"
fail_closed_case expired
marker_write "$(( $(date +%s) + 7200 ))"
fail_closed_case overlong
marker_write "$(( $(date +%s) + 60 ))"
chmod 0666 "$MARKER_PATH"
fail_closed_case unsafe-file
expect_failure "$RENEW" 2> "$out/renew-unsafe-file.log"
chmod 0600 "$MARKER_PATH"
chmod 0777 "$(dirname -- "$MARKER_PATH")"
fail_closed_case unsafe-parent
expect_failure "$RENEW" 2> "$out/renew-unsafe-parent.log"
chmod 1777 "$(dirname -- "$MARKER_PATH")"
fail_closed_case unsafe-sticky-parent
expect_failure "$RENEW" 2> "$out/renew-unsafe-sticky-parent.log"
chmod 0700 "$(dirname -- "$MARKER_PATH")"
mv "$MARKER_PATH" /build/marker-target
ln -s /build/marker-target "$MARKER_PATH"
fail_closed_case symlink-file
expect_failure "$RENEW" 2> "$out/renew-symlink-file.log"
rm "$MARKER_PATH"
mv /build/marker-target "$MARKER_PATH"
mv /build/network-bootstrap /build/marker-real-parent
ln -s /build/marker-real-parent /build/network-bootstrap
fail_closed_case symlink-parent
expect_failure "$RENEW" 2> "$out/renew-symlink-parent.log"
rm /build/network-bootstrap
mv /build/marker-real-parent /build/network-bootstrap
# A store executable is a regular file owned by the outer host root, hence an
# unmapped UID in this namespace. It is mounted, never modified.
mount --bind "$(type -P true)" "$MARKER_PATH"
[ "$(stat -c %u "$MARKER_PATH")" != 0 ]
fail_closed_case nonowned-file
grep -q 'marker is not owned by root' "$out/marker-nonowned-file.log"
expect_failure "$RENEW" 2> "$out/renew-nonowned-file.log"
umount "$MARKER_PATH"
# /foreign-tmp contains a safe fixture marker under the host-root-owned /tmp.
mount --bind /foreign-tmp /build
[ "$(stat -c %u /build)" != 0 ]
fail_closed_case nonowned-ancestor
grep -q 'directory not owned by root' "$out/marker-nonowned-ancestor.log"
expect_failure "$RENEW" 2> "$out/renew-nonowned-ancestor.log"
umount /build

marker_write "$(( $(date +%s) - 1 ))"
"$RENEW"
renewed=$(cat "$MARKER_PATH")
[ "$renewed" -gt "$(date +%s)" ]
[ "$renewed" -le "$(( $(date +%s) + 120 ))" ]
assert_deadline_remaining "$renewed" renewal
expect_state 192.0.2.2 22 open
rm "$MARKER_PATH"
"$REFRESH"
expect_state 192.0.2.2 22 filtered
expect_failure "$RENEW" 2> "$out/renew-missing.log"

# Natural expiration is a separate bounded observation. The same established
# socket must retain its echo while fresh connections become filtered.
marker_write "$(( $(date +%s) + 6 ))"
"$REFRESH"
natural_deadline=$(cat "$MARKER_PATH")
mkfifo /tmp/bootstrap-session
exec 9<> /tmp/bootstrap-session
nsenter -t "$client_pid" -n socat - TCP4:192.0.2.2:22 < /tmp/bootstrap-session > "$out/bootstrap-established.log" 2> "$out/bootstrap-established.err" & flows+=("$!")
printf 'established-before-expiry\n' >&9
for _ in $(seq 1 100); do grep -q established-before-expiry "$out/bootstrap-established.log" && break; sleep 0.02; done
grep -q established-before-expiry "$out/bootstrap-established.log"
expiration_bound=$(( $(date +%s) + 12 ))
while :; do
  nft -j list set inet nixos-fw bootstrap_ssh_v4 > "$out/natural-expiry.json"
  count=$(jq '[.. | objects | .elem? // empty] | flatten | length' "$out/natural-expiry.json")
  [ "$count" -ne 0 ] || break
  [ "$(date +%s)" -le "$expiration_bound" ]
  sleep 0.2
done
[ "$(cat "$MARKER_PATH")" = "$natural_deadline" ]
expect_state 192.0.2.2 22 filtered
printf 'established-after-expiry\n' >&9
for _ in $(seq 1 100); do grep -q established-after-expiry "$out/bootstrap-established.log" && break; sleep 0.02; done
grep -q established-after-expiry "$out/bootstrap-established.log"
printf 'natural_expiry_deadline=%s observed_epoch=%s\n' "$natural_deadline" "$(date +%s)" >> "$out/deadlines.log"

# Invalid marker convergence succeeds; the real nft failure must still escape
# both the refresh command and its native systemd lifecycle hook.
marker_write invalid
nft delete table inet nixos-fw
expect_failure "$REFRESH" 2> "$out/nft-refresh-failure.log"
grep -q 'network bootstrap SSH disabled:' "$out/nft-refresh-failure.log"
rm "$MARKER_PATH"
"$NATIVE_RELOAD"
# A malformed persisted deletion file fails the actual native reload chain;
# nft's atomic transaction leaves both owned and foreign tables intact.
printf 'this is not an nft command\n' > /var/lib/nftables/deletions.nft
expect_failure "$NATIVE_RELOAD" 2> "$out/native-reload-failure.log"
nft list table inet unrelated_runtime > "$out/unrelated-after-failed-reload.nft"
cp "$out/native-deletions.nft" /var/lib/nftables/deletions.nft
"$NATIVE_RELOAD"
"$NATIVE_STOP"
expect_failure nft list table inet nixos-fw > /dev/null 2>&1
expect_failure nft list table inet network-edge-policy > /dev/null 2>&1
nft list table inet unrelated_runtime > "$out/unrelated-after-final-stop.nft"
printf 'body_elapsed_ms=%s\n' "$(( $(date +%s%3N) - body_started ))" | tee "$out/timing.log"
