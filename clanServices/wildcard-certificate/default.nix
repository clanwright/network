_: _: {
  _class = "clan.service";

  manifest = {
    name = "@clanwright/edge-wildcard-certificate";
    description = "Composition-owned DNS-01 wildcard certificate claim";
    readme = builtins.readFile ./README.md;
  };

  roles.certificate = {
    description = "Register exactly one composition-owned wildcard certificate claim";

    interface =
      { lib, ... }:
      {
        options = {
          certName = lib.mkOption {
            type = lib.types.str;
            description = "Certificate name consumed by edge Caddy claims.";
          };

          domain = lib.mkOption {
            type = lib.types.str;
            description = "Primary DNS name for the wildcard certificate.";
          };

          extraDomainNames = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Additional SANs, including the wildcard name.";
          };
        };
      };

    perInstance =
      {
        instanceName ? "edge-wildcard-certificate",
        settings,
        ...
      }:
      let
        ownerToken = "composition:${instanceName}";
      in
      {
        nixosModule = _: {
          networkCore.acme = {
            certificateClaims.${settings.certName} = {
              inherit (settings) domain extraDomainNames;
              inherit ownerToken;
              sourceMarker = ownerToken;
            };

            claimOwners = [
              {
                inherit (settings) certName;
                inherit ownerToken;
                sourceMarker = ownerToken;
              }
            ];

          };
        };
      };
  };
}
