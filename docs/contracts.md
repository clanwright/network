# Ownership and consumer contracts

| Owner | Authority |
| --- | --- |
| Network | Implementation, defaults, dependency versions, exact Caddy/Lego builds, typed public contracts, technical compatibility checks |
| Service consumer | Sites and NaiveProxy snippets, structured listeners, certificate claims, certificate renewal notification units, generated route-fragment dependencies |
| Clanwright core | Machine placement and facts, mandatory profiles, public exposure approval, WAN data and IPv6 policy, encrypted secret values and recipients |

## Public integration

Select modules through the Network Clan catalog exported by the flake. The root
README lists names and roles; adjacent service READMEs define their settings.
Pin an exact released tag and retain its resolved lock. Do not override Network
packages, import internal modules, or use a consumer overlay to add a hidden
setting. New needs change the typed interface through a Network release.

## Certificates

Consumers contribute `networkCore.acme.certificateClaims`, optional ownership
records and `networkCore.acme.reloadServices`, keyed by declared certificate name.
Duplicate ownership is invalid; renewal consumers must reference declared claims.
The wildcard compatibility role contributes a claim to the same local lifecycle.

The Certificates role takes an ACME contact email and a named SOPS interface.
Network declares runtime access and passes only the resolved SOPS path to Lego;
core supplies encrypted values through its SOPS configuration. No credentials
belong in examples, Nix strings, logs or this repository's documentation. The
interface name is configurable; the supported provider and patched package are
Network-owned. Consumers own the units notified after renewal. This contract
does not transfer encrypted value ownership or authorize secret rotation.

## Caddy

Consumers contribute `networkCore.caddy.fragments` with structured host/listener,
certificate and ownership metadata alongside native route text. An empty IPv4
listener list is a wildcard; normalized host overlaps on overlapping listeners
are rejected. Forward-proxy capability claims are exclusive on shared listeners.
Network derives directive ordering from the requested capability. Consumers own
NaiveProxy configuration, authentication and route generation; Caddy does not
invent them. Referenced certificates must exist, and renewal notification remains
explicit. See the service reference for claim fields and fragment ordering.

## Host networking

Core supplies actual interface/MAC/address/gateway/table data. DHCP and static
WAN selections cannot own the same interface; static table ownership must also
be unambiguous. Externally managed WAN is allowed. Avoid retaining an old native
interface owner alongside its Network replacement: Network claim validation
cannot discover every arbitrary external networking implementation.

IPv6 is explicit host profile policy. WAN settings may carry that policy, while
an unset setting preserves existing policy; TCP tuning does not change it.
Firewall ports compose through native NixOS contributions. Core owns exposure
policy, including selection and lifecycle of the optional bootstrap SSH marker;
Network neither creates that marker nor implicitly grants public SSH access.
