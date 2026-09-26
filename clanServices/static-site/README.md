# Static site

Select the `site` role from `@clanwright/network-static-site` and the Caddy
`ingress` role on the same machine. Each site instance creates one Caddy claim;
it does not select Caddy, issue a certificate, open a firewall port, or deploy
content. `useACMEHost` must name an existing Caddy-readable ACME certificate.
Certificate coverage for the canonical host and every alias belongs to the
consumer.

Required settings are `claimName`, `hostName`, `artifact`, `useACMEHost`, and
`listenAddresses`.
`claimName` is a stable safe identifier for the Caddy claim and
`/var/log/caddy/<claimName>.log`; it need not match the site's branding.
`hostName` and each `serverAliases` entry must be a DNS host name. Aliases
redirect GET and HEAD requests without `Proxy-Authorization` to the canonical
HTTPS host, retaining path and query. `serverAliases` defaults to `[]`.

`artifact` is an immutable store-path string whose Nix context retains the
build dependency (for example, `artifact = "${sitePackage}";`). A bare
path string or mutable filesystem path is rejected. The site role validates and copies its directory
before activation. It requires a nonempty readable regular `index.html` and
accepts an optional nonempty readable regular `404.html`. When absent, the role
provides a plain `404.html` fallback. Links and unsupported entries are rejected. Missing
paths retain HTTP 404. No build tooling or runtime fetch is provided.

For example, a consumer can pass the output of its existing build through Clan
without losing the Nix dependency:

```nix
let
  websiteArtifact = website.lib.buildSite {
    system = "x86_64-linux";
    siteUrl = "https://www.example.invalid";
  };
  camouflageArtifact = website.lib.buildSite {
    system = "x86_64-linux";
    siteUrl = "https://secondary.example.invalid";
  };
in
{
  inventory.instances = {
    ingress = {
      module = { input = "network"; name = "@clanwright/network-caddy"; };
      roles.ingress.machines.edge.settings = { };
    };
    website = {
      module = { input = "network"; name = "@clanwright/network-static-site"; };
      roles.site.machines.edge.settings = {
        claimName = "website";
        hostName = "www.example.invalid";
        serverAliases = [ "example.invalid" ];
        artifact = "${websiteArtifact}";
        useACMEHost = "example.invalid";
        listenAddresses = [ ];
        publicSite = true;
      };
    };
    camouflage = {
      module = { input = "network"; name = "@clanwright/network-static-site"; };
      roles.site.machines.edge.settings = {
        claimName = "camouflage";
        hostName = "secondary.example.invalid";
        artifact = "${camouflageArtifact}";
        useACMEHost = "example.invalid";
        listenAddresses = [ ];
        publicSite = false;
      };
    };
  };
}
```

The example assumes a separately declared certificate covering all listed
hosts. The two instances may also share one artifact when the content should
be identical. A proxy consumer selects the stable `website` claim through its
`selectedPublicSiteClaim` setting. To migrate an existing consumer recipe,
retain the claim name, replace its raw Caddy site declaration with this role,
and remove the old declaration. Consumers adopt the role from a released
Network version; a local checkout is not a release.

`listenAddresses` is required and uses Network's canonical IPv4 type. An
explicit `[]` means a wildcard listener. `publicSite` defaults to `false`; set it to
`true` only for a public claim intended as a proxy contribution root. The role
then derives the owner token `static-site:<instanceName>`. A private site
requires an appropriate concrete listener and consumer firewall policy.

For a second camouflage host, select a second `site` instance with a distinct
claim name, its own host and certificate settings, the same artifact, and
`publicSite = false`. A NaiveProxy consumer attaches through the existing Caddy
contribution contract to the selected public claim. Static file serving is
host-matched and follows forward proxy directive ordering.
