{ config, lib, ... }:
{
  options.networkCore.staticSite.claimNames = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    internal = true;
    description = "Static-site claim names before Caddy fragment merging.";
  };
  config.assertions = [
    {
      assertion =
        builtins.length config.networkCore.staticSite.claimNames
        == builtins.length (lib.unique config.networkCore.staticSite.claimNames);
      message = "network-static-site claimName must be unique across site instances.";
    }
  ];
}
