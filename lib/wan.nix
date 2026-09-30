{ config, lib, ... }:
let
  inherit (import ./types.nix { inherit lib; }) interfaceName ipv4;
  claims = config.networking.networkWanClaims;
  interfaces = map (claim: claim.interface) claims;
  physicalMacs = map (claim: lib.toLower claim.macAddress) claims;
in
{
  # Only the facts needed to reject competing physical ownership are retained.
  # This is internal composition state, not a consumer declaration interface.
  options.networking.networkWanClaims = lib.mkOption {
    default = [ ];
    internal = true;
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          interface = lib.mkOption { type = interfaceName; };
          macAddress = lib.mkOption { type = lib.types.strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}"; };
          mode = lib.mkOption {
            type = lib.types.enum [
              "dhcp"
              "static"
            ];
          };
          primaryIPv4 = lib.mkOption {
            type = lib.types.nullOr ipv4;
            default = null;
          };
        };
      }
    );
  };
  config.assertions = [
    {
      assertion = lib.length (lib.filter (claim: claim.mode == "static") claims) <= 1;
      message = "network WAN: a host may select at most one static WAN instance.";
    }
    {
      assertion = lib.length interfaces == lib.length (lib.unique interfaces);
      message = "network WAN: an interface must have exactly one explicit owner (DHCP or static).";
    }
    {
      assertion = lib.length physicalMacs == lib.length (lib.unique physicalMacs);
      message = "network WAN: a physical MAC address must have exactly one explicit interface owner.";
    }
  ];
}
