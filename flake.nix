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
        "@clanwright/network-tcp-tuning" = service ./clanServices/tcp-tuning/default.nix;
      };
      packages.${system} =
        (import ./packages/caddy.nix {
          apps-nixpkgs = nixpkgs;
          inherit system;
        })
        // {
          lego = import ./packages/lego.nix { inherit pkgs; };
        };
      checks.${system} = import ./checks {
        inherit inputs pkgs self;
        root = ./.;
      };
      # Darwin is a development tool host, never a supported runtime target.
      formatter = nixpkgs.lib.genAttrs [ system "aarch64-darwin" ] (
        s: nixpkgs.legacyPackages.${s}.nixfmt
      );
    };
}
