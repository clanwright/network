{ config, lib, ... }:
let
  networkTypes = import ../../lib/types.nix { inherit lib; };

  normalizeHost = hostName: lib.toLower (lib.removeSuffix "." hostName);

  claimHosts = claim: map normalizeHost ([ claim.hostName ] ++ claim.serverAliases);

  isSafeLogPath =
    path:
    let
      segments = lib.drop 1 (lib.splitString "/" path);
    in
    lib.hasPrefix "/" path
    && segments != [ ]
    && builtins.all (
      segment: segment != "." && segment != ".." && builtins.match "[A-Za-z0-9._+-]+" segment != null
    ) segments;

  safeLogPath = lib.types.addCheck lib.types.str isSafeLogPath;

  addressesOverlap =
    left: right:
    left == [ ]
    || right == [ ]
    || builtins.elem "0.0.0.0" left
    || builtins.elem "0.0.0.0" right
    || lib.intersectLists left right != [ ];

  duplicateValues =
    values:
    lib.unique (
      lib.filter (value: builtins.length (lib.filter (candidate: candidate == value) values) > 1) values
    );

  validateClaims =
    requireCompleteCapabilities: fragments:
    let
      claimEntries = lib.mapAttrsToList (key: claim: {
        inherit key claim;
        hosts = claimHosts claim;
        listenAddresses = lib.unique claim.listenAddresses;
      }) fragments;
      invalidAliases = lib.concatLists (
        map (
          entry:
          let
            aliases = map normalizeHost entry.claim.serverAliases;
            duplicateAliases = duplicateValues aliases;
            hostOverlap = lib.filter (alias: alias == normalizeHost entry.claim.hostName) aliases;
          in
          map (alias: "${entry.key}:${alias}") (duplicateAliases ++ hostOverlap)
        ) claimEntries
      );
      collidingPairs = lib.concatLists (
        map (
          leftEntry:
          lib.concatLists (
            map (
              rightEntry:
              lib.optional (leftEntry.key < rightEntry.key) {
                left = leftEntry;
                right = rightEntry;
              }
            ) claimEntries
          )
        ) claimEntries
      );
      collisions = lib.filter (
        pair:
        lib.intersectLists pair.left.hosts pair.right.hosts != [ ]
        && addressesOverlap pair.left.listenAddresses pair.right.listenAddresses
      ) collidingPairs;
      capabilityCollisions = lib.filter (
        pair:
        lib.intersectLists pair.left.claim.capabilities pair.right.claim.capabilities != [ ]
        && addressesOverlap pair.left.listenAddresses pair.right.listenAddresses
      ) collidingPairs;
      invalidOwners = lib.filter (
        entry:
        builtins.any (owner: owner == "") entry.claim.siteOwners
        || (entry.claim.publicSite && builtins.length entry.claim.siteOwners != 1)
        || (!entry.claim.publicSite && entry.claim.siteOwners != [ ])
        || duplicateValues entry.claim.capabilities != [ ]
        || (entry.claim.capabilities != [ ] && !entry.claim.publicSite)
      ) claimEntries;
      incompleteCapabilities = lib.filter (
        entry: builtins.elem "forward-proxy" entry.claim.capabilities != (entry.claim.siteAddress == ":443")
      ) claimEntries;
      collisionMessage = lib.concatStringsSep "; " (
        map (
          pair:
          "${pair.left.key} and ${pair.right.key} both claim ${lib.concatStringsSep ", " (lib.intersectLists pair.left.hosts pair.right.hosts)}"
        ) collisions
      );
    in
    if invalidAliases != [ ] then
      throw "edge Caddy claim aliases collide with their host: ${lib.concatStringsSep ", " invalidAliases}"
    else if collisions != [ ] then
      throw "edge Caddy claims overlap: ${collisionMessage}"
    else if capabilityCollisions != [ ] then
      throw "Caddy capability claims share a listener"
    else if invalidOwners != [ ] then
      throw "Caddy site ownership or capability declaration is invalid"
    else if requireCompleteCapabilities && incompleteCapabilities != [ ] then
      throw "Caddy forward-proxy capability requires siteAddress :443 in the assembled effective fragment"
    else
      fragments;

  claimType = lib.types.submodule (_: {
    options = {
      hostName = lib.mkOption {
        type = lib.types.str;
        description = "Canonical host served by this Caddy claim.";
      };
      serverAliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional normalized host names served by this claim.";
      };
      listenAddresses = lib.mkOption {
        type = lib.types.listOf networkTypes.ipv4;
        default = [ ];
        description = "IPv4 listeners; an empty list or 0.0.0.0 is a wildcard.";
      };
      useACMEHost = lib.mkOption {
        type = lib.types.str;
        description = "Existing DNS-01 ACME certificate name.";
      };
      logFile = lib.mkOption {
        type = safeLogPath;
        description = "Absolute Caddy JSON access-log path using only alphanumerics, slash, dot, underscore, plus, and hyphen; dot segments are rejected.";
      };
      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Native Caddy route fragment for this claim.";
      };
      extraConfigFragments = lib.mkOption {
        type = lib.types.listOf lib.types.lines;
        default = [ ];
        description = "Consumer fragments rendered after the primary route.";
      };
      siteAddress = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ ":443" ]);
        default = null;
        description = "Explicit listener-wide HTTPS site address supplied by a consumer.";
      };
      preRouteConfigFragments = lib.mkOption {
        type = lib.types.listOf lib.types.lines;
        default = [ ];
        description = "Consumer fragments rendered before the primary route.";
      };
      siteOwners = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Exactly one nonempty consumer ownership token when publicSite is true; otherwise empty.";
      };
      capabilities = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "forward-proxy" ]);
        default = [ ];
        description = "Exclusive listener capabilities; repeated declarations are rejected.";
      };
      requiresUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Consumer-owned systemd units required by Caddy.";
      };
      afterUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Consumer-owned systemd ordering dependencies for Caddy.";
      };
      wantsUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Consumer-owned systemd units wanted by Caddy.";
      };
      publicSite = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this claim is an approved public-site root for typed add-ons.";
      };
    };
  });

  contributionType = lib.types.submodule {
    options = {
      preRouteConfigFragments = lib.mkOption {
        type = lib.types.listOf lib.types.lines;
        default = [ ];
      };
      capabilities = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "forward-proxy" ]);
        default = [ ];
      };
      siteAddress = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ ":443" ]);
        default = null;
      };
      requiresUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Consumer-owned systemd units required by Caddy.";
      };
      afterUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      wantsUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };
  cfg = config.networkCore.caddy;
  unknownTargets = lib.filter (name: !(builtins.hasAttr name cfg.fragments)) (
    builtins.attrNames cfg.contributions
  );
  assembled = lib.mapAttrs (
    name: claim:
    if !(builtins.hasAttr name cfg.contributions) then
      claim
    else
      let
        contribution = cfg.contributions.${name};
      in
      claim
      // {
        preRouteConfigFragments = claim.preRouteConfigFragments ++ contribution.preRouteConfigFragments;
        capabilities = claim.capabilities ++ contribution.capabilities;
        siteAddress =
          if contribution.siteAddress == null then claim.siteAddress else contribution.siteAddress;
        requiresUnits = claim.requiresUnits ++ contribution.requiresUnits;
        afterUnits = claim.afterUnits ++ contribution.afterUnits;
        wantsUnits = claim.wantsUnits ++ contribution.wantsUnits;
      }
  ) cfg.fragments;
in
{
  options.networkCore.caddy = {
    contributions = lib.mkOption {
      type = lib.types.attrsOf contributionType;
      default = { };
      description = "Consumer contributions targeting existing site claims; cannot change hosts, listeners, or certificates.";
    };
    effectiveFragments = lib.mkOption {
      type = lib.types.attrsOf claimType;
      readOnly = true;
      apply = validateClaims true;
      description = "Validated assembly of site claims and consumer contributions.";
    };
    fragments = lib.mkOption {
      type = lib.types.attrsOf claimType;
      apply = validateClaims false;
      default = { };
      description = "Consumer-owned Caddy virtual-host declarations.";
    };
  };
  config.networkCore.caddy.effectiveFragments =
    if unknownTargets != [ ] then
      throw "Caddy contributions target absent claims: ${lib.concatStringsSep ", " unknownTargets}"
    else
      assembled;

}
