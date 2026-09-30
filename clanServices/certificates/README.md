# Certificates

Select `@clanwright/network-certificates`, role `server`, with an ACME contact
`email`. `secretName` defaults to `timeweb-dns-api-token`; `dnsResolver` defaults
to `1.1.1.1:53`. Email and resolver are shared native ACME defaults. Each
certificate explicitly chooses its challenge; host-wide `dnsProvider`, `webroot`
and `listenHTTP` defaults must stay null. Native `s3Bucket` is a certificate-only
setting and defaults to null. An implicit certificate created by a misspelled
Caddy reference or a reload-only declaration consequently fails native challenge
validation.

Consumers declare native `security.acme.certs.<explicitStableID>` directly:

```nix
security.acme.certs."wildcard-example" = {
  domain = "example.invalid";
  extraDomainNames = [ "*.example.invalid" ];
  dnsProvider = "timewebcloud";
  reloadServices = [ "reader.service" ];
};
```

Retain existing physical certificate IDs explicitly. A wildcard needs a
star-free ID. Native units and `/var/lib/acme/<id>` follow the ID; `directory` is
read-only. Renaming an ID changes storage and unit identity. This service does
not copy, rename, migrate or adopt certificate state. Domain/SAN/challenge changes
under the same ID can still change issuance. Equal native scalar definitions
coalesce, conflicting scalars fail, and SAN and notification lists compose.
Different IDs for the same domain require deliberate purpose/account intent.

Only certificates selecting `dnsProvider = "timewebcloud"` receive
`credentialFiles.TIMEWEBCLOUD_AUTH_TOKEN_FILE` pointing to the resolved SOPS path.
The named secret is prepared only when at least one Timeweb certificate exists.
Encrypted values and recipients remain consumer-owned. The secret belongs
to `acme:acme` with mode `0400`. Certificate readers do not gain credential
access. Other native providers retain their own credentials and unit policy.
Timeweb renewal units retain IPv4-only address-family/IP filtering, without
changing host IPv6. The host's native ACME module and stock `pkgs.lego` own
issuance, renewal, failure statuses, retries, timeouts and account handling;
Network adds no Lego overlay or generated-script compatibility gate.

Native Caddy `useACMEHost` registers `caddy.service` automatically. Other readers
append exact native `reloadServices` targets and declare certificate group
access or systemd `LoadCredential`. Dynamic direct-file readers also need the
certificate group in `SupplementaryGroups`. Native notifications use
`try-reload-or-restart`: readers of copied credentials need a genuine restart
path because a reload alone may retain the old copy. Lists are not deduplicated
by Network. Native module/package compatibility and real reader behavior remain
separate consumer acceptance gates.

See [verification](../../docs/operations/verify.md) for local gates and the separate live provider boundary.
