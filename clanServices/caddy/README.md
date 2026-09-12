# Caddy

Select the `ingress` role through Clan. The role uses this package's pinned
x86_64-linux Caddy build. Forward proxy directive ordering is enabled exactly when
a consumer declares the `forward-proxy` capability.
Certificates must already exist in `security.acme.certs`; consumers register
renewal reloads with Certificates. No certificate or firewall policy is implied.

Consumers declare `networkCore.caddy.fragments.<name>` with `hostName`, optional
`serverAliases`, IPv4 `listenAddresses`, `useACMEHost`, and `logFile`. An empty
list and `0.0.0.0` are wildcard listeners. Private sites must instead use
concrete IPv4 listeners; the consumer owns its tailnet address and firewall
enforcement; Network does not infer privacy from `publicSite = false`. Caddy
rejects normalized host overlaps on shared listeners. Routes render in order:
`preRouteConfigFragments`, `extraConfig`, `extraConfigFragments`. Consumers own
all route text, static roots, and runtime fragment generation.

`logFile` is an absolute path whose segments may contain ASCII letters, digits,
dot, underscore, plus, and hyphen. Empty and dot segments, whitespace, control
characters, Caddy placeholders, and systemd-tmpfiles specifiers are rejected so
the same value is safe in both generated syntaxes. Paths outside Caddy's native
`/var/log/caddy` directory are supported; the consumer must arrange for their
parent directory and service write access.

A public site sets `publicSite = true` and exactly one nonempty `siteOwners`
token. Claims without `publicSite` cannot declare a site owner. A forward-proxy consumer adds `capabilities = [
"forward-proxy" ]` to its selected public site and explicitly sets `siteAddress =
":443"`. The capability is exclusive on overlapping listeners and enables
forward proxy ordering. Caddy does not generate CONNECT routing or authentication
policy. Consumers supply imports and cross-site CONNECT route fragments.

The base retains HTTP/1 and HTTP/2, disabled automatic HTTPS, and JSON access
logs. It does not provide a shared source-IP tailnet authorization policy.
Consumers declare `afterUnits`, `wantsUnits`, and `requiresUnits` on claims;
Caddy unions these dependencies without implicitly requiring Tailscale. The Clan
role asserts that the effective Caddy package matches its release pin. The
implementation modules are internal; the public integration surface is the Clan
role.

Cross-site consumers read the site-owned `fragments` and declare `contributions`
keyed by an existing claim name. Contributions permit only
`preRouteConfigFragments`, `capabilities`, `siteAddress`, `afterUnits`, `wantsUnits`, and
`requiresUnits`. Lists append to the site's declarations; a non-null contributed
site address selects the listener-wide site. Unknown targets are rejected.
`effectiveFragments` is read-only and validates the assembled claims before
rendering, including duplicate capabilities, listener conflicts, and the
required complete `forward-proxy` plus `siteAddress = ":443"` pair. A base claim
may carry either half when a contribution supplies the other, but incomplete
assembled claims are rejected. This split
allows cross-site route generation without reading and writing the same claims.
