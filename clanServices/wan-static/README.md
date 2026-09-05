# wan-static

Thin independently selectable Clan service, role `host`. Runtime is limited to
x86_64-linux.

Requires `interface`, `macAddress`, `primaryIPv4`, `secondaryIPv4`,
`prefixLength`, `gateway`, `routeTableName` and `routeTableId`.
Exactly two distinct IPv4 addresses share the prefix on the MAC-pinned interface.
Native networkd receives a default gateway and a secondary-source IPv4 rule and
default route with that secondary address as preferred source.
`rulePriority` defaults 10010. `waitOnline.enable` defaults true and
`waitOnline.timeout` defaults 60 seconds; wait-online targets this interface at
routable state, with anyInterface disabled.

`enableIPv6` defaults null (no global override); set false to preserve the
original IPv4-only policy. The module explicitly selects systemd-networkd.
Claims reject duplicate WAN interface ownership and conflicting table IDs or
names across selected static instances. Reserved table IDs 253–255 are rejected.
No WAN selection leaves existing external networking untouched. Replace the old
static module and explicitly pass the consumer's former network/table values.
