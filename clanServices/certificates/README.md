# Certificates

Select the server role with an ACME contact email. Timeweb DNS-01 and the exact Network-owned Lego build are the supported stack. secretName selects a named SOPS interface; encrypted values and recipients remain consumer-owned. The service declares acme ownership, group and mode 0440 and passes only the resolved runtime path to Lego.

Consumers declare networkCore.acme.certificateClaims, ownership records and reloadServices. There is no implicit Caddy dependency. Certificates and private keys remain local under native NixOS ACME storage. Renewal preserves the current IPv4-only ACME process hardening, retry timing and DNS propagation checks; it does not toggle global host IPv6.

See [verification](../../docs/operations/verify.md) for local gates and the separate live provider boundary.
