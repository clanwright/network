{ pkgs }:
pkgs.lego.overrideAttrs (previous: {
  patches = (previous.patches or [ ]) ++ [
    ./lego-timewebcloud-v2-contract.patch
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
    "$out/bin/lego" run --accept-tos --help >/dev/null
  '';
})
