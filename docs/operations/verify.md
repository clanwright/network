# Local verification

Run from the Network repository on the configured development host. Runtime
checks target x86_64-linux using the existing Linux builder. Do not add QEMU VM
configuration or change builders to make a gate pass. Namespace availability is
a check prerequisite, not permission to skip a release gate.

Preserve readable output and elapsed time in the ignored `.work/verification/`
area. One focused check can be run with this zsh sequence; replace only the check
name with one from the table below:

```sh
mkdir -p .work/verification
set -o pipefail
check_name=consumer-certificates
{ time nix build --no-link --print-out-paths ".#checks.x86_64-linux.${check_name}"; } 2>&1 | tee ".work/verification/${check_name}.log"
```

| Existing check outputs | Purpose | Successful derivation artifacts |
| --- | --- | --- |
| `consumer-certificates`, `consumer-caddy`, `consumer-firewall`, `consumer-wan-dhcp`, `consumer-wan-static`, `consumer-tcp-tuning` | Independent Clan consumer evaluation and selected contracts | Gate output; retain command log |
| `incompatible-selections` | Negative selection and ownership fixtures | Gate output; retain command log |
| `caddy-config` | Adapt and validate rendered Caddy configuration | `Caddyfile.original`, `Caddyfile`, `config.json`, `certificate-generation.log`, `adapt.log`, `validate.log` |
| `firewall-runtime` | Isolated Linux firewall lifecycle | `runtime.log` |
| `wan-dhcp-runtime`, `wan-static-runtime` | Native networkd behavior in isolated Linux namespaces | `runtime.log` |
| `acme-local-renewal` | Native ACME script lifecycle against local test transport | `runtime.log` |

The complete local flake gate is:

```sh
{ time nix flake check --system x86_64-linux --print-build-logs; } 2>&1 | tee .work/verification/flake-check.log
```

Release acceptance requires all check outputs to pass for the exact source being
tagged, together with formatting, Statix, Deadnix and independent review. Retain
command logs and elapsed times; failed builds may have no output directory.

The ACME fixture uses the actual patched Lego package and native issuance/renewal
scripts against local Pebble HTTP-01; renewal changed the certificate serial.
The native postrun path was inspected using a recording systemctl stub, not a
booted consumer service. This replaces the real DNS challenge transport and does
not prove Timeweb API credentials, real DNS propagation, production issuance or
a running consumer service reload.
Likewise local namespace checks do not establish deployed host connectivity.
Live ACME, DNS/provider actions, deployment and secret rotation remain separate
explicit approvals.
