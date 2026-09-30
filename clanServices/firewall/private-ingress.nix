{ config, lib, ... }:
let
  inherit (import ../../lib/types.nix { inherit lib; }) ipv4 interfaceName;
  claims = lib.attrValues config.networking.firewall.privateIngress;
  normalize = interfaces: lib.sort builtins.lessThan (lib.unique ([ "lo" ] ++ interfaces));
  destinations = lib.sort builtins.lessThan (lib.unique (map (claim: claim.destinationIPv4) claims));
  claimsFor = address: lib.filter (claim: claim.destinationIPv4 == address) claims;
  interfacesFor = address: normalize (builtins.head (claimsFor address)).trustedInterfaces;
  conflicting = lib.filter (
    address:
    !lib.all (claim: normalize claim.trustedInterfaces == interfacesFor address) (claimsFor address)
  ) destinations;
  ruleFor = address: ''
    ip daddr ${address} iifname != { ${
      lib.concatMapStringsSep ", " builtins.toJSON (interfacesFor address)
    } } counter drop comment "network: private IPv4 ingress"
  '';
in
{
  options.networking.firewall = {
    networkBaseOwner = lib.mkOption {
      internal = true;
      type = lib.types.unique {
        message = "Select exactly one Network firewall base role per host; other services contribute native settings.";
      } lib.types.bool;
    };
    privateIngress = lib.mkOption {
      default = { };
      description = "Private IPv4 destinations keyed by explicit consumer identity; this guard never accepts traffic.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            destinationIPv4 = lib.mkOption { type = ipv4; };
            trustedInterfaces = lib.mkOption {
              type = lib.types.listOf interfaceName;
              default = [ ];
              description = "Permitted ingress interfaces for this destination; loopback is implicit.";
            };
          };
        }
      );
    };
  };
  config = {
    assertions = [
      {
        assertion = conflicting == [ ];
        message = "network firewall private ingress: conflicting trusted interface sets for IPv4 destination(s): ${lib.concatStringsSep ", " conflicting}.";
      }
    ];
    networking.nftables.tables.network-edge-policy = lib.mkIf (claims != [ ]) {
      family = "inet";
      content = ''
        chain private_ingress_guard {
          type filter hook input priority filter - 10; policy accept;
          ${lib.concatMapStringsSep "\n" ruleFor destinations}
        }
      '';
    };
  };
}
