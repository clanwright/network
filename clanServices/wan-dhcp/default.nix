_: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-wan-dhcp";
    description = "Native host wan-dhcp capability";
    readme = builtins.readFile ./README.md;
  };
  roles.host = {
    description = "Enable native wan-dhcp configuration on the host";
    interface =
      { lib, ... }:
      let
        inherit (import ../../lib/types.nix { inherit lib; }) interfaceName;
      in
      {
        options = {
          interface = lib.mkOption { type = interfaceName; };
          macAddress = lib.mkOption { type = lib.types.strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}"; };
        };
      };
    perInstance = { settings, ... }: {
      nixosModule = import ./module.nix { inherit settings; };
    };
  };
}
