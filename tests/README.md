# Independent package verification

Checks select raw Clan module IDs through an isolated synthetic consumer.
They force assertions, generated systemd units and the NixOS top-level
configuration without building or booting that host. Each primary capability
is selectable alone; wildcard claims require Certificates without implicitly
selecting Caddy or adding reload consumers. Combined Certificates/Caddy checks
cover native reload registration and deduplication.

The same evaluation-only predicates are available to the native macOS
`verify-fast` developer app through `lib.checkContracts`; Linux runtime checks
remain mandatory for runtime/release acceptance.

Negative fixtures reject competing WAN owners, invalid addresses, duplicate
MACs/interfaces/tables, multiple static WAN instances, invalid bootstrap
settings, overlapping Caddy listeners, public roots without exactly one owner,
undeclared renewal targets and inconsistent certificate ownership.

Runtime derivations execute on the existing x86_64-linux builder with isolated
processes and namespaces. Namespace creation failure fails the gate. They do not
boot VMs or contact a real DNS/ACME provider.

- Caddy checks the built plugin inventory and validates the generated Caddyfile.
  It retains forwardproxy and ratelimit, removes layer4, and uses h1/h2.
  Actual HTTP requests cover all three Vaultwarden authentication paths:
  fourteen successes, then rate limiting, with an adjacent route unaffected.
  Forwardproxy presence and composition are checked; CONNECT traffic is not.
- Firewall loads the full evaluated native nftables tables and sends real
  packets through isolated interfaces. It covers public/tailnet ports,
  IPv4/IPv6 HTTP rejection, key-only bootstrap configuration, absolute-deadline
  expiry without reload, explicit renewal, revocation, reload, unsafe markers,
  unrelated tables and a later independent ban chain. Expiry blocks new
  connections; existing conntrack sessions follow the native stateful policy.
- WAN runs native systemd-networkd with generated configuration. DHCP obtains
  a lease from local dnsmasq and reacquires it after a lease/address reset.
  Static WAN checks both addresses, policy routing and source selection.
  Both exercise carrier down/up. Read-only empty `/sys` uses networkd's
  container behavior; physical NIC renaming and production boot are not tested.
- The combined Certificates/Caddy contract evaluates provider-credential owner
  `acme`, group `acme` and mode `0400`, certificate group `acme`, and Caddy
  membership in that group. It does not prove SOPS delivery or actual runtime
  access and denial on a deployed machine; those remain separate machine
  acceptance. The synthetic distinct-UID fixture is retired by owner-approved
  scope decision, with no replacement mandatory local gate.
- ACME runs native issuance/renewal scripts with the authoritative Lego package
  against local Pebble HTTP-01. It verifies changed certificate serials and
  invokes the native postrun through a recording systemctl adapter that reloads
  a real Caddy process. TLS then serves the renewed certificate; absent renewal
  markers do not trigger duplicate notifications. This is not a booted systemd
  lifecycle or production Timeweb DNS-01 acceptance.
- The Lego package runs an offline Timeweb provider contract against local DNS
  and a mock HTTP API: v2 record creation, effective CNAME target, request body,
  authentication header, cleanup ID/path and failed-creation handling.

Only public certificates, serials, configuration and readable logs are retained
in check outputs. Generated private keys stay in the ephemeral build sandbox.
See [verification](../docs/operations/verify.md) for commands, artifacts and
remaining live acceptance boundaries.
