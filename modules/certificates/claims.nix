{ lib, ... }:
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

  validateOwnerRecords =
    owners:
    let
      duplicateCertNames = duplicateValues (map (owner: owner.certName) owners);
      duplicateOwnerTokens = duplicateValues (map (owner: owner.ownerToken) owners);
    in
    if duplicateCertNames != [ ] then
      throw "edge ACME certificate claim collides: duplicate certName ${lib.concatStringsSep ", " duplicateCertNames}"
    else if duplicateOwnerTokens != [ ] then
      throw "edge ACME certificate claim collides: duplicate owner token ${lib.concatStringsSep ", " duplicateOwnerTokens}"
    else
      owners;

  validateCertificateClaims =
    claims:
    let
      records = lib.filter (claim: claim.ownerToken != null) (
        lib.mapAttrsToList (certName: claim: {
          inherit certName;
          inherit (claim) ownerToken;
          inherit (claim) sourceMarker;
        }) claims
      );
      missingSourceMarkers = lib.filter (record: record.sourceMarker == null) records;
    in
    if missingSourceMarkers != [ ] then
      throw "edge ACME certificate claim collides: owner token requires sourceMarker"
    else
      builtins.seq (validateOwnerRecords records) claims;
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
      apply = validateCertificateClaims;
      default = { };
      description = "Narrow per-application ACME certificate claims.";
    };

    claimOwners = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ownerRecord);
      apply = validateOwnerRecords;
      default = [ ];
      description = "Named certificate owner records contributed by composition wrappers.";
    };

    evaluatedOwners = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ownerRecord);
      default = [ ];
      description = "Final certificate owner records emitted by the machine ACME adapter.";
    };
  };
}
