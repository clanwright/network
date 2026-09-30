# wan-static

Independently selectable Clan service, role `host`, for x86_64-linux.

Requires `interface`, `macAddress`, `primaryIPv4`, `prefixLength` and `gateway`.
The native systemd `.link` pins the physical interface by MAC. The primary
address owns the main default route and its preferred source, so ordinary
protocol egress uses the primary address. Host IPv6 policy belongs to native
`networking.enableIPv6`.

`additionalIPv4s` defaults to `[]`. Each entry has `address` and optional
`prefixLength`, `gateway`, `routeTable` and `rulePriority`:

- Without `gateway`, an address must lie in the primary prefix. Its prefix
  length defaults to the primary length and may only repeat that length.
  No additional table or rule is created, and route IDs must be omitted.
- With `gateway`, the address may use a different prefix; its prefix length
  still defaults to the primary length. Both `routeTable` and `rulePriority`
  are required. Networkd creates an on-link prefix route and a default route
  in that table, plus a source rule for the address's `/32`.

IDs belong to the address declaration and survive list reordering. Tables are
unsigned 32-bit integers greater than zero; kernel tables 253–255 and the
representative Tailscale transport table 52 are reserved. Source-rule priorities
must be distinct integers from 10001 through 32765. Evaluation rejects duplicate
IDs, a second native IPv4 routing-policy rule at an owned priority, and another
native IPv4 route, policy or active DHCPv4 route-table claim using an owned table.
IPv6-only reuse of a numeric table or priority belongs to the separate IPv6 FIB
and is permitted; this service owns IPv4 routing.
Native named table aliases are resolved and the owning `.network` device is
checked; identical route text on a different device is still a conflict.
While separate-gateway tables are owned, evaluated native IPv4 route/rule
`Table` and active DHCPv4 `RouteTable` values must be positive uint32 integers,
canonical positive decimal strings without leading zeros, built-in names
`local` / `main` / `default`, or valid declared `systemd.network.config.routeTables`
aliases. Alias names use letters, digits, `_`, `.`, `+` or `-`, must contain a
nondigit, and map to positive uint32 IDs other than 253–255. Every declared alias
must satisfy this grammar while separate-gateway IPv4 tables are owned, even
when a particular alias is unused; spaces or punctuation cannot inject native
alias pairs into the generated configuration. Aliases resolve
before decimal values, matching networkd's name precedence. All declared alias
IDs must be distinct while separate-gateway IPv4 tables are owned: networkd
discards a later alias using an already declared ID, allowing numeric-looking
names to fall back to its number parser. Hexadecimal,
octal, binary and signed numeric spellings require an explicit valid alias;
otherwise evaluation rejects them to keep native table ownership unambiguous.
The final native `systemd.network.config.networkConfig.RouteTable` must equal
the pairs generated from this map; raw additions, overrides and reset entries
are unsupported while separate-gateway IPv4 tables are owned. Enabled native
policy `Family`, `From`, `To` and route `Destination`, `Gateway`, `Source`,
`PreferredSource` values must be single-line scalar strings without LF/CR in
that case. Repeated native
assignments cannot obscure the address family used by collision checks.
All structured data in enabled `systemd.network.networks` and global
`systemd.network.config` must have single-line keys and string/path/package
values without LF/CR while separate-gateway IPv4 tables are owned. Native
boolean, numeric and null values and repeated nonclassifier values remain
supported; functions and arbitrary coercible objects are unsupported. Enabled
network `extraConfig` must be empty: raw INI cannot participate in typed table
ownership checks. Disabled network declarations do not claim tables.
This proof covers those evaluated native data options. Direct `.network` unit
overrides through `systemd.network.units`, replacements through `environment.etc`,
and runtime rules created outside them remain the consumer's responsibility.

For routed additional addresses, one native IPv4 rule at priority 10000 looks
up main with `SuppressPrefixLength = 0`. The RPDB therefore applies local
routing and earlier explicit transport selectors first, retains applicable
non-default main routes, then tries the address-specific WAN gateway, and
finally the ordinary main default. There is no automatic CGNAT/private-range
exception or custom route allocator.

The representative standard Linux
[Tailscale policy](https://github.com/tailscale/tailscale/blob/main/wgengine/router/osrouter/router_linux.go)
uses priorities 5210, 5230 and 5250 for its marked transport bypass, followed by
5270 for table 52. These precede Network's lookup. Other transports must place
applicable selectors before 10000; Network does not promise precedence over
arbitrary later selectors. An exit-node default in an earlier transport table
also retains its native precedence.

```nix
settings = {
  interface = "wan0";
  macAddress = "02:00:00:00:00:01";
  primaryIPv4 = "192.0.2.23";
  prefixLength = 24;
  gateway = "192.0.2.1";
  additionalIPv4s = [
    { address = "192.0.2.60"; }
    {
      address = "198.51.100.5";
      prefixLength = 24;
      gateway = "198.51.100.1";
      routeTable = 1002;
      rulePriority = 10012;
    }
  ];
};
networking.enableIPv6 = false;
```

Addresses must be distinct canonical dotted-decimal IPv4 values. Each gateway
must be in its address prefix and must differ from every host address.
Off-prefix/on-link gateways are unsupported. Static bootstrap SSH, when selected,
may target only `primaryIPv4`; additional protocol addresses cannot open it.

`waitOnline.enable` defaults true and `waitOnline.timeout` defaults 60 seconds.
A narrow drop-in for native `systemd-networkd-wait-online@<interface>` requires
that interface to become routable. The global networkd wait-online enablement,
any-interface choice, arguments and timeout remain consumer-owned. Routable
state does not establish Internet reachability.

One host may select one static WAN instance, carrying all its addresses. Shared
checks reject duplicate interface names and case-insensitive MAC identities
across static and DHCP selections. Physical NIC/udev renaming and production
boot order require separate machine acceptance.
