# Certificates

Select the server role with an ACME contact email. Timeweb DNS-01 and the exact Network-owned Lego build are the supported stack. secretName selects a named SOPS interface; encrypted values and recipients remain consumer-owned. The service makes the token owner-readable only by `acme` (`0400`) and passes only its resolved runtime path to Lego. Certificate files separately remain group-readable by the certificate's ACME group, so a server such as Caddy can read certificates without gaining access to the provider token.

Consumers declare networkCore.acme.certificateClaims, ownership records and reloadServices. Native NixOS consumers register their own renewal actions: a Caddy virtual host using `useACMEHost` automatically adds `caddy.service`. Other consumers explicitly contribute `networkCore.acme.reloadServices.<certificate>`. The final merged list is deduplicated for Network-owned claims, including when Caddy is also declared explicitly; unrelated native ACME certificates retain their native reload list unchanged. Certificates and private keys remain local under native NixOS ACME storage. Renewal preserves the current IPv4-only ACME process hardening, retry timing and DNS propagation checks; it does not toggle global host IPv6.

See [verification](../../docs/operations/verify.md) for local gates and the separate live provider boundary.
