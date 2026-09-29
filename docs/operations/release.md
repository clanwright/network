# Release and consumer adoption

Network releases six capabilities, the wildcard compatibility adapter, contracts
and locked packages together. Breaking public-contract changes require a major
version; compatible capabilities a minor version; compatible fixes a patch.
There is no hosted CI, automatic merge or automatic release.

## Prepare a candidate

1. Reconcile canonical documentation with the final code and consumer migration.
2. Run every gate in [verification](verify.md), formatting, Statix and Deadnix on
   the exact candidate source. Retain readable logs, elapsed time and artifacts.
3. Obtain independent review and resolve material correctness/security findings.
4. Inspect the candidate for unintended files and credential material without
   decrypting or printing secrets. Commit only the reviewed candidate.
5. Prepare release notes describing behavior, breaking surfaces, validation and
   required consumer changes. Keep draft notes in the ignored `.work/release/`.

## Version 4 migration

Static WAN replaces `secondaryIPv4`, `routeTableName`, `routeTableId` and
`rulePriority` with the `additionalIPv4s` list and the `routeTableBase`/
`rulePriorityBase` settings. Move each former secondary address into the list
as described in the [static WAN migration](../../clanServices/wan-static/README.md#migration-from-secondaryipv4).
The default route now names the primary address as preferred source, and
evaluation rejects a primary gateway outside the primary prefix.

## Version 2 migration

Before adopting version 2, update consumers as follows:

- Assemble `capabilities = [ "forward-proxy" ]` and `siteAddress = ":443"`
  together. A base Caddy fragment and its contributions may supply the pair
  separately; the final declaration must be complete.
- Use canonical absolute Caddy log paths with nonempty path segments containing
  only letters, digits, `.`, `_`, `+` and `-`; `.` and `..` segments are invalid.
  Keep certificate ownership in `certificateClaims` and `claimOwners`, and remove
  any writes to the internal read-only `evaluatedOwners` result.
- Supply canonical IPv4 addresses for bootstrap SSH, as for WAN and Caddy.
  Rejected markers now converge closed with a diagnostic and successful refresh;
  scripts must not use refresh failure as a test for an invalid marker. Genuine
  nftables errors still fail. Explicit stricter SSH authentication methods are
  preserved while password and keyboard-interactive authentication remain off.
- Treat static WAN `waitOnline` settings as interface-specific readiness.
  Consumers that used them to control host-wide waiting must configure their
  global `systemd.network.wait-online` policy explicitly.
- Network deduplicates final renewal notifications only for its own certificate
  claims. Other native ACME certificates retain their notification lists.

Version 1 already removed Network TCP tuning and `tailnet_only`, required
nftables and a single owner for public Caddy roots, narrowed WAN validation and
replaced the empty bootstrap marker with an expiring deadline. Consumers moving
from version 0 must also move tuning to their VPN domain, bind private admin
sites to their Tailscale address with interface enforcement, and update
bootstrap/handoff scripts. IPv4-only and HTTP/1.1+HTTP/2 behavior is retained.

## Publish an approved candidate

Publication requires separate owner approval. Run from the Network root with
an explicit, reviewed tag and notes file; this procedure never creates a GitHub
repository or overwrites a tag. Set both variables before using the commands.

```bash
set -euo pipefail
: "${release_tag:?Set the reviewed new SemVer tag}"
: "${notes_file:?Set the reviewed release notes path}"
test -f "$notes_file"
test -z "$(git status --porcelain)"
release_commit="$(git rev-parse HEAD)"
python3 - "$release_tag" <<'PY'
import re
import sys
assert re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", sys.argv[1]), "Use an exact stable SemVer tag"
PY
! git show-ref --verify --quiet "refs/tags/$release_tag"
remote_tags="$(git ls-remote git@github.com:clanwright/network.git "refs/tags/$release_tag" "refs/tags/$release_tag^{}")"
test -z "$remote_tags"
gh repo view clanwright/network --json nameWithOwner
```

The SSH `ls-remote` must succeed; an authentication/network failure is not proof
that a tag is absent. Use the existing Keychain-backed `gh` authentication and
SSH Git transport; do not rotate credentials to bypass a sandbox limitation.

```bash
git push git@github.com:clanwright/network.git "$release_commit:refs/heads/main"
git tag -a "$release_tag" "$release_commit" -m "Network $release_tag"
git push git@github.com:clanwright/network.git "refs/tags/$release_tag"
gh release create "$release_tag" --repo clanwright/network --verify-tag \
  --title "Network $release_tag" --notes-file "$notes_file"
```

Verify both remote views resolve the annotated tag to the reviewed commit:

```bash
remote_tag_commit="$(git ls-remote git@github.com:clanwright/network.git "refs/tags/$release_tag^{}" | awk '{print $1}')"
release_api_object="$(gh api "repos/clanwright/network/git/ref/tags/$release_tag" --jq '.object.sha')"
release_api_commit="$(gh api "repos/clanwright/network/git/tags/$release_api_object" --jq '.object.sha')"
test "$remote_tag_commit" = "$release_commit"
test "$release_api_commit" = "$release_commit"
gh release view "$release_tag" --repo clanwright/network \
  --json isDraft,isPrerelease,tagName,url
test -z "$(git status --porcelain)"
```

## Consumer adoption

For the nested-input portability fix, Apps must release a version whose own lock
adopts the new Network release. Consumers then update Apps and their direct
Network pin together, retaining identical Apps-owned and root Network/Primitives
sources. Changing only the root Network input leaves an older Apps dependency
graph in place. Neither manual lock imports nor consumer source overrides are
migration steps. Acceptance includes clean initial locking, normal updating of
an existing valid Apps v0.1.0 lock, module evaluation, source convergence and
byte-identical relocking on the accepted official Nix versions. Local candidate
snapshots establish compatibility, not published release adoption.

The Lego 5 package requires a consumer nixpkgs whose native NixOS ACME module
supports Lego 5 commands and v4 account migration. Update the consumer nixpkgs
before adopting this package update; updating only the Network input is not
sufficient. Network rejects generated ACME scripts without migration and
v5 run support, including unrelated native certificates because they
share the Lego package. The local renewal gate checks migration of a synthetic
v4 account layout while preserving its account URL and key identity. It does
not establish live provider acceptance.

Adoption follows publication. Pin the verified released tag, retain the resolved
revision in the consumer lock, migrate the typed settings and remove superseded
implementation. Compare evaluated behavior, build affected production closures
and run the consumer review/verification gates before accepting the migration.

A separately prepared consumer worktree may evaluate a local candidate using an
explicit `--override-input network` for development. Such evidence is a candidate
compatibility check, not released-tag provenance or completed adoption. Do not
commit a local path pin or a guessed future tag in place of a verified release.

Publication and consumer source adoption do not authorize host updates, DNS or
provider operations, live ACME, credential rotation or backup operations.
