# Local verification

Local acceptance comprises source review, pure native composition, package builds
and the available ordinary process/tool checks on the existing x86_64-linux Nix
builder. Do not create a VM, root/systemd runner, test host or privilege,
credential or isolation workaround. Namespace prerequisites of the existing
process fixtures must be available; their absence is a failed local fixture,
not evidence of service-manager behavior. Actual manager/same-host behavior is
PREDEPLOY acceptance in the matrix below.

## Fast development gate

On the configured Apple Silicon development host:

```sh
nix run --no-write-lock-file --option builders "" .#verify-fast
```

The app runs pinned nixfmt, Statix, Deadnix, Bash syntax, whitespace checks and
all 14 evaluated contracts against the x86_64-linux configuration. Static checks
include nonignored untracked files. Native Git-flake evaluation requires newly
imported files to be visible to Git, for example with `git add --intent-to-add`.
Contract evaluation is offline, disables
import-from-derivation and remote builders, and fails on missing prerequisites.
It retains stage logs, elapsed milliseconds and exit codes in a unique
`.work/verification/fast-<run>/` directory. Developer tool downloads/builds on
first invocation are distinct from contract time.

```sh
nix eval --offline --json --no-write-lock-file \
  --option allow-import-from-derivation false --option builders "" \
  .#lib.checkContracts
```

`lib.checkContracts` and Linux check derivations share the same predicates and
an explicit coverage manifest. This gate proves configuration, not packet
handling, file permissions, deployed readers or live renewal.

## Native lock generation

Run with the installed Nix and the official stable Nix binary accepted by the
consumer. Keep both results; this is mandatory source-graph acceptance.

```sh
bash checks/nested-consumer-lock.sh
bash checks/nested-consumer-lock.sh --nix /absolute/path/to/official/nix
```

The native Git/Nix/rsync helper copies current staged, unstaged and nonignored
untracked source into disposable Git repositories. It exercises fresh direct
and intermediate-flake locking, a normal existing-lock update and byte-identical
relocking. Native Nix graph comparison checks resolved follows, exact identities
and dependency sharing; one real Clan role composition checks the catalog.
It does not alter the working checkout's index, refs or lock, or migrate consumer
inputs. `--source DIRECTORY` selects another source checkout. Logs and durations
remain in `.work/verification/nested-lock-unique/`.

## Linux builds and bounded process checks

Build all 24 outputs explicitly; on Darwin, a bare `nix flake check` can report
zero runtime checks. Preserve logs and measured whole-command time:

```sh
mkdir -p .work/verification
set -o pipefail
{ time nix build --no-link --print-out-paths --print-build-logs --no-write-lock-file \
  --impure --expr 'let f = builtins.getFlake ("git+file://" + toString ./.); in builtins.attrValues f.checks.x86_64-linux'; } \
  2>&1 | tee .work/verification/linux-checks.log
```

For one affected check, build `.#checks.x86_64-linux.<name>`. Store hits reuse
existing evidence; they do not mean that the test body ran again. When only docs
change, unchanged derivation identities may reuse accepted source-check evidence;
record the accepted immutable source, output identities and readable logs. Rerun
the fast gate on the final checkout and rebuild any changed derivation. Each runtime
fixture has finite process/request deadlines and retains readable results.

