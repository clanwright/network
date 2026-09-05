# Release and consumer adoption

A release is one atomic SemVer version for all six capabilities, the compatibility
adapter, contracts and locked packages. Breaking consumer contract changes require
a major version; compatible capabilities require a minor version; compatible
fixes use a patch version. Do not publish partial capability releases.

Before creating a tag:

1. Finish the intended public interface and reconcile documentation with runtime.
2. Run every local gate in verify.md on the exact candidate source with the existing
   Linux builder. Resolve runtime failures; preserve readable logs and duration.
3. Obtain independent review and resolve material correctness/security findings.
4. Inspect the public candidate contents and provenance, including accidental local
   artifacts and secret material, without decrypting or printing secrets.

Only a passing, reviewed candidate can be published to `clanwright/network` with
an exact immutable release tag. Verify the tag's source identity and run the local
gates against that tagged source before consumer adoption. There is no hosted CI
or automatic merge/release workflow; these are local owner-controlled gates.
The first release is currently unfinished and has no claimed tag here.

Consumer adoption is a subsequent transaction: use the exact verified Network
tag, retain the resolved revision in the consumer lock, select the intended Clan
capabilities, pass core-owned settings and remove superseded implementation.
Keep public options limited to concrete needs. Add, test and release a missing
option in Network; do not add consumer package overlays or internal imports. Compare evaluated
behavior, build all affected production closures and run the consumer's local
verification/review gates before declaring the migration accepted.

Publication does not authorize deployment. Actual host updates, DNS/provider
operations, issuance against live ACME and secret rotation each retain their
separate explicit approval boundary.
