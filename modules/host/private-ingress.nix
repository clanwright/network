{ config, lib, ... }:
let
  inherit (import ../../lib/types.nix { inherit lib; }) ipv4;
  claims = config.networkCore.firewall.privateIngressClaims;
  normalize = interfaces: lib.sort builtins.lessThan (lib.unique ([ "lo" ] ++ interfaces));
  destinations = lib.unique (map (claim: claim.destinationIPv4) (lib.attrValues claims));
  claimsFor = address: lib.filter (claim: claim.destinationIPv4 == address) (lib.attrValues claims);
  interfacesFor = address: normalize (builtins.head (claimsFor address)).trustedInterfaces;
  conflicting = lib.filter (
    address:
    let
      normalized = map (claim: normalize claim.trustedInterfaces) (claimsFor address);
    in
    !(lib.all (interfaces: interfaces == builtins.head normalized) normalized)
  ) destinations;
  ruleFor = address: ''
    ip daddr ${address} iifname != { ${
      lib.concatMapStringsSep ", " builtins.toJSON (interfacesFor address)
    } } counter drop comment "network: private IPv4 ingress"
  '';
in
{
  options.networkCore.firewall.privateIngressClaims = lib.mkOption {
    default = { };
    description = "Application private IPv4 destinations keyed by caller identity.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          destinationIPv4 = lib.mkOption { type = ipv4; };
          trustedInterfaces = lib.mkOption {
            type = lib.types.listOf (lib.types.strMatching "[a-zA-Z0-9_.-]{1,15}");
            default = [ ];
            description = "Ingress interfaces trusted for this destination; loopback is always trusted.";
          };
        };
      }
    );
  };
  options.networkCore.firewall.privateIngressRules = lib.mkOption {
    type = lib.types.lines;
    readOnly = true;
    internal = true;
  };

  config = {
    assertions = [
      {
        assertion = conflicting == [ ];
        message = "network firewall private ingress: conflicting trusted interface sets for IPv4 destination(s): ${lib.concatStringsSep ", " conflicting}.";
      }
    ];
    networkCore.firewall.privateIngressRules = lib.concatMapStringsSep "\n" ruleFor destinations;
  };
}
