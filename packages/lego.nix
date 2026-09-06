{ pkgs }:
let
  apiV2 = pkgs.fetchpatch {
    url = "https://github.com/go-acme/lego/commit/012a2c1e019005d07b8c9eff7f7996eb44d848f6.patch";
    hash = "sha256-dWqrvEDj5hTM2vsS3gAk0Uo3Y++i0+MIx8gRzSI6YcA=";
    includes = [
      "providers/dns/timewebcloud/internal/client.go"
      "providers/dns/timewebcloud/internal/types.go"
    ];
  };
in
pkgs.lego.overrideAttrs (previous: {
  patches = (previous.patches or [ ]) ++ [
    apiV2
    ./lego-timewebcloud-api-v2-v4.patch
  ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export GOFLAGS="''${GOFLAGS//-trimpath/}"
    go test -v ./providers/dns/timewebcloud -run '^TestNetworkTimewebV2Contract$' -count=1
    runHook postCheck
  '';
  postPatch = (previous.postPatch or "") + ''
    grep -F 'JoinPath("v2", "domains"' providers/dns/timewebcloud/internal/client.go
  '';
  postInstall = (previous.postInstall or "") + ''
    "$out/bin/lego" --accept-tos --help >/dev/null
  '';
})
