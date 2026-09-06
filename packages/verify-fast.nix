{ pkgs }:
pkgs.writeShellApplication {
  name = "verify-fast";
  runtimeInputs = with pkgs; [
    coreutils
    gitMinimal
    nix
    nixfmt
    statix
    deadnix
  ];
  text = ''
    case "$#:$*" in
      0:) ;;
      1:-h|1:--help)
        echo 'Usage: verify-fast (from the Network checkout)'
        echo 'Native static checks and Linux configuration contracts; no runtime acceptance.'
        exit 0 ;;
      *) echo 'Usage: verify-fast' >&2; exit 2 ;;
    esac
    cd "$(git rev-parse --show-toplevel)"
    mkdir -p .work/verification
    artifacts="$(mktemp -d "$PWD/.work/verification/fast-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    echo "Artifacts: $artifacts"
    start="$(date +%s%3N)"
    printf 'stage\telapsed_ms\texit\n' > "$artifacts/timings.tsv"
    # shellcheck disable=SC2329 # Invoked by EXIT.
    finish() {
      status="$?"
      elapsed="$(( $(date +%s%3N) - start ))"
      printf 'total\t%s\t%s\n' "$elapsed" "$status" >> "$artifacts/timings.tsv"
      echo "verify-fast: ''${elapsed}ms, exit=$status; artifacts: $artifacts"
    }
    trap finish EXIT
    run() {
      local name="$1" stage_start status
      shift
      stage_start="$(date +%s%3N)"
      echo "== $name =="
      if "$@" > "$artifacts/$name.log" 2>&1; then status=0; else status="$?"; fi
      printf '%s\t%s\t%s\n' "$name" "$(( $(date +%s%3N) - stage_start ))" "$status" >> "$artifacts/timings.tsv"
      if [ "$status" -ne 0 ]; then
        cat "$artifacts/$name.log" >&2
        return "$status"
      fi
    }
    nix_files=()
    while IFS= read -r -d "" file; do
      if [ -f "$file" ]; then nix_files+=("$file"); fi
    done < <(git ls-files -z --cached --others --exclude-standard -- '*.nix')
    run diff git diff --check HEAD
    run format nixfmt --check "''${nix_files[@]}"
    run statix statix check . --ignore .work
    run deadnix deadnix --fail "''${nix_files[@]}"
    run contracts nix eval --offline --json --no-write-lock-file \
      --option allow-import-from-derivation false --option builders "" \
      .#lib.checkContracts
    echo 'Static checks and evaluated contracts passed. Linux runtime checks are separate.'
  '';
}
