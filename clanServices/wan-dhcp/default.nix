_: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-wan-dhcp";
    description = "Native host wan-dhcp capability";
    readme = builtins.readFile ./README.md;
  };
  roles.host = {
    description = "Enable native wan-dhcp configuration on the host";
    interface = { lib, ... }: {
      options = {
        interface = lib.mkOption { type = lib.types.strMatching "[a-zA-Z0-9_.-]{1,15}"; };
        macAddress = lib.mkOption { type = lib.types.strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}"; };
        enableIPv6 = lib.mkOption {
          type = lib.types.nullOr lib.types.bool;
          default = null;
        };

      };
    };
    perInstance = { settings, ... }: {
      nixosModule = _: {
        imports = [
          ../../modules/host/platform.nix
          (import ../../modules/host/wan-dhcp.nix { inherit settings; })
        ];
      };
    };
  };
}
