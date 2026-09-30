# Ownership and consumer contracts

| Owner | Authority |
| --- | --- |
| Network | Six Clan role interfaces, native extensions, specialized Caddy construction, shared types and technical conflict checks |
| Host/consumer | Native ACME module and stock Lego, explicit certificate IDs/challenges/readers, sites and proxy/publisher routes, startup dependencies and package qualification |
| Machine/transport owner | Placement, physical WAN facts, IPv6/exposure policy, private address/interface readiness, transport grants and deployment |
| Secret owner | Encrypted values, recipients and state adoption; Network references only the named SOPS path |

Select roles through the catalog listed in the root README. Adjacent service
READMEs own exact settings and declarations. Importing internal modules or
replacing Network's Caddy package is unsupported. New settings require a concrete
consumer need and a Network release. Release and consumer adoption are separate
transactions described in [release](operations/release.md). Local evidence and
all PREDEPLOY acceptance requirements have one owner:
[verification](operations/verify.md).

## Certificate identity and readers

Declare `security.acme.certs.<explicitStableID>` directly. Preserve physical IDs:
they determine `/var/lib/acme/<id>` and unit names. A wildcard uses a star-free
ID and native SANs. Renaming changes storage identity; Network does not move or
adopt state. Changes under an existing ID may still alter issuance.

Each certificate explicitly selects its native challenge; null host-wide
challenge defaults ensure that misspelled reader references and reload-only
implicit entries fail validation. Native scalar/list composition remains native.
Separate IDs for the same domain need deliberate purpose/account intent.

Only Timeweb certificates receive the named SOPS credential and Timeweb IPv4
unit policy. The credential is `acme:acme`, mode `0400`; certificate group access
does not grant credential access. Other providers use native credentials. The
host's ACME/Lego pair owns retries, failure statuses and account handling.

Certificate consumers declare their exact notification targets and reader access
as described in the [Certificates reference](../clanServices/certificates/README.md).
Native `try-reload-or-restart` notification does not prove that a reader consumes
the renewed certificate. State/account adoption remains host-owned.

## Native Caddy composition

Consumers extend the native canonical site key without redeclaring its base
owner. The [Caddy reference](../clanServices/caddy/README.md) owns exact native
settings, listener/root conflicts, ordered route contributions and log policy.
Advertised endpoint metadata does not select the actual bind address. Consumers
own CONNECT scope, authentication, token policy, publisher behavior and sensitive
path logging. Network neither reconstructs nor scans their route text.

The proxy owner supplies one complete authenticated CONNECT fragment. The
consumer attaches it once to the explicit listener catch-all root and prepends
the same full fragment at priority 500 to every effective same-listener named
site whose canonical host or alias can match a target. Named outer Host routes
are terminal and precede the root, so root-only ordering and cover TLS SNI cannot
qualify that path. Keep each named site's owner, listeners, certificate, native
hostName and ordinary `forwardProxy = false`. Each attachment retains CONNECT
method and guards on both the actual selected local bind IPv4 and local port
443, including on mixed public/private listeners. `http.request.local.port` is
numeric and must compare with `443`. The target authority port is independent. Separate
listeners require their own declared roots and independently scoped policy.

The transport owner supplies one finite, read-only startup gate through native
`systemd.services.caddy.serviceConfig.ExecStartPre`. With a private listener and
no private address, cold start/restart remains fail-closed. There is no per-reload
gate, watcher, wildcard fallback or transport-loss unit binding. Native failed
reload preserves the old configuration/listeners/TLS; after the address returns,
an explicit reload applies changes. Independent public start/reload while the
configured private address is absent is not a requirement. The
[verification boundary](operations/verify.md) defines required observation of
these native transitions.

For Tailscale, Access supplies `access.lib.tailscaleReadyGate { pkgs; ipv4;
interface; }`, an executable derivation usable as a native unit command. Pass
the selected listener IPv4 and effective `services.tailscale.interfaceName`.
Consumer `pkgs` selects support tools only; the helper fixes the Access CLI.
The effective `services.tailscale.package` must equal
`access.packages.${system}.tailscale`. Attach the helper once to ordinary
`ExecStartPre`, without `+`/`!` or sandbox relaxation. Actual Caddy-UID access to
LocalAPI (`AF_UNIX`), interface inspection (`AF_NETLINK`) and cancellation remain
Access and consuming-unit responsibilities; their acceptance is defined in
[verification](operations/verify.md).

## Static artifacts

The website owns its immutable artifact and build. The role validates it and
declares the native canonical site, guarded alias redirects and a terminal
fallback. No SPA fallback or runtime fetch is supplied. Extensions use the same
canonical key. The consumer declares a certificate covering canonical/alias
hosts and owns deployment/exposure; selecting an ID does not prove live SANs.

## Firewall and WAN

One selected Firewall base owns native nftables policy. Destination-specific
public ports cannot also be opened by host/interface-wide ports or ranges.
Applications contribute `networking.firewall.privateIngress.<caller>` with an
explicit IPv4 destination and trusted interfaces. Loopback is implicit. Equal
normalized declarations compose; conflicting sets fail. The guard drops other
ingress before native/transport accepts and never grants traffic itself.
Application HTTP policy and transport grants stay with their owners.

Bootstrap SSH targets the static primary management IPv4 only. Its trusted marker
contains an absolute epoch deadline; reload/reboot preserves the remaining
lifetime. Missing, malformed or expired markers close new connections. Established
connections retain native conntrack behavior. Creating/renewing the marker and
the primary-transport handoff are explicit operator actions, never automatic.

One static WAN selection owns the primary main default and additional addresses.
An additional address with its own gateway needs explicit stable `routeTable`
and `rulePriority`; list order does not allocate identities. Local and earlier
transport selectors apply first, then non-default main routes, per-source WAN
default and ordinary main default. Native table/priority/device conflicts are
checked; arbitrary runtime rules remain transport/consumer-owned. Interface
readiness is separate from host-wide wait-online policy and Internet reachability.
