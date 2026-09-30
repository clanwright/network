# Release and consumer adoption

Network releases its six capabilities, native extensions and specialized Caddy
build together. Breaking public contracts require a major version. There is no
hosted CI, automatic merge or release. Local candidates and PREDEPLOY evidence
are distinct from publication and source adoption.

## Prepare a candidate

1. Reconcile canonical documentation and the exact consumer declaration changes.
2. Run the measured gates in [verification](verify.md) on the exact source.
   Retain readable evidence and distinguish process proof from deferred behavior.
3. Obtain independent review and resolve material source findings.
4. Inspect candidate files without decrypting or printing secrets. Prepare a
   reviewed commit only within the authorized delivery scope.
5. Write concise release notes describing supported capabilities, contracts and
   rationale, with a link to the verification boundary. Temporary notes belong
   in ignored `.work/release/`.

## Versioning and consumer contracts

Use certificates, Caddy extensions, static sites, private ingress and WAN through the
[consumer contracts](../contracts.md) and the adjacent service READMEs linked
from the [documentation index](../../README.md). Preserve certificate IDs,
listener/proxy scope, reader access, bootstrap deadlines and stable route IDs.
No compatibility adapter or automatic state move is provided.

## Publish an approved candidate

Publish within the owner-authorized delivery scope; do not request approval
again for an already-authorized commit/push/release. From a clean reviewed
checkout, set an exact stable SemVer tag and reviewed notes file:

```bash
set -euo pipefail
: "${release_tag:?Set the reviewed new SemVer tag}"
: "${notes_file:?Set the reviewed release notes path}"
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
test -f "$notes_file"
test -z "$(git status --porcelain)"
release_commit="$(git rev-parse HEAD)"
! git show-ref --verify --quiet "refs/tags/$release_tag"
remote_tags="$(git ls-remote git@github.com:clanwright/network.git "refs/tags/$release_tag" "refs/tags/$release_tag^{}")"
test -z "$remote_tags"
gh repo view clanwright/network --json nameWithOwner
```

SSH must succeed; failure is not proof of an absent tag. Use existing
Keychain-backed GitHub authentication and SSH transport. Do not change credentials
as a sandbox workaround. Sandboxed Keychain access failure is not token expiry;
request normal outside-sandbox execution if needed. Preserve existing Git signing
configuration; verify signatures when signing is enabled. No new signing or PR
policy is introduced here. The following commands publish the reviewed commit and tag:

```bash
git push git@github.com:clanwright/network.git "$release_commit:refs/heads/main"
git tag -a "$release_tag" "$release_commit" -m "Network $release_tag"
git push git@github.com:clanwright/network.git "refs/tags/$release_tag"
gh release create "$release_tag" --repo clanwright/network --verify-tag \
  --title "Network $release_tag" --notes-file "$notes_file"
```

Verify remote main, the annotated tag and release resolve to the reviewed commit,
and the checkout remains clean:

```bash
remote_main_commit="$(git ls-remote git@github.com:clanwright/network.git refs/heads/main | awk '{print $1}')"
test "$remote_main_commit" = "$release_commit"
remote_tag_commit="$(git ls-remote git@github.com:clanwright/network.git "refs/tags/$release_tag^{}" | awk '{print $1}')"
release_api_object="$(gh api "repos/clanwright/network/git/ref/tags/$release_tag" --jq '.object.sha')"
release_api_commit="$(gh api "repos/clanwright/network/git/tags/$release_api_object" --jq '.object.sha')"
test "$remote_tag_commit" = "$release_commit"
test "$release_api_commit" = "$release_commit"
gh release view "$release_tag" --repo clanwright/network \
  --json isDraft,isPrerelease,tagName,url
test -z "$(git status --porcelain)"
```

## Published-input provenance and consumer adoption

After publication, perform a fresh native public lock/import using the actual
verified tag, without a candidate path or input override. Run on both the
installed Nix and the official stable Nix accepted by the consumer; retain
versions, resolved revision/NAR identities, lock files, output and timings in
ignored `.work/`. For example, from the Network checkout:

```bash
set -euo pipefail
: "${release_tag:?Set the verified published SemVer tag}"
: "${nix_bin:?Set installed or accepted official Nix executable}"
mkdir -p .work/verification
published_check="$(mktemp -d "$PWD/.work/verification/published-input.XXXXXXXX")"
cat > "$published_check/flake.nix" <<EOF
{
  inputs.network.url = "github:clanwright/network/$release_tag";
  outputs = { network, ... }: let
    selected = import (network.outPath + "/checks/consumer.nix") {
      self = network; inputs = network.inputs; root = network.outPath;
    } {
      instances.firewall = {
        module = { input = "network"; name = "@clanwright/network-firewall"; };
        roles.host.machines.network-node.settings = { };
      };
    };
  in { public = assert selected.valid && selected.evaluated
    && selected.machine.networking.firewall.enable; {
    revision = network.rev; narHash = network.narHash;
    catalog = builtins.attrNames network.clan.modules;
    firewall = selected.machine.networking.firewall.enable;
  }; };
}
EOF
{ time {
  "$nix_bin" --version
  "$nix_bin" flake lock "path:$published_check"
  "$nix_bin" eval --json --no-update-lock-file \
    --option allow-import-from-derivation false --option builders "" \
    "path:$published_check#public"
  cp "$published_check/flake.lock" "$published_check/first.lock"
  "$nix_bin" flake lock "path:$published_check"
  cmp "$published_check/first.lock" "$published_check/flake.lock"
}; } > "$published_check/result.log" 2>&1
cat "$published_check/result.log"
```

The reported revision must equal the verified release commit. This fresh public
import and unchanged relock supplement the mandatory local candidate
fresh/update/relock gates; neither substitutes for the actual consumer's gates.
An intermediate consumer owns its nested Network pin: a root-only update does
not migrate that graph. Use ordinary Nix updates for each owner-controlled pin,
retain resolved sources, prove convergence on accepted Nix versions and run the
consumer composition/build checks. Do not reconstruct locks or commit local path
pins or guessed future tags.

Ephemeral composition against an immutable local candidate proves that source
seam, not released provenance or persistent input/state adoption. Qualify the
host-native ACME/Lego pair and existing account state separately. Complete the
[PREDEPLOY matrix](verify.md#predeploy-acceptance) before relying on deployed
behavior. Publication/input adoption do not authorize host updates, live ACME,
DNS/provider, secret or backup operations.
