# Stub for data-mesher flake input.
# git.clan.lol server serves truncated tarballs for this repo.
# Our project does not use data-mesher; this stub satisfies clan-core's
# unconditional import of inputs.data-mesher.nixosModules.data-mesher.
{
  description = "data-mesher stub";
  outputs = _: {
    nixosModules.data-mesher =
      { lib, pkgs, ... }:
      {
        options.services.data-mesher = {
          enable = lib.mkEnableOption "data-mesher";
          package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.hello;
            description = "stub — not used in this project";
          };
          openFirewall = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          logLevel = lib.mkOption {
            type = lib.types.str;
            default = "info";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 7946;
          };
        };
      };
  };
}
