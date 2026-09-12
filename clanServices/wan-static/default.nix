_: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-wan-static";
    description = "Native host wan-static capability";
    readme = builtins.readFile ./README.md;
  };
  roles.host = {
    description = "Enable native wan-static configuration on the host";
    interface =
      { lib, ... }:
      let
        inherit (import ../../lib/types.nix { inherit lib; }) ipv4;
      in
      {
        options = {
          interface = lib.mkOption { type = lib.types.strMatching "[a-zA-Z0-9_.-]{1,15}"; };
          macAddress = lib.mkOption { type = lib.types.strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}"; };
          enableIPv6 = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
          };
          primaryIPv4 = lib.mkOption { type = ipv4; };
          secondaryIPv4 = lib.mkOption { type = ipv4; };
          prefixLength = lib.mkOption { type = lib.types.ints.between 0 32; };
          gateway = lib.mkOption { type = ipv4; };
          routeTableName = lib.mkOption { type = lib.types.strMatching "[a-zA-Z][a-zA-Z0-9_]*"; };
          routeTableId = lib.mkOption { type = lib.types.ints.between 1 4294967295; };
          rulePriority = lib.mkOption {
            type = lib.types.ints.between 1 4294967295;
            default = 10010;
          };
          waitOnline = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            timeout = lib.mkOption {
              type = lib.types.ints.positive;
              default = 60;
            };
          };

        };
      };
    perInstance = { settings, ... }: {
      nixosModule = _: {
        imports = [
          ../../modules/host/platform.nix
          (import ../../modules/host/wan-static.nix { inherit settings; })
        ];
      };
    };
  };
}
