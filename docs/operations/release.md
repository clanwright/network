# Release and consumer adoption

Network releases five capabilities, the wildcard compatibility adapter, contracts
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

The current breaking candidate removes Network TCP tuning and `tailnet_only`,
requires nftables, requires a single owner for public Caddy roots, narrows WAN
validation and replaces the empty bootstrap marker with an expiring deadline.
Consumers move tuning to their VPN domain, bind private admin sites to their
Tailscale address with interface enforcement, and update bootstrap/handoff
scripts. Existing IPv4-only and HTTP/1.1+HTTP/2 behavior is retained.

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
