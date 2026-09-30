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
        inherit (import ../../lib/types.nix { inherit lib; }) ipv4;
        portOptions = {
          options.allowedTCPPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
          };
          options.allowedUDPPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
          };
        };
        portSettings = lib.types.submodule portOptions;
        destinationSettings = lib.types.submodule [
          portOptions
          { options.destinationIPv4 = lib.mkOption { type = ipv4; }; }
        ];
      in
      {
        options = {
          public = lib.mkOption {
            default = { };
            type = lib.types.submodule [
              portOptions
              {
                options.destinations = lib.mkOption {
                  type = lib.types.listOf destinationSettings;
                  default = [ ];
                  description = "Public ports accepted only for one host IPv4 destination.";
                };
              }
            ];
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
              type = lib.types.nullOr ipv4;
              default = null;
            };
            markerPath = lib.mkOption {
              type = lib.types.strMatching "/[^\n]*";
              default = "/var/lib/bootstrap/allow-wan-ssh";
            };
            durationSeconds = lib.mkOption {
              type = lib.types.ints.between 1 3600;
              default = 3600;
              description = "Maximum bootstrap SSH window and explicit renewal duration.";
            };
          };

        };
      };
    perInstance = { settings, ... }: {
      nixosModule = import ./module.nix { inherit settings; };
    };
  };
}
