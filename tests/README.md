# Independent package verification

The checks instantiate external Clan consumers using the published raw module
IDs. Each primary brick is selected on its own. The wildcard helper is tested
with its required certificate service and must not select Caddy or register an
implicit reload consumer. Consumers force all assertions, rendered systemd unit
texts, and the NixOS top-level derivation without building or booting that host.

Negative fixtures reject competing WAN owners, reserved routing tables, missing
bootstrap addresses, overlapping Caddy claims (including explicit `0.0.0.0`
listeners), undeclared renewal targets, and inconsistent explicit/inline
certificate owners. Matching certificate owners are accepted.

Runtime derivations execute on the existing x86_64-linux builder. They never boot
a VM or contact a provider. Namespace creation failure fails the check.

- Caddy validates the actual generated native Caddyfile with consumer site and
  forward-proxy contributions, including native required-unit ordering. Only
  certificate fixture paths are relocated; keys
  are generated in the build sandbox and never copied to check outputs.
- Firewall executes the actual evaluated start and stop rules in a private
  network namespace. It verifies IPv4/IPv6 rule convergence, marker-controlled
  bootstrap SSH, HTTP rejection, teardown, and preservation of unrelated rules.
  This is rule-state verification, not an end-to-end packet reachability test.
- WAN starts native systemd-networkd with generated native configuration in a
  private user/network/mount namespace and fixture root. Read-only empty `/sys`
  follows systemd's container interface, disabling the absent udev dependency.
  DHCP obtains a real lease from namespace-local dnsmasq; static WAN verifies
  both addresses, policy routing, and source-specific route selection. These
  tests do not exercise physical NIC renaming, carrier loss, or host boot order.
- ACME executes native order/renew scripts with the authoritative Lego package
  against a local Pebble CA using actual HTTP-01 validation. It verifies changed
  certificate serials and executes the native post-renew script, relocating only
  its fixture directory. A recording `systemctl` stub verifies notification
  requests and suppresses duplicates when no renewed marker exists. It does not
  claim a running systemd consumer was restarted or that Timeweb DNS-01 was
  exercised. Only public certificates, serials, and logs are retained.

Systemd initialization evidence is from upstream v261.2:
`src/network/networkd-link.c` calls `udev_available()` before waiting for device
initialization; `src/shared/udev-util.c` determines availability from whether
`/sys` is read-only. No daemon patch or builder capability override is used.
