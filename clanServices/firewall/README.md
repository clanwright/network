# firewall

Thin independently selectable Clan service, role `host`. Runtime is limited to
x86_64-linux.

Enables the native NixOS firewall, disables ping and automatic OpenSSH exposure.
Settings `public.allowedTCPPorts`, `public.allowedUDPPorts`, and
`interfaces.<name>.allowedTCPPorts/allowedUDPPorts` are additive native firewall
contributions (all default empty). Other services may contribute ports.

`rejectHttp` defaults false and drops non-loopback TCP 80 on IPv4 and IPv6 when
enabled. `bootstrapSsh.enable` defaults false; enabling requires `publicIPv4`.
`bootstrapSsh.markerPath` defaults to /var/lib/bootstrap/allow-wan-ssh.
The consumer workflow owns creating/removing this marker; firewall reload
converges its effect. No Access dependency or marker creation is included.

The existing NIXOS_EDGE_FIREWALL chain and marked jumps retain their ownership:
reload removes only owned marked jumps, flushes the private chain, and reinstalls
it before other INPUT jumps. Bootstrap enablement also removes the exact legacy
destination-qualified IPv4 port 22 rule; generic unmarked SSH rules remain alone.
Stop removes only marked jumps and the private chain. Rules use iptables as in
the original implementation. The consumer must avoid simultaneously retaining
the old edge-firewall owner. Set both switches true to preserve its behavior.
