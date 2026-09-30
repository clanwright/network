{ instanceName, settings }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (settings) hostName serverAliases;
  hosts = [ hostName ] ++ serverAliases;
  matcherID = builtins.substring 0 16 (builtins.hashString "sha256" hostName);
  hostMatcher = "@static_site_${matcherID}_hosts";
  aliasMatcher = "@static_site_${matcherID}_aliases";
  errorMatcher = "@static_site_${matcherID}_errors";
  validatedArtifact =
    pkgs.runCommand "network-static-site-${matcherID}" { siteArtifact = settings.artifact; }
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
  config = {
    assertions = [
      {
        assertion = config.services.caddy.enable;
        message = "network-static-site requires the network-caddy ingress role on the same machine.";
      }
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "network-static-site supports x86_64-linux only.";
      }
    ];
    services.caddy.virtualHosts.${hostName} = {
      owner = "static-site:${instanceName}";
      inherit serverAliases;
      inherit (settings) useACMEHost listenAddresses;
      extraConfig = lib.mkMerge [
        (lib.optionalString (serverAliases != [ ]) ''
          route {
            ${aliasRedirect}
          }
        '')
        (lib.mkOrder 2000 ''
          route {
            ${hostMatcher} host ${lib.concatStringsSep " " hosts}
            root ${hostMatcher} ${validatedArtifact}
            file_server ${hostMatcher}
          }

          handle_errors 404 {
            ${errorMatcher} host ${lib.concatStringsSep " " hosts}
            handle ${errorMatcher} {
              rewrite * /404.html
              file_server
            }
          }
        '')
      ];
    };
  };
}
