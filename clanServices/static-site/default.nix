_: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-static-site";
    description = "Serve a validated static artifact through a native Caddy virtual host";
    readme = builtins.readFile ./README.md;
  };

  roles.site = {
    description = "Declare a host-scoped static site on an existing Caddy ingress";
    interface =
      { lib, options, ... }:
      let
        networkTypes = import ../../lib/types.nix { inherit lib; };
      in
      {
        options = {
          hostName = lib.mkOption {
            type = networkTypes.dnsName;
            description = "Canonical lowercase ASCII DNS host and native Caddy virtualHosts key.";
          };
          serverAliases = lib.mkOption {
            type = lib.types.listOf networkTypes.dnsName;
            default = [ ];
            description = "Additional DNS hosts redirected to the canonical host.";
          };
          artifact = lib.mkOption {
            type = lib.types.addCheck lib.types.str (
              value:
              builtins.match "/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._-]+" value != null
              && builtins.getContext value != { }
            );
            description = "Built site directory or context-preserving Nix store path.";
          };
          useACMEHost = lib.mkOption {
            type = lib.types.str;
            description = "Existing certificate name; this role does not issue certificates.";
          };
          listenAddresses = lib.mkOption {
            type = lib.types.listOf networkTypes.ipv4;
            # listOf's implicit emptyValue is []; require an actual definition
            # so only an explicitly supplied [] selects wildcard listeners.
            apply =
              addresses:
              if options.listenAddresses.isDefined then
                addresses
              else
                throw "network-static-site requires explicit listenAddresses; [] means wildcard.";
            description = "IPv4 listeners; an empty list means wildcard.";
          };
        };
      };
    perInstance =
      { instanceName, settings, ... }:
      {
        nixosModule = import ./module.nix {
          inherit instanceName settings;
        };
      };
  };
}
