# Local verification

Run from the Network repository on the configured development host. Runtime
checks use the existing x86_64-linux builder. Do not change builders or add QEMU
VM configuration to make a gate pass. Namespace availability is a prerequisite;
its absence fails the runtime gate.

## Fast development gate on Apple Silicon macOS

```sh
nix run --no-write-lock-file --option builders "" .#verify-fast
```

This developer app runs pinned nixfmt, Statix, Deadnix, whitespace checks and
all evaluation-only contracts against the unchanged x86_64-linux target. It
exports no Darwin runtime packages or NixOS support. The contract predicates
are shared with the existing Linux flake checks through `lib.checkContracts`.

The initial app invocation may download the locked sources and native developer
tools. Contract evaluation itself is offline, disables import-from-derivation
and disables remote builders: a missing prerequisite fails instead of silently
starting a Linux build. Each run retains stage logs and milliseconds/exit codes
in a unique `.work/verification/fast-<run>/` directory. This gate does not prove
Linux binaries, packet handling, actual file permissions or certificate renewal.

To inspect only the evaluated contracts:

```sh
nix eval --offline --json --no-write-lock-file \
  --option allow-import-from-derivation false --option builders "" \
  .#lib.checkContracts
```

## Linux runtime and release acceptance

The combined Certificates/Caddy evaluation checks that the provider credential
is configured with owner `acme`, group `acme` and mode `0400`, that certificate
files use group `acme`, and that Caddy belongs to that group. These predicates
do not prove SOPS delivery or actual runtime access and denial on a deployed
machine. Those permissions remain a separate machine acceptance boundary.

The synthetic distinct-UID permission fixture is retired by owner-approved
scope decision; there is no replacement mandatory local gate.

Preserve readable output and elapsed time under ignored `.work/verification/`:

```sh
mkdir -p .work/verification
set -o pipefail
check_name=certificates-caddy-integration
{ time nix build --no-link --print-out-paths ".#checks.x86_64-linux.${check_name}"; } 2>&1 | tee ".work/verification/${check_name}.log"
```

| Check outputs | Purpose |
| --- | --- |
| `consumer-certificates`, `consumer-caddy`, `consumer-firewall`, `consumer-wan-dhcp`, `consumer-wan-static` | Independent capability selection through the Clan catalog; evaluated assertions and units |
| `consumer-wildcard`, `incompatible-certificate-reload`, `certificate-owner-consistency` | Wildcard adapter, reload target and ownership contracts |
| `certificates-caddy-integration` | Combined native reload registration/deduplication, credential owner/group/mode `acme`/`acme`/`0400`, certificate group `acme`, and Caddy certificate-group membership |
| `acme-local-renewal` | Native issuance/renewal against local Pebble; running Caddy serves the renewed certificate |
| `caddy-contribution-dependencies`, `caddy-wildcard-listener-collisions`, `caddy-public-site-owner` | Fragment composition, listener collision and public-root ownership |
| `caddy-module-inventory`, `caddy-config`, `caddy-ratelimit-runtime` | Exact plugin inventory, rendered config validation and rate-limited HTTP requests |
| `firewall-invalid-bootstrap`, `firewall-runtime` | Bootstrap settings and native nftables packet/lifecycle checks |
| `wan-selection-contracts`, `wan-dhcp-runtime`, `wan-static-runtime` | Interface/MAC/table ownership, one static WAN, actual networkd addressing and carrier recovery |

Build every Linux check explicitly for release acceptance:

```sh
set -o pipefail
{ time nix build --no-link --print-out-paths --print-build-logs --no-write-lock-file \
  --impure --expr 'let f = builtins.getFlake (toString ./.); in builtins.attrValues f.checks.x86_64-linux'; } \
  2>&1 | tee .work/verification/all-checks-build.log
```

Do not use a successful `nix flake check --system x86_64-linux` on Darwin
as runtime acceptance: it can evaluate the Linux derivations while reporting
`running 0 flake checks`. The explicit build above requests every Linux check
regardless of the development host. Existing valid store outputs are reused;
this does not mean each test was executed again.

Run formatting, Statix and Deadnix from the pinned toolchain as release gates:

```sh
check_tools="$(nix build --no-link --print-out-paths --impure --expr '
  let f = builtins.getFlake (toString ./.);
      p = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  in p.symlinkJoin { name = "network-check-tools"; paths = [ p.nixfmt p.statix p.deadnix ]; }')"
git ls-files -z '*.nix' | xargs -0 "$check_tools/bin/nixfmt" --check
"$check_tools/bin/statix" check . --ignore .work
git ls-files -z '*.nix' | xargs -0 "$check_tools/bin/deadnix" --fail
```

Use the locked nixpkgs tools, not an unrelated channel. For example, obtain
`statix` and `deadnix` from this flake's locked input through `nix build --expr`
or the configured development environment. No runtime architecture is added by
the optional Darwin formatter. Release acceptance also requires independent
review and the exact-source checks above.

Caddy checks retain public config, adaptation/validation logs and runtime logs.
ACME outputs retain public certificates, serial evidence and logs, never generated
private keys. The postrun fixture invokes a recording systemctl adapter that
reloads a real Caddy process; this proves the new certificate is served but does
not boot a full consumer systemd installation. The DNS challenge transport is
local Pebble HTTP-01, not production Timeweb DNS-01. Provider credentials, real
propagation and live issuance require separate authorized acceptance. The Lego
package separately runs an offline Timeweb v2 contract against local DNS and a
mock HTTP API, covering CNAME targets, record creation, cleanup and failures.

Firewall checks use full evaluated native tables and actual packets in isolated
namespaces. They test bootstrap expiration without firewall reload, renewal,
revocation, reload, IPv4/IPv6 HTTP blocking and preservation of unrelated tables.
WAN checks exercise native networkd leases, routing and carrier recovery; physical
NIC/udev renaming and production boot order still require machine acceptance.
Local checks never establish deployed host connectivity or stunnel readiness.

The shared consumer harness is a synthetic in-repository consumer with an isolated
on-disk fixture directory. Actual independent-flake integration is additionally
checked in the Clanwright candidate worktree; a local source override does not
prove released-tag adoption. See [release and adoption](release.md).
