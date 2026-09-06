# shellcheck shell=bash
set -euo pipefail

if ! unshare -Urn true; then
  echo 'BLOCKED: builder does not support unprivileged user/network namespaces' >&2
  exit 1
fi

unshare -Urn bash -euo pipefail <<'INNER'
client_pid=
listeners=
cleanup() {
  [ -z "$listeners" ] || kill $listeners 2>/dev/null || true
  [ -z "$client_pid" ] || kill "$client_pid" 2>/dev/null || true
  rm -f -- "$MARKER_PATH" "$(dirname -- "$MARKER_PATH")/symlink-target"
  rmdir -- "$(dirname -- "$MARKER_PATH")" 2>/dev/null || true
}
trap cleanup EXIT

# `/tmp` is owned by the outer sandbox root, which is intentionally unmapped in
# this user namespace. Build-local `/build` is owned by the mapped builder user,
# so this fixture accurately presents the production root-owned marker contract.
mkdir -p -- "$(dirname -- "$MARKER_PATH")"
chmod 0700 "$(dirname -- "$MARKER_PATH")"

nft -f - <<'EOF'
table inet unrelated_runtime {
  chain retained {
    counter comment "must survive Network apply and teardown"
  }
}
EOF

nft -f "$APPLY_RULES"
nft -f "$APPLY_RULES"
nft list table inet unrelated_runtime > "$out/unrelated-after-reapply.nft"
nft list table inet nixos-fw > "$out/native-firewall.nft"
nft list table inet network-edge-policy > "$out/network-edge-policy.nft"
grep -q 'tcp dport 443 accept' "$out/native-firewall.nft"
grep -q 'network: reject non-loopback HTTP' "$out/network-edge-policy.nft"
grep -q 'network: active bootstrap SSH' "$out/native-firewall.nft"

unshare -n -- sleep infinity &
client_pid=$!
for _ in $(seq 1 50); do
  nsenter -t "$client_pid" -n ip link set lo up 2>/dev/null && break
  sleep 0.02
done
nsenter -t "$client_pid" -n ip link show lo >/dev/null

ip link add server0 type veth peer name client0
ip link set client0 netns "$client_pid"
ip address add 192.0.2.2/24 dev server0
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
    nc -4 -l -k -s "$address" -p "$port" >/dev/null 2>&1 & listeners="$listeners $!"
  done
done
for address in 2001:db8:1::2 2001:db8:2::2; do
  for port in 22 80 443; do
    nc -6 -l -k -s "$address" -p "$port" >/dev/null 2>&1 & listeners="$listeners $!"
  done
done
sleep 0.2

probe4() { nsenter -t "$client_pid" -n nc -4 -z -w 1 "$1" "$2"; }
probe6() { nsenter -t "$client_pid" -n nc -6 -z -w 1 "$1" "$2"; }

probe4 192.0.2.2 443
probe6 2001:db8:1::2 443
probe4 198.51.100.2 22
probe6 2001:db8:2::2 22

! probe4 192.0.2.2 80
! probe6 2001:db8:1::2 80
! probe4 192.0.2.2 22
! probe6 2001:db8:1::2 22

printf '%s\n' "$(( $(date +%s) + 5 ))" > "$MARKER_PATH"
chmod 0600 "$MARKER_PATH"
"$REFRESH"
nft list set inet nixos-fw bootstrap_ssh_v4 > "$out/bootstrap-active.nft"
probe4 192.0.2.2 22
! probe6 2001:db8:1::2 22

# An accept in the native chain is still subject to a later base-chain drop,
# matching nftables/fail2ban composition semantics.
nft -f - <<'EOF'
table inet later_security_drop {
  chain input {
    type filter hook input priority filter + 10; policy accept;
    tcp dport 22 drop
  }
}
EOF
! probe4 192.0.2.2 22
nft delete table inet later_security_drop
probe4 192.0.2.2 22

nft -f "$APPLY_RULES"
"$REFRESH"
probe4 192.0.2.2 22
sleep 6
! probe4 192.0.2.2 22

printf '%s\n' "$(( $(date +%s) - 1 ))" > "$MARKER_PATH"
chmod 0600 "$MARKER_PATH"
"$RENEW"
probe4 192.0.2.2 22

printf '%s\n' "$(( $(date +%s) + 30 ))" > "$MARKER_PATH"
chmod 0666 "$MARKER_PATH"
! "$REFRESH"
! probe4 192.0.2.2 22
chmod 0600 "$MARKER_PATH"
: > "$MARKER_PATH"
! "$REFRESH"
! probe4 192.0.2.2 22
printf '09\n' > "$MARKER_PATH"
! "$REFRESH"
! probe4 192.0.2.2 22
rm -f -- "$MARKER_PATH"
marker_target="$(dirname -- "$MARKER_PATH")/symlink-target"
printf '%s\n' "$(( $(date +%s) + 30 ))" > "$marker_target"
ln -s "$marker_target" "$MARKER_PATH"
! "$REFRESH"
! probe4 192.0.2.2 22
rm -f -- "$MARKER_PATH" "$marker_target"
printf '%s\n' "$(( $(date +%s) + 7200 ))" > "$MARKER_PATH"
! "$REFRESH"
! probe4 192.0.2.2 22

rm -f -- "$MARKER_PATH"
"$REFRESH"
! probe4 192.0.2.2 22

nft -f "$STOP_RULES"
nft -f "$STOP_RULES"
! nft list table inet nixos-fw >/dev/null 2>&1
! nft list table inet network-edge-policy >/dev/null 2>&1
nft list table inet unrelated_runtime > "$out/unrelated-after-teardown.nft"
INNER
