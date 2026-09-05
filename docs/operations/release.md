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
an exact immutable release tag. There is no hosted CI or automatic merge/release
workflow; these are local owner-controlled gates.

## Publish `v0.1.0`

Run this procedure from the root of the standalone Network checkout after the
candidate checks above pass. The release text is the reviewed
`../artifacts/release-v0.1.0.md` file when Network is still located at
`.work/network-extraction/repository/` beside that artifacts directory.

Record the candidate commit and confirm the SSH transport before creating any
remote state:

```bash
release_tag=v0.1.0
release_commit="$(git rev-parse HEAD)"
notes_file=../artifacts/release-v0.1.0.md
test -f "$notes_file"
git status --short
git remote -v
ssh -T git@github.com
```

The status must be clean and the configured GitHub transport must use
`git@github.com:`. The SSH probe can exit non-zero after reporting successful
GitHub authentication because GitHub does not provide shell access.

Create the public repository, push the candidate over SSH, then create the exact
release from the prepared notes file:

```bash
if ! gh repo view clanwright/network >/dev/null 2>&1; then
  gh repo create clanwright/network --public \
    --source=. \
    --remote=origin
fi
git remote set-url origin git@github.com:clanwright/network.git
git push --set-upstream origin HEAD:main
git tag -a "$release_tag" "$release_commit" -m "Network $release_tag"
git push origin "refs/tags/$release_tag"
gh release create "$release_tag" \
  --repo clanwright/network \
  --verify-tag \
  --title "Network $release_tag" \
  --notes-file "$notes_file"
```

Verify that both GitHub views resolve the immutable tag to the exact local
candidate commit:

```bash
remote_tag_commit="$(git ls-remote git@github.com:clanwright/network.git \
  "refs/tags/$release_tag^{}" | awk '{print $1}')"
release_api_object="$(gh api \
  "repos/clanwright/network/git/ref/tags/$release_tag" \
  --jq '.object.sha')"
release_api_commit="$(gh api \
  "repos/clanwright/network/git/tags/$release_api_object" \
  --jq '.object.sha')"
test "$remote_tag_commit" = "$release_commit"
test "$release_api_commit" = "$release_commit"
gh release view "$release_tag" \
  --repo clanwright/network \
  --json isDraft,isPrerelease,tagName,url
```

For this annotated tag, `git ls-remote` uses the peeled `^{}` reference while
the GitHub API first resolves the tag object and then its commit. Both equality
checks must pass before consumer adoption. Run the local gates from the released commit as
described in [Network verification](verify.md), and preserve their readable
logs and timing artifacts.

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
