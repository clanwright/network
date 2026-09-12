# wan-static

Thin independently selectable Clan service, role `host`. Runtime is limited to
x86_64-linux.

Requires `interface`, `macAddress`, `primaryIPv4`, `secondaryIPv4`,
`prefixLength`, `gateway`, `routeTableName` and `routeTableId`.
Exactly two distinct IPv4 addresses share the prefix on the MAC-pinned interface.
Native networkd receives a default gateway and a secondary-source IPv4 rule and
default route with that secondary address as preferred source.
`rulePriority` defaults 10010. `waitOnline.enable` defaults true and
`waitOnline.timeout` defaults 60 seconds; a dedicated readiness unit targets
this interface at routable state. Consumer-owned global networkd wait-online
enablement, any-interface policy, arguments and timeout remain unchanged.

`enableIPv6` defaults null (no global override); set false to preserve the
original IPv4-only policy. The module explicitly selects systemd-networkd.
Claims reject duplicate WAN interface ownership. A host may select at most one static WAN
instance, while that instance may retain two IPv4 addresses on its one physical
interface. Physical MAC ownership is case-insensitive and unique even when two
claims use different interface names. IPv4 settings use canonical dotted-decimal
octets and `rulePriority` is limited to the networkd unsigned 32-bit range
excluding zero. Reserved table IDs 253–255 are rejected.
No WAN selection leaves existing external networking untouched. Replace the old
static module and explicitly pass the consumer's former network/table values.
