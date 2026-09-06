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
        ipv4 = lib.types.addCheck lib.types.str (
          value:
          let
            octets = lib.splitString "." value;
            validOctet = octet: builtins.match "(0|[1-9][0-9]{0,2})" octet != null && lib.toInt octet <= 255;
          in
          builtins.length octets == 4 && lib.all validOctet octets
        );
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
