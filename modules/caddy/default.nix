{ config, lib, ... }:
let
  cfg = config.networkCore.caddy;
  fragments = cfg.effectiveFragments;
  enableForwardProxyOrdering = builtins.any (
    claim: builtins.elem "forward-proxy" claim.capabilities
  ) (lib.attrValues fragments);
  render =
    claim:
    lib.concatStringsSep "\n" (
      lib.filter (value: value != "") [
        (lib.concatStringsSep "\n" claim.preRouteConfigFragments)
        claim.extraConfig
        (lib.concatStringsSep "\n" claim.extraConfigFragments)
      ]
    );
in
{
  imports = [ ./claims.nix ];
  config = {
    assertions = lib.mapAttrsToList (name: claim: {
      assertion = builtins.hasAttr claim.useACMEHost config.security.acme.certs;
      message = "Caddy claim ${name} requires an existing ACME certificate ${claim.useACMEHost}.";
    }) fragments;
    services.caddy = {
      enable = true;
      virtualHosts = lib.mapAttrs (_: claim: {
        hostName =
          if claim.siteAddress != null then
            claim.siteAddress
          else
            lib.concatStringsSep ", " ([ claim.hostName ] ++ claim.serverAliases);
        inherit (claim) useACMEHost;
        extraConfig = render claim;
        listenAddresses = lib.unique claim.listenAddresses;
        logFormat = ''
          format json {
            time_format iso8601
          }
          output file ${claim.logFile}
        '';
      }) fragments;
      logFormat = "level INFO";
      globalConfig = ''
        auto_https off
        ${lib.optionalString enableForwardProxyOrdering "order forward_proxy before file_server"}
        servers {
          protocols h1 h2
        }
      '';
    };
    systemd.services.caddy = {
      requires = lib.unique (lib.concatMap (claim: claim.requiresUnits) (lib.attrValues fragments));
      after = lib.unique (lib.concatMap (claim: claim.afterUnits) (lib.attrValues fragments));
      wants = lib.unique (lib.concatMap (claim: claim.wantsUnits) (lib.attrValues fragments));
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
    systemd.tmpfiles.rules = lib.optionals (fragments != { }) (
      [ "d /var/log/caddy 0750 caddy caddy -" ]
      ++ lib.unique (map (claim: "f ${claim.logFile} 0640 caddy caddy -") (lib.attrValues fragments))
    );
    users.users.caddy.extraGroups = [ "acme" ];
  };
}
