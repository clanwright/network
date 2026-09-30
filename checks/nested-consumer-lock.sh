#!/usr/bin/env bash
# Fresh/update/relock proof using ordinary independent Git flakes and native Nix.
# Stage elapsed_seconds use Bash's whole-second clock; /usr/bin/time may wrap
# the entire gate when subsecond measurements are needed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
source=$root
nix_bin=${NIX_BIN:-nix}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source|--nix)
      [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
      case "$1" in --source) source=$2 ;; --nix) nix_bin=$2 ;; esac
      shift 2 ;;
    *) echo "Usage: $0 [--source DIRECTORY] [--nix PATH]" >&2; exit 2 ;;
  esac
done
source=$(cd "$source" && pwd -P)
git -C "$source" rev-parse --show-toplevel >/dev/null
[ -f "$source/flake.nix" ] && [ -f "$source/flake.lock" ]
mkdir -p "$root/.work/verification/nested-lock-unique"
run=$(mktemp -d "$root/.work/verification/nested-lock-unique/run.XXXXXXXX")
echo "evidence=$run"
export XDG_CACHE_HOME="$run/cache"
nix=("$nix_bin" --extra-experimental-features 'nix-command flakes')
# Git identity and commits apply only to the disposable repositories.
git_identity=(-c user.name='Nested lock check' -c user.email=check@example.invalid -c commit.gpgsign=false)
stage() {
  local name=$1 started=$SECONDS status=0
  shift
  "$@" >"$run/$name.log" 2>&1 || status=$?
  printf '\nexit=%s elapsed_seconds=%s\n' "$status" "$((SECONDS - started))" >>"$run/$name.log"
  echo "$name exit=$status elapsed_seconds=$((SECONDS - started))"
  [ "$status" -eq 0 ] || { echo "See $run/$name.log" >&2; exit "$status"; }
}
commit() {
  local directory=$1 name=$2
  stage "$name-add" git -C "$directory" add -A
  stage "$name" git -C "$directory" "${git_identity[@]}" commit -m "$name"
}
# --cached includes current contents of staged/unstaged files; --others includes
# nonignored untracked files. Filter deleted files before rsync (also on macOS).
list_files() { git -C "$source" ls-files --cached --others --exclude-standard -z >"$run/source-files.nul"; }
stage candidate-files list_files
while IFS= read -r -d '' file; do
  case "$file" in .git/*|.work/*) continue ;; esac
  if [ -f "$source/$file" ] || [ -L "$source/$file" ]; then printf '%s\0' "$file"; fi
done <"$run/source-files.nul" >"$run/candidate-files.nul"
candidate=$run/network
wrapper=$run/wrapper
consumer=$run/consumer
mkdir "$candidate" "$wrapper" "$consumer"
stage candidate-copy rsync -a --from0 --files-from="$run/candidate-files.nul" "$source/" "$candidate/"
stage candidate-init git -C "$candidate" init -q
commit "$candidate" candidate-commit
revision=$(git -C "$candidate" rev-parse HEAD)
# Nix renders URL strings, including escaping paths, rather than shell JSON logic.
nix_string() { "${nix[@]}" eval --offline --impure --expr 'builtins.toJSON (builtins.getEnv "LOCK_URL")' --raw; }
write_wrapper() {
  local network_url
  LOCK_URL="git+file://$candidate?rev=$revision"; export LOCK_URL
  network_url=$(nix_string)
  printf '{ inputs.network.url = %s; outputs = { network, ... }: { public = { revision = network.rev; narHash = network.narHash; source = toString network.outPath; catalog = builtins.attrNames network.clan.modules; dataMesher = builtins.isFunction network.nixosModules.data-mesher; }; }; }\n' "$network_url" >"$wrapper/flake.nix"
}
write_consumer() {
  local network_url wrapper_url
  LOCK_URL="git+file://$candidate?rev=$revision"; export LOCK_URL
  network_url=$(nix_string)
  LOCK_URL="git+file://$wrapper?rev=$wrapper_revision"; export LOCK_URL
  wrapper_url=$(nix_string)
  cat >"$consumer/flake.nix" <<FLAKE
{
  inputs.network.url = $network_url;
  inputs.wrapper.url = $wrapper_url;
  outputs = { network, wrapper, ... }:
    let
      direct = {
        revision = network.rev;
        narHash = network.narHash;
        source = toString network.outPath;
        catalog = builtins.attrNames network.clan.modules;
        dataMesher = builtins.isFunction network.nixosModules.data-mesher;
      };
      selected = import (network.outPath + "/checks/consumer.nix") {
        self = network; inputs = network.inputs; root = network.outPath;
      } {
        instances.firewall = {
          module = { input = "network"; name = "@clanwright/network-firewall"; };
          roles.host.machines.network-node.settings = { };
        };
      };
      expected = [
        "@clanwright/network-caddy" "@clanwright/network-certificates"
        "@clanwright/network-firewall" "@clanwright/network-static-site"
        "@clanwright/network-wan-dhcp" "@clanwright/network-wan-static"
      ];
    in {
      public =
        assert direct == wrapper.public;
        assert direct.catalog == expected && direct.dataMesher;
        assert selected.valid && selected.evaluated && selected.machine.networking.firewall.enable;
        { inherit direct; selectedCapability = "@clanwright/network-firewall"; valid = true; };
    };
}
FLAKE
}
validate_graph() {
  NESTED_CANDIDATE_LOCK="$candidate/flake.lock" NESTED_CONSUMER_LOCK="$consumer/flake.lock" \
    NESTED_CANDIDATE_REVISION="$revision" NESTED_WRAPPER_REVISION="$wrapper_revision" \
    "${nix[@]}" eval --offline --impure --json --file "$root/checks/nested-consumer-lock.nix" --apply '
      check: check {
        candidateLock = builtins.getEnv "NESTED_CANDIDATE_LOCK";
        consumerLock = builtins.getEnv "NESTED_CONSUMER_LOCK";
        candidateRevision = builtins.getEnv "NESTED_CANDIDATE_REVISION";
        wrapperRevision = builtins.getEnv "NESTED_WRAPPER_REVISION";
      }'
}
evaluate_public() {
  "${nix[@]}" eval --offline --json --no-update-lock-file --option allow-import-from-derivation false \
    --option builders '' "path:$consumer#public" >"$run/$1.json"
}
repeat_lock() {
  local name=$1
  cp "$consumer/flake.lock" "$run/$name-before.lock"
  stage "$name" "${nix[@]}" flake lock "path:$consumer"
  stage "$name-identical" cmp "$run/$name-before.lock" "$consumer/flake.lock"
}
stage nix-version "$nix_bin" --version
write_wrapper
stage wrapper-init git -C "$wrapper" init -q
commit "$wrapper" wrapper-source-commit
stage wrapper-lock "${nix[@]}" flake lock "path:$wrapper"
commit "$wrapper" wrapper-lock-commit
wrapper_revision=$(git -C "$wrapper" rev-parse HEAD)
write_consumer
stage fresh-consumer-lock "${nix[@]}" flake lock "path:$consumer"
stage fresh-graph validate_graph
stage fresh-public-eval evaluate_public fresh-public-eval
repeat_lock fresh-repeat-lock
# Update an existing valid consumer lock after both independent sources change.
printf 'second candidate revision\n' >"$candidate/nested-lock-revision.txt"
commit "$candidate" candidate-update-commit
revision=$(git -C "$candidate" rev-parse HEAD)
write_wrapper
stage wrapper-update-lock "${nix[@]}" flake update network --flake "path:$wrapper"
commit "$wrapper" wrapper-update-commit
wrapper_revision=$(git -C "$wrapper" rev-parse HEAD)
write_consumer
stage consumer-update-lock "${nix[@]}" flake update network wrapper --flake "path:$consumer"
stage updated-graph validate_graph
repeat_lock updated-repeat-lock
echo 'fresh lock, native consumer, exact graph, update and repeated locks passed'
