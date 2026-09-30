{
  description = "Independently selectable Clan network bricks for the Clanwright stack";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    clan-core = {
      url = "github:clan-lol/clan-core";
      inputs.nixpkgs.follows = "nixpkgs";
      # Pinned Clan unconditionally imports this unused module. Its empty
      # export follows this source so nested locking needs no relative input.
      inputs.data-mesher.follows = "";
    };
  };
  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      service = path: nixpkgs.lib.modules.importApply path { inherit self; };
    in
    {
      # Satisfy the pinned Clan import without declaring a fictitious service.
      nixosModules.data-mesher = _: { };
      clan.modules = {
        "@clanwright/network-certificates" = service ./clanServices/certificates/default.nix;
        "@clanwright/network-caddy" = service ./clanServices/caddy/default.nix;
        "@clanwright/network-static-site" = service ./clanServices/static-site/default.nix;
        "@clanwright/network-firewall" = service ./clanServices/firewall/default.nix;
        "@clanwright/network-wan-dhcp" = service ./clanServices/wan-dhcp/default.nix;
        "@clanwright/network-wan-static" = service ./clanServices/wan-static/default.nix;
      };
      packages.${system} = import ./packages/caddy.nix { inherit pkgs; };
      checks.${system} = import ./checks {
        inherit inputs pkgs self;
        root = ./.;
      };
      # Evaluation-only developer interface; the target remains x86_64-linux.
      lib.checkContracts =
        let
          expected = [
            "caddy-native-contracts"
            "certificate-native-contracts"
            "certificates-caddy-integration"
            "consumer-caddy"
            "consumer-certificates"
            "consumer-firewall"
            "consumer-static-site"
            "consumer-wan-dhcp"
            "consumer-wan-static"
            "firewall-invalid-bootstrap"
            "firewall-private-ingress-contracts"
            "firewall-public-destination-contracts"
            "static-site-contracts"
            "wan-selection-contracts"
          ];
          runtimeChecks = [
            "acme-local-renewal"
            "caddy-module-inventory"
            "caddy-runtime"
            "firewall-private-ingress-runtime"
            "firewall-runtime"
            "static-site-invalid-artifacts"
            "static-site-runtime"
            "timewebcloud-contract"
            "wan-dhcp-runtime"
            "wan-static-runtime"
          ];
          # Do not force runtime derivations just to discover pure predicates.
          contracts = nixpkgs.lib.genAttrs expected (name: self.checks.${system}.${name}.contract);
        in
        if
          builtins.attrNames self.checks.${system}
          != nixpkgs.lib.sort builtins.lessThan (expected ++ runtimeChecks)
        then
          throw "Network fast gate contract inventory changed; update its explicit coverage manifest"
        else if !builtins.all (result: result == true) (builtins.attrValues contracts) then
          throw "Network fast gate contract failed"
        else
          contracts;
      apps.aarch64-darwin.verify-fast = {
        type = "app";
        program = nixpkgs.lib.getExe (
          import ./packages/verify-fast.nix {
            pkgs = nixpkgs.legacyPackages.aarch64-darwin;
          }
        );
      };
      # Darwin is a development tool host, never a supported runtime target.
      formatter = nixpkgs.lib.genAttrs [ system "aarch64-darwin" ] (
        s: nixpkgs.legacyPackages.${s}.nixfmt
      );
    };
}
