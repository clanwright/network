{
  description = "Independently selectable Clan network bricks for the Clanwright stack";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    data-mesher.url = "path:./stubs/data-mesher";
    clan-core = {
      url = "github:clan-lol/clan-core";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.data-mesher.follows = "data-mesher";
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
      clan.modules = {
        "@clanwright/network-certificates" = service ./clanServices/certificates/default.nix;
        "@clanwright/edge-wildcard-certificate" = service ./clanServices/wildcard-certificate/default.nix;
        "@clanwright/network-caddy" = service ./clanServices/caddy/default.nix;
        "@clanwright/network-firewall" = service ./clanServices/firewall/default.nix;
        "@clanwright/network-wan-dhcp" = service ./clanServices/wan-dhcp/default.nix;
        "@clanwright/network-wan-static" = service ./clanServices/wan-static/default.nix;
      };
      packages.${system} = (import ./packages/caddy.nix { inherit pkgs; }) // {
        lego = import ./packages/lego.nix { inherit pkgs; };
      };
      checks.${system} = import ./checks {
        inherit inputs pkgs self;
        root = ./.;
      };
      # Evaluation-only developer interface; the target remains x86_64-linux.
      lib.checkContracts =
        let
          expected = [
            "caddy-contribution-dependencies"
            "caddy-public-site-owner"
            "caddy-wildcard-listener-collisions"
            "certificate-owner-consistency"
            "certificates-caddy-integration"
            "consumer-caddy"
            "consumer-certificates"
            "consumer-firewall"
            "consumer-wan-dhcp"
            "consumer-wan-static"
            "consumer-wildcard"
            "firewall-invalid-bootstrap"
            "incompatible-certificate-reload"
            "wan-selection-contracts"
          ];
          contracts = nixpkgs.lib.mapAttrs (_: check: check.contract) (
            nixpkgs.lib.filterAttrs (_: check: check ? contract) self.checks.${system}
          );
        in
        if builtins.attrNames contracts != expected then
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
