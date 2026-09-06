{ config, lib, ... }:
let
  claims = config.networkCore.wan.claims;
  pairs = lib.concatMap (a: map (b: { inherit a b; }) claims) claims;
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
          tableId = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
          };
          tableName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
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
      assertion =
        lib.all (pair: pair.a == pair.b || pair.a.interface != pair.b.interface) pairs
        && builtins.length claims == builtins.length (lib.unique claims);
      message = "network WAN: an interface must have exactly one explicit owner (DHCP or static).";
    }
    {
      assertion = lib.all (
        pair: pair.a == pair.b || lib.toLower pair.a.macAddress != lib.toLower pair.b.macAddress
      ) pairs;
      message = "network WAN: a physical MAC address must have exactly one explicit interface owner.";
    }
    {
      assertion = lib.all (
        pair:
        pair.a == pair.b
        || pair.a.tableId == null
        || pair.b.tableId == null
        || (pair.a.tableId != pair.b.tableId && pair.a.tableName != pair.b.tableName)
      ) pairs;
      message = "network WAN: route table names and IDs must have unique owners.";
    }
  ];
}
