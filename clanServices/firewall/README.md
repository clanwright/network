# firewall

Thin independently selectable Clan service, role `host`. Runtime is limited to
x86_64-linux.

Enables the native NixOS nftables firewall, disables ping and automatic OpenSSH exposure.
Settings `public.allowedTCPPorts`, `public.allowedUDPPorts`, and
`interfaces.<name>.allowedTCPPorts/allowedUDPPorts` are additive native firewall
contributions (all default empty). Other services may contribute ports.

`rejectHttp` defaults false and drops non-loopback TCP 80 on IPv4 and IPv6 when
enabled. `bootstrapSsh.enable` defaults false; enabling requires `publicIPv4` and
forces key-only OpenSSH authentication. It adds an IPv4 TCP 22 accept rule only
while the configured address is present in a kernel timeout set. Independent
public and interface-specific TCP 22 contributions continue to apply. A later nftables
base chain, including fail2ban, can still drop a connection.

`bootstrapSsh.markerPath` defaults to `/var/lib/bootstrap/allow-wan-ssh` and
`durationSeconds` defaults to 3600 (the maximum). Core owns initial marker
creation and final removal. The marker must be a root-owned, non-writable,
regular non-symlink file in a safe root-owned directory and contain exactly one
decimal Unix expiry epoch plus newline. Empty, stale, malformed, overlong or
untrusted markers fail closed. Because the deadline is absolute, reload and
reboot do not extend it; nftables enforces the remaining lifetime in-kernel.

`network-bootstrap-ssh-refresh` updates the timeout set in the native firewall
table without replacing unrelated tables. `network-bootstrap-ssh-renew` explicitly replaces
an existing trusted marker atomically with a new bounded deadline and refreshes
the set. Removal followed by refresh closes the bootstrap opening immediately.
The managed `network-edge-policy` table also owns the optional HTTP drop. NixOS
replaces only declared tables on reload; the module forces whole-ruleset flushing
off so runtime tables owned by Tailscale, fail2ban and other services survive.
