# Network

Network is the personal x86_64-linux networking stack extracted for the public
`clanwright/network` project. Five independently selectable Clan capabilities
share one dependency lock and one atomic SemVer release.

| Capability | Clan module | Role | Implementation reference |
| --- | --- | --- | --- |
| Certificates | `@clanwright/network-certificates` | `server` | [Certificates](clanServices/certificates/README.md) |
| Caddy | `@clanwright/network-caddy` | `ingress` | [Caddy](clanServices/caddy/README.md) |
| Firewall | `@clanwright/network-firewall` | `host` | [Firewall](clanServices/firewall/README.md) |
| WAN DHCP | `@clanwright/network-wan-dhcp` | `host` | [WAN DHCP](clanServices/wan-dhcp/README.md) |
| WAN static | `@clanwright/network-wan-static` | `host` | [WAN static](clanServices/wan-static/README.md) |

WAN ownership is physical as well as logical: interface names and normalized MAC
addresses must be unique across WAN selections, and a host may select at most one
static WAN instance. That instance can configure two IPv4 addresses on its NIC.

The [wildcard certificate compatibility adapter](clanServices/wildcard-certificate/README.md)
is an additional claim adapter, not a sixth runtime capability.

Documentation index:

- [Architecture and scope](docs/architecture.md)
- [Ownership and consumer contracts](docs/contracts.md)
- [Local verification](docs/operations/verify.md)
- [Release and consumer adoption](docs/operations/release.md)
- [Deferred work](docs/backlog.md)
- [Contributor instructions](AGENTS.md)
- [Agent issue tracker](docs/agents/issue-tracker.md)
- [Agent triage labels](docs/agents/triage-labels.md)
- [Agent domain documentation rules](docs/agents/domain.md)

TCP performance policy is owned by the consumer VPN domain. The breaking
Network candidate removes the former TCP-tuning role; coordinate its migration
with consumers before adopting a new release.
