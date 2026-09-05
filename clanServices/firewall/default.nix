_: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-firewall";
    description = "Native host firewall capability";
    readme = builtins.readFile ./README.md;
  };
  roles.host = {
    description = "Enable native firewall configuration on the host";
    interface =
      { lib, ... }:
      let
        portSettings = lib.types.submodule {
          options.allowedTCPPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
          };
          options.allowedUDPPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
          };
        };
      in
      {
        options = {
          public = lib.mkOption {
            default = { };
            type = portSettings;
          };
          interfaces = lib.mkOption {
            default = { };
            type = lib.types.attrsOf portSettings;
          };
          rejectHttp = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          bootstrapSsh = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            publicIPv4 = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+");
              default = null;
            };
            markerPath = lib.mkOption {
              type = lib.types.strMatching "/[^\n]*";
              default = "/var/lib/bootstrap/allow-wan-ssh";
            };
          };

        };
      };
    perInstance = { settings, ... }: {
      nixosModule = _: {
        imports = [
          ../../modules/host/platform.nix
          (import ../../modules/host/firewall.nix { inherit settings; })
        ];
      };
    };
  };
}
