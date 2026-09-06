# Deferred work

These are conditional review items, not delivery commitments. Other runtime
architectures are outside the product scope.

| Issue | Why deferred | Trigger and acceptance |
| --- | --- | --- |
| Alternative DNS providers | The supported personal stack uses Timeweb DNS-01 | A concrete approved consumer need; a narrow typed contract and provider-specific verification before a release |
| Generic Caddy plugin ecosystem | Existing consumers need the pinned build and forward-proxy capability | An actual missing capability; assess a narrow pinned addition first, with collision and rendered-config checks |
| Broader framework or networking redesign | Extraction should preserve evaluated behavior using native facilities | Demonstrated limitation that cannot be addressed within the current contract; approved design and behavior comparison |
| Remove the local Timeweb API v2 patch | The pinned official package has not yet replaced the required patch | Official packaged support catches up; verify equivalent API v2 behavior, rerun lifecycle/package gates, then remove the patch in a Network release |

## Explicitly deferred by the review

- TCP tuning placement and performance comparisons belong to the VPN domain.
  Ownership migration preserves the existing consumer values until that review.
- IPv6 production enablement and HTTP/3 need a separately tested consumer/VPN
  migration; the current IPv4-only, HTTP/1.1+HTTP/2 behavior is retained.
- Moving ACME to another host/account was declined. Local root can access DNS
  credentials; owner/group/mode and certificate-reader group membership are
  checked by evaluated integration contracts. Deployed SOPS file permissions
  remain machine acceptance, not a synthetic dummy-file test.
- Physical NIC rename, deployed connectivity and live DNS-01 issuance still need
  separately authorized acceptance on the applicable machine/provider.
