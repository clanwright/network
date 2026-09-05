{ settings, self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  mkAcmeIpv4Override = {
    after = [
      "network-online.target"
      "nss-lookup.target"
    ];
    wants = [
      "network-online.target"
      "nss-lookup.target"
    ];
    unitConfig = {
      StartLimitIntervalSec = lib.mkForce "1h";
      StartLimitBurst = lib.mkForce 5;
    };
    serviceConfig = {
      RestrictAddressFamilies = lib.mkForce [
        "AF_INET"
        "AF_UNIX"
        "AF_NETLINK"
      ];
      IPAddressDeny = lib.mkForce [ "::/0" ];
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce "2min";
      TimeoutStartSec = lib.mkForce "20min";
      SuccessExitStatus = lib.mkForce [
        10
        11
      ];
    };
    environment = {
      GODEBUG = "ipv6=0";
      TIMEWEBCLOUD_HTTP_TIMEOUT = "60";
      TIMEWEBCLOUD_PROPAGATION_TIMEOUT = "600";
      TIMEWEBCLOUD_POLLING_INTERVAL = "15";
    };
  };
  claims = config.networkCore.acme.certificateClaims;
  explicitOwners = config.networkCore.acme.claimOwners;
  ownedNames = map (x: x.certName) explicitOwners;
  owners =
    explicitOwners
    ++ lib.filter (x: x.ownerToken != null && !(builtins.elem x.certName ownedNames)) (
      lib.mapAttrsToList (certName: claim: {
        inherit certName;
        inherit (claim) ownerToken sourceMarker;
      }) claims
    );
  duplicate = xs: builtins.length xs != builtins.length (lib.unique xs);
  package = self.packages.x86_64-linux.lego;
in
{
  imports = [ ./claims.nix ];
  options.networkCore.acme.reloadServices = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    default = { };
    description = "Consumer-owned renewal notification units keyed by certificate name.";
  };
  config = {
    assertions = [
      {
        assertion = builtins.all (
          owner:
          builtins.hasAttr owner.certName claims
          && (
            claims.${owner.certName}.ownerToken == null
            || (
              claims.${owner.certName}.ownerToken == owner.ownerToken
              && claims.${owner.certName}.sourceMarker == owner.sourceMarker
            )
          )
        ) explicitOwners;
        message = "Explicit certificate ownership must match its declared certificate owner.";
      }
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "network-certificates supports x86_64-linux only.";
      }
      {
        assertion = !duplicate (map (x: x.certName) owners) && !duplicate (map (x: x.ownerToken) owners);
        message = "Certificate ownership must be unique.";
      }
      {
        assertion = builtins.all (name: builtins.hasAttr name claims) (
          builtins.attrNames config.networkCore.acme.reloadServices
        );
        message = "A renewal consumer refers to an undeclared certificate.";
      }
      {
        assertion = pkgs.lego.outPath == package.outPath;
        message = "Network owns the exact Lego package; consumer overrides are unsupported.";
      }
    ];
    networkCore.acme.evaluatedOwners = owners;
    nixpkgs.overlays = [ (_final: _previous: { lego = package; }) ];
    sops.secrets.${settings.secretName} = {
      owner = "acme";
      group = "acme";
      mode = "0440";
    };
    security.acme = {
      acceptTerms = true;
      defaults = { inherit (settings) email dnsResolver; };
      certs = lib.mapAttrs (name: claim: {
        inherit (claim) domain extraDomainNames;
        dnsProvider = "timewebcloud";
        dnsPropagationCheck = true;
        inherit (settings) dnsResolver;
        credentialFiles.TIMEWEBCLOUD_AUTH_TOKEN_FILE = config.sops.secrets.${settings.secretName}.path;
        group = "acme";
        reloadServices = lib.unique (config.networkCore.acme.reloadServices.${name} or [ ]);
      }) claims;
    };
    systemd.services = lib.genAttrs (map (name: "acme-order-renew-${name}") (
      builtins.attrNames claims
    )) (_: mkAcmeIpv4Override);
  };
}
