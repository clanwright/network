# Architecture

Network supplies the implementation, defaults, package versions and contracts
for six separately selected Clan capabilities. It is a ready-made personal stack
with Timeweb DNS-01, the Network Caddy build and native NixOS/networkd composition.
Only x86_64-linux is supported. The optional Darwin formatter does not expand
that runtime boundary.

The flake exports Clan modules, exact package builds and local checks. Its locked
nixpkgs input is the package authority; Clan follows that input. All capabilities
release together. Consumers select exported Clan roles and typed settings rather
than importing implementation modules or replacing packages with overlays.
A missing setting is a proposed Network change and release, not an invitation
to bypass the contract.

Selection is independent: Certificates has no implicit Caddy dependency; Caddy
needs declared ACME certificates but does not select Certificates or Firewall.
Firewall does not select Access. WAN may be configured externally. Core profiles
choose mandatory capabilities and public exposure; Network checks technical
compatibility. TCP tuning does not choose IPv6 policy.

Certificates uses one Network-owned patched Lego package with Timeweb API v2
on every participating host. Issuance, keys and renewal stay local through native
NixOS ACME. Caddy owns its base runtime and validation; the service consumer owns
site and NaiveProxy route fragments. Native firewall and networkd facilities
remain the primary host implementation.

See [contracts](contracts.md) for authority boundaries and [verification](operations/verify.md)
for what establishes release readiness. No runtime or provider state is inferred
from the desired configuration.
