{ instanceName, settings }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hostName = lib.toLower settings.hostName;
  serverAliases = map lib.toLower settings.serverAliases;
  hosts = [ hostName ] ++ serverAliases;
  hostMatcher = "@static_site_${settings.claimName}_hosts";
  aliasMatcher = "@static_site_${settings.claimName}_aliases";
  errorMatcher = "@static_site_${settings.claimName}_errors";
  validatedArtifact =
    pkgs.runCommand "network-static-site-${settings.claimName}"
      {
        siteArtifact = settings.artifact;
      }
      ''
        bash ${./validate-artifact.sh} "$siteArtifact" "$out"
      '';
  aliasRedirect = lib.optionalString (serverAliases != [ ]) ''
    ${aliasMatcher} {
      host ${lib.concatStringsSep " " serverAliases}
      method GET HEAD
      not header Proxy-Authorization *
    }
    redir ${aliasMatcher} https://${hostName}{uri} 308
  '';
in
{
  imports = [
    ./claims.nix
    ../caddy/claims.nix
    ../host/platform.nix
  ];
  config = {
    networkCore.staticSite.claimNames = [ settings.claimName ];
    assertions = [
      {
        assertion = settings.listenAddresses != null;
        message = "network-static-site requires an explicit listenAddresses list; [] means wildcard.";
      }
      {
        assertion = config.services.caddy.enable;
        message = "network-static-site requires the network-caddy ingress role on the same machine.";
      }
    ];
    networkCore.caddy.fragments.${settings.claimName} = {
      inherit hostName serverAliases;
      inherit (settings) useACMEHost publicSite;
      listenAddresses = if settings.listenAddresses == null then [ ] else settings.listenAddresses;
      logFile = "/var/log/caddy/${settings.claimName}.log";
      siteOwners = lib.optional settings.publicSite "static-site:${instanceName}";
      extraConfig = ''
        ${hostMatcher} host ${lib.concatStringsSep " " hosts}
        ${aliasRedirect}
        root ${hostMatcher} ${validatedArtifact}
        file_server ${hostMatcher}

        handle_errors 404 {
          ${errorMatcher} host ${lib.concatStringsSep " " hosts}
          handle ${errorMatcher} {
            rewrite * /404.html
            file_server
          }
        }
      '';
    };
  };
}
