# wan-static

Thin independently selectable Clan service, role `host`. Runtime is limited to
x86_64-linux.

Requires `interface`, `macAddress`, `primaryIPv4`, `prefixLength` and `gateway`.
The primary address, its prefix and its gateway own the host default route;
networkd receives that route with the primary address as preferred source, so
default egress stays on the primary address.

`additionalIPv4s` defaults to an empty list and accepts any number of entries
`{ address; prefixLength ? null; gateway ? null; }` on the same MAC-pinned
interface:

- An entry without `gateway` must lie inside the primary prefix and may only
  repeat the primary `prefixLength`. It becomes a plain additional address;
  replies use the contacted address as source and the primary gateway.
- An entry with `gateway` may lie in another prefix; `prefixLength` still
  defaults to the primary's. Networkd receives a `from <address>/32` rule and a
  table holding that prefix as an on-link route and a default route through the
  entry's gateway, both with the entry as preferred source.

Entry `i` uses table `routeTableBase + i` (default base 1000) and rule priority
`rulePriorityBase + i` (default base 10010); only entries with a gateway create
tables and rules. Numbers follow list position, so reordering or inserting
entries renumbers later tables and rules. Choose the bases so that the
generated range avoids the consumer's own tables and rules.

A source rule sends all traffic from its address to the entry's table, ahead of
the main table. Routes that other interfaces (tunnels, containers) add to the
main table are therefore not used for traffic sourced from such an address;
bind services that must answer through those interfaces to a gateway-less
address.

```nix
settings = {
  interface = "wan0";
  macAddress = "02:00:00:00:00:01";
  primaryIPv4 = "192.0.2.23";
  prefixLength = 24;
  gateway = "192.0.2.1";
  additionalIPv4s = [
    { address = "192.0.2.60"; }
    { address = "192.0.2.82"; }
    { address = "198.51.100.5"; prefixLength = 24; gateway = "198.51.100.1"; }
  ];
  enableIPv6 = false;
};
```

Evaluation rejects duplicate addresses, a gateway-less entry outside the primary
prefix, a gateway outside its address prefix or equal to a host address,
generated tables in the reserved range 253–255 or above the unsigned 32-bit
limit, and generated rule priorities that would not precede the main table rule
(above 32765). IPv4 settings use canonical dotted-decimal octets.
Gateways outside their prefix (on-link gateways) are not supported.

`waitOnline.enable` defaults true and `waitOnline.timeout` defaults 60 seconds;
a dedicated readiness unit targets this interface at routable state.
Consumer-owned global networkd wait-online enablement, any-interface policy,
arguments and timeout remain unchanged.

`enableIPv6` defaults null (no global override); set false to preserve the
original IPv4-only policy. The module explicitly selects systemd-networkd.
Claims reject duplicate WAN interface ownership. A host may select at most one
static WAN instance, carrying all of its IPv4 addresses on its one physical
interface. Physical MAC ownership is case-insensitive and unique even when two
claims use different interface names.
No WAN selection leaves existing external networking untouched.

## Migration from `secondaryIPv4`

Version 4 removes `secondaryIPv4`, `routeTableName`, `routeTableId` and
`rulePriority`. Move the former secondary address into `additionalIPv4s`:

- Same prefix and gateway as the primary: `{ address = <secondaryIPv4>; }`.
  The former per-address table and rule are no longer created; replies leave
  through the same gateway as before.
- To keep a dedicated table and rule, add `gateway = <gateway>;` to the entry
  and set `routeTableBase`/`rulePriorityBase` so that the entry's index maps to
  the former `routeTableId` and `rulePriority`. Rule priorities are now limited
  to 32765 so that they precede the main table; a former higher priority must
  be lowered. The named networkd route table is not recreated; tables are
  numeric, so consumer configuration referring to the former `routeTableName`
  must use the number.
