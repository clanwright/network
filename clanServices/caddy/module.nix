{ package }:
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.caddy;
  networkTypes = import ../../lib/types.nix { inherit lib; };
  defaultLogFormat = ''
    output stderr
    format json
    level INFO
    exclude http.log.error
  '';
  addressesOverlap =
    left: right:
    left == [ ]
    || right == [ ]
    || builtins.elem "0.0.0.0" left
    || builtins.elem "0.0.0.0" right
    || lib.intersectLists left right != [ ];
  sites = lib.mapAttrsToList (name: site: {
    inherit name;
    inherit (site)
      owner
      hostName
      serverAliases
      listenAddresses
      forwardProxy
      useACMEHost
      ;
    hosts = [ name ] ++ site.serverAliases;
  }) cfg.virtualHosts;
  pairs = lib.concatMap (
    left: map (right: { inherit left right; }) (lib.filter (right: left.name < right.name) sites)
  ) sites;
  overlapping = lib.filter (
    pair: addressesOverlap pair.left.listenAddresses pair.right.listenAddresses
  ) pairs;
in
{
  options.services.caddy.virtualHosts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, name, ... }:
        {
          options = {
            owner = lib.mkOption {
              type = lib.types.uniq (lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_.:@/-]*");
              description = "Single base-site owner token. Route extensions must not redeclare it.";
            };
            forwardProxy = lib.mkOption {
              type = lib.types.uniq lib.types.bool;
              default = false;
              description = "Exclusive listener-wide forward-proxy root; extensions set true once.";
            };
            serverAliases = lib.mkOption { type = lib.types.listOf networkTypes.dnsName; };
            listenAddresses = lib.mkOption { type = lib.types.listOf networkTypes.ipv4; };
          };
          config = {
            hostName = lib.mkDefault (if config.forwardProxy then ":443" else name);
            logFormat = lib.mkDefault ''
              output stderr
              format json
            '';
          };
        }
      )
    );
  };

  config = {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "network-caddy supports x86_64-linux only.";
      }
      {
        assertion = cfg.package.outPath == package.outPath;
        message = "network-caddy requires its release-pinned caddy-custom package.";
      }
      {
        assertion =
          cfg.settings == { }
          && cfg.extraConfig == ""
          && options.services.caddy.configFile.highestPrio == 1500
          && cfg.adapter == "caddyfile"
          && !cfg.resume;
        message = "network-caddy requires the native virtualHosts-generated Caddyfile without main configuration, adapter, or resume overrides.";
      }
      {
        assertion = options.services.caddy.globalConfig.highestPrio == 100;
        message = "network-caddy globalConfig must retain the native Network policy; ordinary ordered additions are supported.";
      }
      {
        assertion = cfg.logFormat == defaultLogFormat;
        message = "network-caddy requires the default logger to exclude HTTP errors; access logging is configured per native virtual host.";
      }
      {
        assertion = !(builtins.any (site: site.forwardProxy) sites) || cfg.httpsPort == 443;
        message = "network-caddy forward-proxy roots require services.caddy.httpsPort = 443 so native aliases share their listener port.";
      }
      {
        assertion = builtins.all (site: networkTypes.dnsName.check site.name) sites;
        message = "network-caddy virtualHosts keys must be canonical lowercase ASCII DNS hosts, without raw addresses, URL, port, wildcard, or trailing dot.";
      }
      {
        assertion = builtins.all (
          site:
          site.owner != ""
          && site.hostName == (if site.forwardProxy then ":443" else site.name)
          && builtins.all networkTypes.dnsName.check site.serverAliases
          && builtins.length site.serverAliases == builtins.length (lib.unique site.serverAliases)
          && !(builtins.elem site.name site.serverAliases)
          && builtins.all networkTypes.ipv4.check site.listenAddresses
        ) sites;
        message = "network-caddy requires one owner, its derived native hostname, canonical distinct aliases, and IPv4 listeners per site.";
      }
      {
        assertion = builtins.all (
          pair: lib.intersectLists pair.left.hosts pair.right.hosts == [ ]
        ) overlapping;
        message = "network-caddy canonical hosts or aliases overlap on shared IPv4 listeners.";
      }
      {
        assertion = builtins.all (pair: !(pair.left.forwardProxy && pair.right.forwardProxy)) overlapping;
        message = "network-caddy forward-proxy roots overlap on shared IPv4 listeners.";
      }
    ];
    services.caddy = {
      enable = true;
      inherit package;
      logFormat = defaultLogFormat;
      globalConfig = ''
        persist_config off
        auto_https off
        ${lib.optionalString (builtins.any (
          site: site.forwardProxy
        ) sites) "order forward_proxy before file_server"}
        servers {
          protocols h1 h2
        }
        log sanitized_http_errors {
          output stderr
          include http.log.error
          format filter {
            wrap json {
              message_key ""
            }
            fields {
              request>uri delete
              request>headers delete
              error delete
              msg delete
            }
          }
        }
      '';
    };
    users.users.caddy.extraGroups = lib.optional (builtins.any (
      site: site.useACMEHost != null && config.security.acme.certs.${site.useACMEHost}.group == "acme"
    ) sites) "acme";
  };
}
