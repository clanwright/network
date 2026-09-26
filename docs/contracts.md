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
Network-owned. The credential is owned by `acme` with mode `0400`; certificate
readers must not inherit credential access. Root compromise on an issuing host
can still expose DNS API privileges; this accepted boundary does not claim
zone isolation. Native NixOS Caddy registers its reload automatically for each `useACMEHost`;
consumers explicitly register other units. The final notification list is deduplicated
for Network-owned certificate claims; unrelated native certificates retain their
notification lists. Derived ownership records are internal read-only results. This contract
does not transfer encrypted value ownership or authorize secret rotation.

## Caddy

Consumers contribute `networkCore.caddy.fragments` with structured host/listener,
certificate and ownership metadata alongside native route text. An empty IPv4
listener list is a wildcard; normalized host overlaps on overlapping listeners
are rejected. Forward-proxy capability claims are exclusive on shared listeners
and require a listener-wide `:443` site address in the assembled declaration.
A public root (`publicSite = true`) requires exactly one nonempty `siteOwners`
token. Log paths must be absolute and safe for both Caddy and tmpfiles syntax.
Network derives directive ordering from the requested capability. Consumers own
NaiveProxy configuration, authentication and route generation; Caddy does not
invent them. Referenced certificates must exist. Caddy renewal registration is
native; other service notifications remain explicit. See the service reference for claim fields and fragment ordering.

## Static sites

The static-site role consumes an already-built, immutable Nix static directory.
The website owns source, dependency pins, build tools and output. The consumer
selects the artifact, canonical host, aliases, existing certificate, listener,
placement and public claim identity. Network validates the artifact at build
time and owns file serving, browser alias redirects and real HTTP 404 responses.
It does not build the website, fetch content at runtime or provide SPA fallback.

Each instance emits one Caddy claim through the existing ownership and conflict
checks. Select the Caddy ingress separately. A public instance supports existing
NaiveProxy contributions to its explicit claim name; Network does not add proxy
authentication or routing. A second nonpublic instance can serve the same
artifact on a secondary host. Nonpublic metadata does not imply network privacy.

The consumer must select a certificate covering every served host and redirect
alias, including secondary instances. Referencing an existing certificate does
not prove the deployed certificate's SANs. Domain and exposure approval remain
with the consumer/core. See the [role reference](../clanServices/static-site/README.md)
for settings and migration.

## Host networking

Core supplies actual interface/MAC/address/gateway/table data. DHCP and static
WAN selections cannot own the same interface or normalized physical MAC. At most one static WAN instance is
supported per host, retaining its two IPv4 addresses. Externally managed WAN is allowed. Avoid retaining an old native
interface owner alongside its Network replacement: Network claim validation
cannot discover every arbitrary external networking implementation.

Static WAN readiness waits for its claimed interface through a dedicated unit.
The consumer retains the global networkd wait-online policy. Network uses one
canonical IPv4 type for WAN addresses, Caddy listeners and bootstrap SSH.

IPv6 is explicit host profile policy. WAN settings may carry that policy, while
an unset setting preserves existing policy. TCP tuning belongs to the consumer
VPN domain and is no longer a Network capability.
Firewall ports compose through native NixOS contributions on the nftables
backend. Legacy iptables policy is not supported by this candidate. Core owns exposure
policy, including selection and lifecycle of the optional bootstrap SSH marker;
Network neither creates that marker nor implicitly grants public SSH access.
Applications may contribute typed `networkCore.firewall.privateIngressClaims`
keyed by caller identity while core selects the Firewall role. Each claim binds
an explicit private IPv4 destination to trusted incoming interfaces; loopback
is implicit. Network drops all other ingress to that destination before native
and Tailscale accepts, across protocols and ports, without adding an accept.
Identical normalized claims compose; conflicting interface sets for an address
fail evaluation. Core supplies actual addresses and interfaces and retains
Tailscale grants and deployment ownership.
Bootstrap disables password and keyboard-interactive authentication and defaults
to public-key authentication, preserving an explicit stricter consumer method.
Rejected markers close the temporary opening and produce a diagnostic; failure
to apply nftables changes remains an error.

Remote private administration requires binding services to the actual Tailscale
IPv4 address and contributing a `privateIngressClaims` entry that trusts
`tailscale0` through the selected Network Firewall role. The consumer retains
Tailscale grants and application HTTP policy, including any `/admin` routing. The former
`tailnet_only` CGNAT-source snippet is removed: a source range alone does not
authenticate tailnet membership. Core also owns Tailscale grants/ACL policy.
Bootstrap deadlines and handoff procedures are specified by the Firewall service
reference and core operator runbook; applying or rebooting a firewall must not
renew an expired deadline.
