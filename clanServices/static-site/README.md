# Static site

Select `site` from `@clanwright/network-static-site` and Caddy `ingress` on the same
machine. Each instance owns a native virtual host keyed by canonical `hostName`,
with the unique owner `static-site:<instanceName>`. It does not select Caddy,
issue certificates, open ports or deploy content.

Required settings: `hostName`, `artifact`, `useACMEHost`, `listenAddresses`.
Optional `serverAliases` defaults to `[]`. Hosts use the shared canonical lowercase
ASCII DNS type. Caddy rejects alias/self collisions and host overlaps on shared
listeners. Listeners are an explicit list of canonical IPv4 addresses; `[]` means
wildcard. Multiple addresses are supported. Private sites require a concrete
address and consumer firewall policy.

`artifact` is an immutable store-path string retaining Nix build context, e.g.
`artifact = "${websiteArtifact}";`. Mutable paths and bare context-free store
strings are rejected. Network validates/copies the directory before activation.
A nonempty readable regular `index.html` is required. Optional `404.html` must
also be nonempty/readable; otherwise a plain fallback is supplied. Links,
unsupported entries and unreadable contents fail the build. Missing paths retain
HTTP 404. No SPA fallback, website build tool or runtime fetch is provided.

Aliases redirect GET/HEAD without `Proxy-Authorization` to canonical HTTPS,
preserving path/query. File serving and error handling remain host-guarded,
including when a proxy extension turns the native address into `:443`. Unknown
hosts do not receive the artifact. The consumer separately declares a certificate
covering all canonical/alias hosts. `useACMEHost` preserves the explicit physical
certificate ID; no certificate state is renamed or migrated.

```nix
inventory.instances = {
  ingress = {
    module = { input = "network"; name = "@clanwright/network-caddy"; };
    roles.ingress.machines.edge.settings = { };
  };
  website = {
    module = { input = "network"; name = "@clanwright/network-static-site"; };
    roles.site.machines.edge.settings = {
      hostName = "www.example.invalid";
      serverAliases = [ "example.invalid" ];
      artifact = "${websiteArtifact}";
      useACMEHost = "existing-cert-id";
      listenAddresses = [ "192.0.2.1" "192.0.2.2" ];
    };
  };
};
```

Extensions target `services.caddy.virtualHosts."www.example.invalid"` directly
without repeating `owner`. A proxy sets `forwardProxy = true` once and contributes
native `extraConfig = lib.mkBefore ''route { ... }'';`. A publisher uses
`lib.mkAfter` with its own matcherless outer route. Put host/path/method guards
inside the literal blocks. Static serving is a terminal fallback at
`lib.mkOrder 2000`, after the publisher despite its `mkAfter`. The
[Caddy reference](../caddy/README.md) defines this native order and log policy.
The alias redirect has normal priority 1000, before the publisher; browser alias
GET/HEAD still redirect even for a publisher path. Proxy authentication and
CONNECT remain ahead of that redirect.

A second cover host is a separate instance with its own canonical host,
certificate/listeners and an immutable artifact, optionally shared.
