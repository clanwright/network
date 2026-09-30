# Caddy

Select `ingress` through `@clanwright/network-caddy`. It selects Network's single
specialized x86_64-linux Caddy with the forward-proxy and rate-limit plugins.
Consumer package replacement is rejected. Certificate issuance, transport
readiness and firewall exposure belong to their explicit owners.

Declare `services.caddy.virtualHosts.<canonicalDNSHost>` directly. Keys and native
`serverAliases` are canonical lowercase ASCII DNS hosts, at most 253 bytes total
and 63 bytes per label. URLs, ports, raw addresses, wildcard hosts, uppercase and
trailing dots are rejected. Repeated/self aliases and host/alias overlap on
shared listeners are rejected. Native `listenAddresses` is a list of canonical
IPv4 addresses; `[]` and `0.0.0.0` mean wildcard. One base may bind several
addresses; independent bases for one key are rejected even with disjoint binds.

Each base defines one required `owner`, e.g. `owner = "apps:notes";`. Native
`types.uniq` rejects a second definition even with the same value. The token
begins with an ASCII letter/digit; remaining characters may include letters,
digits, `.`, `_`, `:`, `@`, `/` and `-`. Extensions target the existing canonical
key without repeating `owner`; an absent base fails for a missing owner.

`forwardProxy` is a native `types.uniq` boolean defaulting to `false`. A selected
extension sets it to `true` once. Network derives native `hostName` as the key
normally or the catch-all `:443` for a proxy root. Divergent explicit hostnames
and proxy roots sharing overlapping listeners are rejected. Native aliases are
retained on the catch-all root. The consumer owns authentication, CONNECT routing,
token semantics and selected listener scope.

Any proxy root requires native `services.caddy.httpsPort = 443`. This keeps
unqualified aliases and cover sites on the same effective port as `:443`;
ordinary configurations without a proxy may use another HTTPS port.
An ordinary cover site retains an outer HTTP Host matcher. TLS SNI alone does
not select it for an arbitrary-target CONNECT request. Place the full
authenticated CONNECT policy on the explicit listener catch-all root; cover
sites retain their own content and certificates. Named native Host routes are
terminal and precede catch-alls. A CONNECT authority matching a named site selects
that route before the root; an inner order500 does not change this precedence.
The consumer explicitly prepends the same complete CONNECT policy at priority
500 (`lib.mkBefore`) inside every named site on that listener whose canonical
host or alias can match a target.
Keep those sites ordinary: do not repeat owner, change hostName/listeners/TLS or
set forwardProxy. The selected root already attaches its policy once. Shared
policy generation remains with the proxy owner; each attachment retains CONNECT
method and guards on both the actual selected local bind IPv4 and local port
443, including on mixed public/private listeners. Caddy's `http.request.local.port`
placeholder is numeric: CEL compares it with `443`, not `"443"`.
Destination authority ports are separate. A disjoint listener needs
its own declared root and independently scoped policy, respecting root exclusivity.

For the public VPN fragment, the consumer extension is:

```nix
services.caddy.virtualHosts."existing.named.site.invalid".extraConfig =
  lib.mkBefore config.clanwright.vpn.naiveproxy.connectRoute;
```

Native `useACMEHost` names a separately declared `security.acme.certs.<stableID>`.
Caddy registers its own native renewal target; Network grants the `acme` reader
group when a selected certificate uses it. A different certificate group needs
an explicit native reader grant.
A missing certificate reference can create a native reload-only entry, whose
missing challenge fails ACME validation. Keep host-wide challenge defaults null
through Certificates. Native `useACMEHost = null` is usable for explicit custom
TLS fixtures; automatic HTTPS remains disabled.

For execution order across native `extraConfig` extensions, use **matcherless
outer literal `route { ... }` blocks** with host/path/method guards inside. A
matched outer route can be reordered by Caddy's adapter. Use `lib.mkBefore` for
a proxy pre-route, `lib.mkAfter` for a publisher, and `lib.mkOrder 2000` for a
terminal base fallback. The static-site role already gives its fallback that
priority. Site directives such as `tls`, `log_skip` and `handle_errors` stay
outside route blocks. Nix text order alone does not change native directive sorting.
Sensitive publisher paths need a site-level `log_skip` before alias redirects;
a skip buried in the later publisher route cannot hide an earlier alias response.
The publisher owner must verify successful/failing token paths and alias responses.

```nix
services.caddy.virtualHosts."site.example.invalid" = {
  owner = "apps:site";
  listenAddresses = [ "192.0.2.1" "192.0.2.2" ];
  useACMEHost = "existing-cert-id";
  extraConfig = lib.mkOrder 2000 ''
    route {
      @site host site.example.invalid
      reverse_proxy @site 127.0.0.1:8080
    }
  '';
};
```

In a separate extension module:

```nix
services.caddy.virtualHosts."site.example.invalid".extraConfig = lib.mkAfter ''
  route {
    @publisher {
      host site.example.invalid
      path /published/*
    }
    respond @publisher "publisher response" 200
  }
'';
```

The base disables config persistence and automatic HTTPS and retains HTTP/1 and
HTTP/2. A proxy root enables the plugin's usual `forward_proxy before file_server`
order; literal routes control their own internal order. Main JSON `settings`,
raw top-level `extraConfig`, explicit `configFile`, custom adapter and resume
bypasses are rejected. Ordinary ordered `globalConfig` additions are supported;
force-removal of the Network policy fails the native option-priority check.
This guard qualifies the supported module's definitions rather than parsing
arbitrary consumer text.

Access logs default to JSON stderr/journal. Native per-site `logFormat`, including
`null`, and consumer `log_skip` remain available. The default operational logger
excludes `http.log.error`; a separate native filtered logger retains structured
status, method, host, logger, error ID and trace while removing URI, headers and
unsafe free-text errors/messages. In the supported Caddy version, `msg delete`
also removes the failing error-handler's nested message. Dropping the secondary
error string loses any diagnostics embedded in it. Native successful error chains
can log the original error at DEBUG; filtering emitted records does not promise
that every error response produces an ERROR record. Actual consumer plugin fields,
authentication/token routes and journal access still need consumer acceptance.

Declare unit dependencies and startup transport checks directly through native
`systemd.services.caddy`. Network retains native retry, reload reset and renewal.
The consumer attaches its read-only transport helper only in `ExecStartPre`;
Network adds no reload gate, watcher or transport-loss unit binding.

The [verification boundary](../../docs/operations/verify.md) owns local evidence
and the separate PREDEPLOY requirements for actual consumer behavior.
