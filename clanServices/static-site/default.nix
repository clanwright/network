_: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-static-site";
    description = "Serve a validated static artifact through a Caddy claim";
    readme = builtins.readFile ./README.md;
  };

  roles.site = {
    description = "Declare a host-scoped static site on an existing Caddy ingress";
    interface =
      { lib, ... }:
      let
        networkTypes = import ../../lib/types.nix { inherit lib; };
        dnsName = lib.types.addCheck lib.types.str (
          name:
          builtins.stringLength name <= 253
          &&
            builtins.match "[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*" name
            != null
          && builtins.all (label: builtins.stringLength label <= 63) (lib.splitString "." name)
        );
      in
      {
        options = {
          claimName = lib.mkOption {
            type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]*";
            description = "Stable Caddy claim and safe access-log name, independent of branding.";
          };
          hostName = lib.mkOption {
            type = dnsName;
            description = "Canonical DNS host served by the site.";
          };
          serverAliases = lib.mkOption {
            type = lib.types.listOf dnsName;
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
            type = lib.types.nullOr (lib.types.listOf networkTypes.ipv4);
            default = null;
            description = "IPv4 listeners; an empty list means wildcard.";
          };
          publicSite = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Declare this claim as the public root eligible for a proxy contribution.";
          };
        };
      };
    perInstance =
      { instanceName, settings, ... }:
      {
        nixosModule = import ../../modules/static-site {
          inherit instanceName settings;
        };
      };
  };
}
