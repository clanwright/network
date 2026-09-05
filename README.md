# Network

Network is the personal x86_64-linux networking stack extracted for the public
`clanwright/network` project. Six independently selectable Clan capabilities
share one dependency lock and one atomic SemVer release.

| Capability | Clan module | Role | Implementation reference |
| --- | --- | --- | --- |
| Certificates | `@clanwright/network-certificates` | `server` | [Certificates](clanServices/certificates/README.md) |
| Caddy | `@clanwright/network-caddy` | `ingress` | [Caddy](clanServices/caddy/README.md) |
| Firewall | `@clanwright/network-firewall` | `host` | [Firewall](clanServices/firewall/README.md) |
| WAN DHCP | `@clanwright/network-wan-dhcp` | `host` | [WAN DHCP](clanServices/wan-dhcp/README.md) |
| WAN static | `@clanwright/network-wan-static` | `host` | [WAN static](clanServices/wan-static/README.md) |
| TCP tuning | `@clanwright/network-tcp-tuning` | `host` | [TCP tuning](clanServices/tcp-tuning/README.md) |

The [wildcard certificate compatibility adapter](clanServices/wildcard-certificate/README.md)
is an additional claim adapter, not a seventh runtime capability.

Documentation index:

- [Architecture and scope](docs/architecture.md)
- [Ownership and consumer contracts](docs/contracts.md)
- [Local verification](docs/operations/verify.md)
- [Release and consumer adoption](docs/operations/release.md)
- [Deferred work](docs/backlog.md)
- [Contributor instructions](AGENTS.md)
