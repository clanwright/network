> **Archived.** This module now lives in the Clanwright monorepository as
> `bricks/network` (https://github.com/ibelyasov/clanwright) and is no longer
> developed or released here.

# Network

Network is the x86_64-linux networking stack in the public
`clanwright/network` project. Six separately selectable Clan capabilities
share one dependency lock and one atomic SemVer release.

| Capability | Clan module | Role | Implementation reference |
| --- | --- | --- | --- |
| Certificates | `@clanwright/network-certificates` | `server` | [Certificates](clanServices/certificates/README.md) |
| Caddy | `@clanwright/network-caddy` | `ingress` | [Caddy](clanServices/caddy/README.md) |
| Static sites | `@clanwright/network-static-site` | `site` | [Static sites](clanServices/static-site/README.md) |
| Firewall | `@clanwright/network-firewall` | `host` | [Firewall](clanServices/firewall/README.md) |
| WAN DHCP | `@clanwright/network-wan-dhcp` | `host` | [WAN DHCP](clanServices/wan-dhcp/README.md) |
| WAN static | `@clanwright/network-wan-static` | `host` | [WAN static](clanServices/wan-static/README.md) |

Documentation index:

- [Architecture and scope](docs/architecture.md)
- [Ownership and consumer contracts](docs/contracts.md)
- [Local verification](docs/operations/verify.md)
- [Release and consumer adoption](docs/operations/release.md)
- [Contributor instructions](AGENTS.md)
- [Agent issue tracker](docs/agents/issue-tracker.md)
- [Agent triage labels](docs/agents/triage-labels.md)
- [Agent domain documentation rules](docs/agents/domain.md)

Certificates and virtual hosts use native NixOS declarations. Network constructs
one specialized Caddy package; the host supplies its native ACME module and stock
Lego. Firewall and WAN use native nftables and systemd-networkd. Runtime support
is x86_64-linux only; verification uses the existing builder without VM tests.