| Outputs | Useful coverage |
| --- | --- |
| `consumer-caddy`, `consumer-certificates`, `consumer-static-site`, `consumer-firewall`, `consumer-wan-dhcp`, `consumer-wan-static` | Actual independent Clan role selection, assertions and native generated units |
| `certificate-native-contracts`, `certificates-caddy-integration` | Stable IDs, wildcard SANs, scalar conflicts/list composition, null challenge defaults, implicit-reference failures, native notification and reader/credential configuration, stock host Lego/unit policy |
| `caddy-native-contracts` | Native owner/extension semantics, canonical DNS/listeners/aliases, proxy exclusivity and rejected configuration/package bypasses |
| `caddy-module-inventory`, `caddy-runtime` | Exact plugin inventory; one native config adaptation/validation, meaningful rate-limit requests, genuine returned-handler/error-handler failures and complete configured process sinks with positive leak controls |
| `static-site-contracts`, `static-site-invalid-artifacts`, `static-site-runtime` | Artifact/context/settings validation; generated multi-address catch-all/aliases, exact bodies, publisher-before-fallback, CONNECT origin positive/negative controls, custom/fallback 404 and explicit reload/artifact replacement |
| `timewebcloud-contract` | Stock Lego source/vendor/toolchain; local DNS/API mocks prove direct/CNAME record creation/cleanup and failures, with no provider/public DNS access |
| `acme-local-renewal` | Current native issuance/renewal scripts with local Pebble, stock host Lego, exact notification arguments and real Caddy served-certificate replacement through a recording process adapter |
| `firewall-invalid-bootstrap`, `firewall-public-destination-contracts`, `firewall-private-ingress-contracts` | Absolute-deadline settings, native base uniqueness, broader-accept port/range conflicts, explicit destinations and normalized private guards |
| `firewall-runtime`, `firewall-private-ingress-runtime` | Generated native nftables scripts and actual packets: expiry/renew/revoke, remaining deadline across reload, IPv4/IPv6 HTTP/private ingress and unrelated table preservation |
| `wan-selection-contracts`, `wan-dhcp-runtime`, `wan-static-runtime` | Interface/MAC/route ownership, stable IDs/native alias conflicts/readiness, available networkd process addressing/routing/carrier recovery and representative transport precedence |

The process fixtures qualify the generated configuration and bounded requests.
For a concrete CONNECT consumer, also inspect adapted Host matchers and effective
bind/443 listeners; test a target matching a named vhost with correct, missing and
wrong credentials and origin controls. This available source/process seam must
pass before publication. Its policy belongs in [contracts](../contracts.md).

The local ACME fixture uses Pebble HTTP-01 and a recording/reloading process
adapter, not a service manager or Timeweb DNS-01. Generated fixture keys are
removed before retaining outputs. Actual credential/reader permissions require
the PREDEPLOY acceptance below. Existing certificate/account state and the
host-native ACME/Lego pair need consumer qualification; no Network account-migration adapter is supplied.

## PREDEPLOY acceptance

This is the canonical remaining runtime matrix. Every row is **PREDEPLOY / NOT
OBSERVED** by local acceptance. No existing root/systemd runner is available; the
owner deferred these actual cases and forbids a replacement runner. These rows
do not block source delivery, and local process PASS never changes their status.

| Owner | Required actual evidence | Status |
| --- | --- | --- |
| Access and consuming unit owner | Finite readiness helper under actual Caddy UID/sandbox; private address/interface checks through `AF_NETLINK`, Tailscale LocalAPI through `AF_UNIX`, finite deadline, actual manager stop/restart and TERM/KILL cancellation including TERM-resistant descendant/cgroup cleanup; fail-closed cold start/restart without private IP | PREDEPLOY / NOT OBSERVED |
| Network and Apps/VPN | Actual service manager with assembled vendor unit/drop-ins, environment and identity; same-host public/private FD ownership and sockets; missing-IP failed atomic reload retains old public routes/listeners/TLS; explicit reload after IP return; transport-loss/return and listener lifetime behavior | PREDEPLOY / NOT OBSERVED |
| Apps/VPN | Real auth/token/CONNECT/login paths, named-host/alias precedence, positive origin controls, real TLS and all configured journal/access/error sinks; successful and failing sensitive requests without raw/encoded secret leakage | PREDEPLOY / NOT OBSERVED |
| Certificate host and each reader | Actual credential `0400` owner/denial, groups and `LoadCredential` delivery; exact reload/restart recipients and renewed certificate consumption; existing certificate/account state adoption | PREDEPLOY / NOT OBSERVED |
| Network and machine/transport owner | Physical NIC naming and boot order, WAN policy precedence/carrier recovery, bootstrap absolute deadline across reboot/reload and primary transport handoff | PREDEPLOY / NOT OBSERVED |
| Provider/operator | Production DNS-01 propagation and issuance, live ACME endpoints and DNS credential scope | PREDEPLOY / NOT OBSERVED |

Reuse shared evidence only where behavior is identical. No VM, new system manager
runner or privilege/isolation workaround is permitted. Provider/DNS, live ACME,
deploy, backup writer, restore/prune and credential/secret mutations retain their
separate owner-approval boundaries. Publication and source adoption are distinct
from these actions; see [release and adoption](release.md).
