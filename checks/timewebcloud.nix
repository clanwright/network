{ pkgs }:
let
  inherit (pkgs) lego;
in
# buildGoModule uses the normal stdenv; keep its C compiler for stock CGO.
pkgs.runCommandCC "network-stock-lego-${lego.version}-timewebcloud-contract"
  {
    # Reuse the stock package's source, vendor closure and exact Go toolchain.
    # This derivation adds tests only, and never builds a replacement runtime.
    nativeBuildInputs = lego.nativeBuildInputs ++ [
      pkgs.util-linux
      pkgs.iproute2
    ];
    env = {
      # mkDerivation flattens buildGoModule's env into these package attrs.
      inherit (lego)
        GOOS
        GOARCH
        GO111MODULE
        GOTOOLCHAIN
        CGO_ENABLED
        ;
      GOFLAGS = "-mod=vendor";
      GOPROXY = "off";
      GOSUMDB = "off";
    };
  }
  ''
    set -euo pipefail
    mkdir -p "$out"
    cp -r ${lego.src} source
    chmod -R u+w source
    cd source
    cp -r ${lego.goModules} vendor
    cp ${./timewebcloud_test.go} providers/dns/timewebcloud/network_contract_test.go
    export GOCACHE="$TMPDIR/go-cache" GOPATH="$TMPDIR/go"
    mkdir -p "$GOCACHE" "$GOPATH"
    {
      printf 'stock-package-version=%s\nsource=%s\nvendor=%s\n' \
        '${lego.version}' '${lego.src}' '${lego.goModules}'
      go version
      go env GOOS GOARCH GOVERSION GOTOOLCHAIN GOFLAGS GOPROXY GOSUMDB CGO_ENABLED
      sha256sum go.mod go.sum vendor/modules.txt providers/dns/timewebcloud/network_contract_test.go
    } > "$out/identity.txt"
    started=$(date +%s%N)
    timeout -k 2s 120s unshare --user --map-root-user --net \
      bash ${./timewebcloud.sh} 2>&1 | tee "$out/tests.log"
    finished=$(date +%s%N)
    printf 'elapsed_ms=%s\n' "$(((finished - started) / 1000000))" > "$out/timing.txt"
    grep -F -- '--- PASS: TestNetworkTimewebV2Contract' "$out/tests.log"
    grep -F -- '--- PASS: TestClient_CreateRecord_error' "$out/tests.log"
    grep -F -- '--- PASS: TestClient_DeleteRecord_error' "$out/tests.log"
    touch "$out/passed"
  ''
