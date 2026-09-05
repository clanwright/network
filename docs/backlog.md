# Deferred work

These are conditional review items, not delivery commitments. Other runtime
architectures are outside the product scope.

| Issue | Why deferred | Trigger and acceptance |
| --- | --- | --- |
| Alternative DNS providers | The supported personal stack uses Timeweb DNS-01 | A concrete approved consumer need; a narrow typed contract and provider-specific verification before a release |
| Generic Caddy plugin ecosystem | Existing consumers need the pinned build and forward-proxy capability | An actual missing capability; assess a narrow pinned addition first, with collision and rendered-config checks |
| Broader framework or networking redesign | Extraction should preserve evaluated behavior using native facilities | Demonstrated limitation that cannot be addressed within the current contract; approved design and behavior comparison |
| Remove the local Timeweb API v2 patch | The pinned official package has not yet replaced the required patch | Official packaged support catches up; verify equivalent API v2 behavior, rerun lifecycle/package gates, then remove the patch in a Network release |
