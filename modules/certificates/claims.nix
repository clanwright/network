{ config, lib, ... }:
let
  ownerRecord = _: {
    options = {
      certName = lib.mkOption {
        type = lib.types.str;
        description = "Certificate name covered by the owner record.";
      };
      ownerToken = lib.mkOption {
        type = lib.types.str;
        description = "Stable owner token used to reject duplicate certificate ownership.";
      };
      sourceMarker = lib.mkOption {
        type = lib.types.str;
        description = "Source marker identifying the composition or machine owner.";
      };
    };
  };

  duplicateValues =
    values:
    lib.unique (
      lib.filter (value: builtins.length (lib.filter (candidate: candidate == value) values) > 1) values
    );

  collectOwnership =
    claims: claimOwners:
    let
      explicitNames = map (owner: owner.certName) claimOwners;
      claimRecords = lib.filter (owner: owner.ownerToken != null) (
        lib.mapAttrsToList (certName: claim: {
          inherit certName;
          inherit (claim) ownerToken sourceMarker;
        }) claims
      );
      owners =
        claimOwners ++ lib.filter (owner: !(builtins.elem owner.certName explicitNames)) claimRecords;
      duplicateCertNames = duplicateValues (map (owner: owner.certName) owners);
      duplicateOwnerTokens = duplicateValues (map (owner: owner.ownerToken) owners);
      missingSourceMarkers = lib.filter (owner: owner.sourceMarker == null) claimRecords;
      mismatchedOwners = lib.filter (
        owner:
        !(builtins.hasAttr owner.certName claims)
        || (
          claims.${owner.certName}.ownerToken != null
          && (
            claims.${owner.certName}.ownerToken != owner.ownerToken
            || claims.${owner.certName}.sourceMarker != owner.sourceMarker
          )
        )
      ) claimOwners;
    in
    {
      inherit
        duplicateCertNames
        duplicateOwnerTokens
        mismatchedOwners
        missingSourceMarkers
        owners
        ;
    };

  ownership = collectOwnership config.networkCore.acme.certificateClaims config.networkCore.acme.claimOwners;
in
{
  options.networkCore.acme = {
    certificateClaims = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (_: {
          options = {
            domain = lib.mkOption {
              type = lib.types.str;
              description = "Primary domain for an application ACME certificate claim.";
            };
            extraDomainNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Additional names for an application ACME certificate claim.";
            };
            ownerToken = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional stable owner token for this certificate claim.";
            };
            sourceMarker = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional source marker for this certificate claim.";
            };
          };
        })
      );
      default = { };
      description = "Narrow per-application ACME certificate claims.";
    };

    claimOwners = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ownerRecord);
      default = [ ];
      description = "Named certificate owner records contributed by composition wrappers.";
    };

    evaluatedOwners = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ownerRecord);
      internal = true;
      readOnly = true;
      description = "Final certificate owner records emitted by the machine ACME adapter.";
    };
  };

  config = {
    assertions = [
      {
        assertion = ownership.missingSourceMarkers == [ ];
        message = "A certificate claim owner token requires a source marker.";
      }
      {
        assertion = ownership.mismatchedOwners == [ ];
        message = "Explicit certificate ownership must match its declared certificate owner.";
      }
      {
        assertion = ownership.duplicateCertNames == [ ];
        message = "Certificate ownership must have unique certificate names.";
      }
      {
        assertion = ownership.duplicateOwnerTokens == [ ];
        message = "Certificate ownership must have unique owner tokens.";
      }
    ];

    networkCore.acme.evaluatedOwners = ownership.owners;
  };
}
