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
        inherit (import ../../lib/types.nix { inherit lib; }) ipv4 interfaceName;
      in
      {
        options = {
          interface = lib.mkOption { type = interfaceName; };
          macAddress = lib.mkOption { type = lib.types.strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}"; };
          primaryIPv4 = lib.mkOption { type = ipv4; };
          prefixLength = lib.mkOption { type = lib.types.ints.between 0 32; };
          gateway = lib.mkOption { type = ipv4; };
          additionalIPv4s = lib.mkOption {
            type = lib.types.listOf (
              lib.types.submodule {
                options = {
                  address = lib.mkOption { type = ipv4; };
                  prefixLength = lib.mkOption {
                    type = lib.types.nullOr (lib.types.ints.between 0 32);
                    default = null;
                  };
                  gateway = lib.mkOption {
                    type = lib.types.nullOr ipv4;
                    default = null;
                  };
                  routeTable = lib.mkOption {
                    type = lib.types.nullOr (lib.types.ints.between 1 4294967295);
                    default = null;
                    description = "Stable native route-table ID, required with a separate gateway.";
                  };
                  rulePriority = lib.mkOption {
                    type = lib.types.nullOr (lib.types.ints.between 10001 32765);
                    default = null;
                    description = "Stable source-rule priority after main non-default lookup (10000).";
                  };
                };
              }
            );
            default = [ ];
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
      nixosModule = import ./module.nix { inherit settings; };
    };
  };
}
