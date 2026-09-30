{ settings }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  credentialPath = config.sops.secrets.${settings.secretName}.path;
  challengeDefaults = [
    "dnsProvider"
    "webroot"
    "listenHTTP"
  ];
  timewebCertificates = lib.filterAttrs (
    _: certificate: certificate.dnsProvider == "timewebcloud"
  ) config.security.acme.certs;
in
{
  # Extend native certificate submodules instead of reconstructing the merged
  # certificate map: domain scalars and SAN/reader lists retain native semantics.
  options.security.acme.certs = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }: {
          config = lib.mkIf (config.dnsProvider == "timewebcloud") {
            credentialFiles.TIMEWEBCLOUD_AUTH_TOKEN_FILE = credentialPath;
          };
        }
      )
    );
  };

  config = {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "network-certificates supports x86_64-linux only.";
      }
      {
        assertion = builtins.all (name: config.security.acme.defaults.${name} == null) challengeDefaults;
        message = "network-certificates requires null host-wide ACME challenge defaults; each certificate must explicitly select its challenge.";
      }
    ];
    sops.secrets = lib.mkIf (timewebCertificates != { }) {
      ${settings.secretName} = {
        owner = "acme";
        group = "acme";
        mode = "0400";
      };
    };
    security.acme = {
      acceptTerms = true;
      defaults = {
        inherit (settings) email dnsResolver;
        dnsProvider = null;
        webroot = null;
        listenHTTP = null;
      };
    };
    # Preserve the documented Timeweb IPv4 policy only for selected certificates.
    # Native ACME retains its own retry, failure, timeout and start-limit policy.
    systemd.services = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "acme-order-renew-${name}" {
        serviceConfig = {
          RestrictAddressFamilies = lib.mkForce [
            "AF_INET"
            "AF_UNIX"
            "AF_NETLINK"
          ];
          IPAddressDeny = [ "::/0" ];
        };
      }
    ) timewebCertificates;
  };
}
