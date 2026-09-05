# Certificate claim

The certificate role declares one named DNS-01 certificate with certName, domain and extraDomainNames. It works for wildcard and ordinary SANs. The stable module ID is retained for existing consumers.

Select network-certificates on the same machine. The claim never selects Caddy or a reload target. Consumers register their own networkCore.acme.reloadServices entries. This helper does not own secret values or certificate storage.
