# firewall

Thin independently selectable Clan service, role `host`. Runtime is limited to
x86_64-linux.

Enables the native NixOS nftables firewall, disables ping and automatic OpenSSH exposure.
Settings `public.allowedTCPPorts`, `public.allowedUDPPorts`, and
`interfaces.<name>.allowedTCPPorts/allowedUDPPorts` are additive native firewall
contributions (all default empty). Other services may contribute ports.

Applications may contribute `networkCore.firewall.privateIngressClaims.<caller>`
on a host selecting this role. Each claim requires a canonical `destinationIPv4`
and accepts `trustedInterfaces`, a list of Linux interface names. Loopback (`lo`)
is always trusted, including when the list is empty. A destination is protected
across all protocols and ports: traffic arriving on any other interface is
dropped before native firewall and Tailscale accept rules. The guard never opens
a port or grants traffic on a trusted interface; native firewall policy and
application authorization still apply. For example:

```nix
networkCore.firewall.privateIngressClaims.admin = {
  destinationIPv4 = "100.101.102.103";
  trustedInterfaces = [ "tailscale0" ];
};
```

Claims are keyed by caller identity. Interface order, duplicates and explicit
`lo` are normalized. Multiple callers may claim one address with the same
normalized set; conflicting sets fail evaluation. IPv6 destinations and unsafe
interface names fail type validation. Removing one claim retains independent
claims; removing the last claim removes its guard rule. Consumers own address
binding, Tailscale grants and public exposure decisions.

To migrate a copied private-ingress guard, select this role on the host, bind
the application to its explicit private IPv4 address (not a wildcard or IPv6
listener), and add the corresponding claim. Verify the evaluated destination
and interface rule before removing the copied guard. Keep application HTTP
policy, including `/admin` routing, and consumer grants in their existing owners.

`rejectHttp` defaults false and drops non-loopback TCP 80 on IPv4 and IPv6 when
enabled. `bootstrapSsh.enable` defaults false; enabling requires a canonical
IPv4 `publicIPv4` and defaults OpenSSH to key-only authentication. A stricter
consumer `AuthenticationMethods` setting, such as two public keys, is retained.
It adds an IPv4 TCP 22 accept rule only
while the configured address is present in a kernel timeout set. Independent
public and interface-specific TCP 22 contributions continue to apply. A later nftables
base chain, including fail2ban, can still drop a connection.

`bootstrapSsh.markerPath` defaults to `/var/lib/bootstrap/allow-wan-ssh` and
`durationSeconds` defaults to 3600 (the maximum). Core owns initial marker
creation and final removal. The marker must be a root-owned, non-writable,
regular non-symlink file in a safe root-owned directory and contain exactly one
decimal Unix expiry epoch plus newline. Missing and expired markers clear the
timeout set normally. Rejected invalid or untrusted markers also clear the set,
log a diagnostic, and converge closed without failing a successful nftables
lifecycle. Actual nftables errors remain failures. Because the deadline is absolute, reload and
reboot do not extend it; nftables enforces the remaining lifetime in-kernel.

`network-bootstrap-ssh-refresh` updates the timeout set in the native firewall
table without replacing unrelated tables. `network-bootstrap-ssh-renew` explicitly replaces
an existing trusted marker atomically with a new bounded deadline and refreshes
the set. Removal followed by refresh closes the bootstrap opening immediately.
The managed `network-edge-policy` table also owns private IPv4 ingress guards
and the optional HTTP drop. NixOS
replaces only declared tables on reload; the module forces whole-ruleset flushing
off so runtime tables owned by Tailscale, fail2ban and other services survive.
