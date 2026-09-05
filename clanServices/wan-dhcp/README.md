# wan-dhcp

Thin independently selectable Clan service, role `host`. Runtime is limited to
x86_64-linux.

Requires `interface` and `macAddress`. Renames the interface by MAC, selects
systemd-networkd, disables global DHCP and enables DHCP on this interface.
`enableIPv6` is nullable and defaults null, leaving existing global IPv6 policy
unchanged; consumers preserving an IPv4-only host must explicitly set false.

Each selected service contributes a typed internal `networkCore.wan.claims`
entry. One owner per interface is required, including across DHCP/static roles.
Without a selected WAN service the package does not modify external networking.
Remove the old interface/network module when selecting this replacement.
