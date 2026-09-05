set -euo pipefail
# All rules are confined to the new network namespace. Namespace failure is a
# failed gate, not a skip: never retry this script in the host namespace.
if ! unshare -Urn true; then
  echo 'BLOCKED: builder does not support unprivileged user/network namespaces' >&2
  exit 1
fi
unshare -Urn bash -euo pipefail <<'INNER'
ip link set lo up
iptables -A INPUT -p tcp --dport 2222 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 2222 -j ACCEPT
bash "$FIREWALL_START"
bash "$FIREWALL_START"
iptables-save > "$out/initial-v4.rules"
ip6tables-save > "$out/initial-v6.rules"
test "$(iptables-save | grep -c -- '-A INPUT .*edge-firewall:jump')" = 1
! iptables-save | grep -q 'edge-firewall:bootstrap-ssh'
iptables-save | grep -q 'edge-firewall:reject-http'
ip6tables-save | grep -q 'edge-firewall:reject-http'
touch /tmp/network-bootstrap-marker
bash "$FIREWALL_START"
iptables-save > "$out/bootstrap-v4.rules"
iptables-save | grep 'edge-firewall:bootstrap-ssh' | grep -q -- '-d 192.0.2.2/32'
rm /tmp/network-bootstrap-marker
bash "$FIREWALL_START"
! iptables-save | grep -q 'edge-firewall:bootstrap-ssh'
bash "$FIREWALL_STOP"
bash "$FIREWALL_STOP"
iptables-save > "$out/stopped-v4.rules"
ip6tables-save > "$out/stopped-v6.rules"
! iptables-save | grep -q NIXOS_EDGE_FIREWALL
! ip6tables-save | grep -q NIXOS_EDGE_FIREWALL
iptables-save | grep -q -- '--dport 2222 -j ACCEPT'
ip6tables-save | grep -q -- '--dport 2222 -j ACCEPT'
INNER
