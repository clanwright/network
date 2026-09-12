{ config, lib, ... }:
let
  claims = config.networkCore.wan.claims;
  interfaces = map (claim: claim.interface) claims;
  physicalMacs = map (claim: lib.toLower claim.macAddress) claims;
in
{
  options.networkCore.wan.claims = lib.mkOption {
    default = [ ];
    internal = true;
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          owner = lib.mkOption { type = lib.types.str; };
          interface = lib.mkOption { type = lib.types.str; };
          macAddress = lib.mkOption { type = lib.types.str; };
          mode = lib.mkOption {
            type = lib.types.enum [
              "dhcp"
              "static"
            ];
          };
        };
      }
    );
  };
  config.assertions = [
    {
      assertion = builtins.length (builtins.filter (claim: claim.mode == "static") claims) <= 1;
      message = "network WAN: a host may select at most one static WAN instance.";
    }
    {
      assertion = builtins.length interfaces == builtins.length (lib.unique interfaces);
      message = "network WAN: an interface must have exactly one explicit owner (DHCP or static).";
    }
    {
      assertion = builtins.length physicalMacs == builtins.length (lib.unique physicalMacs);
      message = "network WAN: a physical MAC address must have exactly one explicit interface owner.";
    }
  ];
}
