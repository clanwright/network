{
  self,
  inputs,
  pkgs,
  root,
  gate,
}:
let
  lib = inputs.nixpkgs.lib;
  consume = import ./consumer.nix { inherit self inputs root; };
  instances.certificates = {
    module = {
      input = "network";
      name = "@clanwright/network-certificates";
    };
    roles.server.machines.network-node.settings.email = "fixture@example.invalid";
  };
  base = {
    networkCore.acme = {
      certificateClaims.fixture.domain = "fixture.invalid";
      reloadServices.fixture = [ "fixture-consumer.service" ];
    };
  };
  wildcard = consume {
    instances = instances // {
      wildcard = {
        module = {
          input = "network";
          name = "@clanwright/edge-wildcard-certificate";
        };
        roles.certificate.machines.network-node.settings = {
          certName = "wildcard";
          domain = "fixture.invalid";
          extraDomainNames = [ "*.fixture.invalid" ];
        };
      };
    };
  };
  badReload = consume {
    inherit instances;
    extraModule.networkCore.acme.reloadServices.absent = [ "fixture.service" ];
  };
  ownerFixture =
    {
      explicitName ? "fixture",
      explicitOwner ? "service:A",
      explicitSource ? "A",
    }:
    consume {
      inherit instances;
      extraModule.networkCore.acme = {
        certificateClaims.fixture = {
          domain = "fixture.invalid";
          ownerToken = "service:A";
          sourceMarker = "A";
        };
        claimOwners = [
          {
            certName = explicitName;
            ownerToken = explicitOwner;
            sourceMarker = explicitSource;
          }
        ];
      };
    };
  matchingOwner = ownerFixture { };
  conflictingOwner = ownerFixture {
    explicitOwner = "service:B";
    explicitSource = "B";
  };
  conflictingSource = ownerFixture { explicitSource = "B"; };
  missingOwnedCertificate = ownerFixture { explicitName = "absent"; };
  production = consume {
    inherit instances;
    extraModule = base;
  };
  combinedInstances = instances // {
    caddy = {
      module = {
        input = "network";
        name = "@clanwright/network-caddy";
      };
      roles.ingress.machines.network-node.settings = { };
    };
  };
  combined = consume {
    instances = combinedInstances;
    extraModule = {
      imports = [ base ];
      # Deliberately duplicate the native Caddy registration to prove the
      # effective NixOS ACME option is deduplicated after module merging.
      networkCore.acme.reloadServices.fixture = [ "caddy.service" ];
      networkCore.caddy.fragments.fixture = {
        hostName = "fixture.invalid";
        useACMEHost = "fixture";
        logFile = "/tmp/network-acme-caddy.log";
        publicSite = false;
        listenAddresses = [ "127.0.0.1" ];
        siteOwners = [ ];
        extraConfig = ''respond "fixture"'';
      };
    };
  };
  fixture = consume {
    instances = combinedInstances;
    extraModule = { lib, ... }: {
      imports = [
        base
        {
          networkCore.acme.reloadServices.fixture = [ "caddy.service" ];
          networkCore.caddy.fragments.fixture = {
            hostName = "fixture.invalid";
            useACMEHost = "fixture";
            logFile = "/tmp/network-acme-caddy.log";
            publicSite = false;
            listenAddresses = [ "127.0.0.1" ];
            siteOwners = [ ];
            extraConfig = ''respond "fixture"'';
          };
        }
      ];
      # Local challenge transport only. The tested native scripts and the
      # package under test are identical to the production consumer.
      security.acme.certs.fixture = {
        dnsProvider = lib.mkForce null;
        credentialFiles = lib.mkForce { };
        dnsResolver = lib.mkForce null;
        server = "https://localhost:14000/dir";
        listenHTTP = "127.0.0.1:5002";
        validMinDays = 99999;
      };
    };
  };
  unit = fixture.machine.systemd.services.acme-order-renew-fixture;
  contract =
    production.valid
    && production.evaluated
    && production.machine.security.acme.certs.fixture.dnsProvider == "timewebcloud"
    && production.machine.security.acme.certs.fixture.reloadServices == [ "fixture-consumer.service" ]
    &&
      production.machine.security.acme.certs.fixture.credentialFiles.TIMEWEBCLOUD_AUTH_TOKEN_FILE
      == production.machine.sops.secrets.timeweb-dns-api-token.path;
  combinedContract =
    combined.valid
    && combined.evaluated
    && combined.machine.sops.secrets.timeweb-dns-api-token.owner == "acme"
    && combined.machine.sops.secrets.timeweb-dns-api-token.group == "acme"
    && combined.machine.sops.secrets.timeweb-dns-api-token.mode == "0400"
    && combined.machine.security.acme.certs.fixture.group == "acme"
    && builtins.elem "acme" combined.machine.users.users.caddy.extraGroups
    && builtins.length combined.machine.security.acme.certs.fixture.reloadServices == 2
    && builtins.elem "fixture-consumer.service" combined.machine.security.acme.certs.fixture.reloadServices
    && builtins.elem "caddy.service" combined.machine.security.acme.certs.fixture.reloadServices;
in
{
  consumer-wildcard = gate "network-consumer-wildcard" (
    wildcard.valid
    && wildcard.evaluated
    && wildcard.machine.security.acme.certs.wildcard.extraDomainNames == [ "*.fixture.invalid" ]
    && wildcard.machine.security.acme.certs.wildcard.reloadServices == [ ]
    && !wildcard.machine.services.caddy.enable
  );
  incompatible-certificate-reload = gate "network-incompatible-certificate-reload" (!badReload.valid);
  certificate-owner-consistency = gate "network-certificate-owner-consistency" (
    matchingOwner.valid
    && matchingOwner.evaluated
    && !conflictingOwner.valid
    && !conflictingSource.valid
    && !missingOwnedCertificate.valid
  );
  consumer-certificates = gate "network-consumer-certificates" contract;
  certificates-caddy-integration = gate "network-certificates-caddy-integration" combinedContract;
  acme-local-renewal =
    assert fixture.valid && fixture.evaluated;
    pkgs.runCommand "network-acme-local-renewal"
      {
        nativeBuildInputs = [
          pkgs.util-linux
          pkgs.iproute2
          pkgs.pebble
          pkgs.dnsmasq
          pkgs.openssl
          pkgs.curl
          pkgs.bash
          pkgs.diffutils
          self.packages.x86_64-linux.caddy-custom
          self.packages.x86_64-linux.lego
        ];
        ORDER_SCRIPT = pkgs.writeShellScript "native-acme-order" unit.script;
        POST_SCRIPT = lib.removePrefix "+" unit.serviceConfig.ExecStartPost;
        EXPECTED_RELOADS = lib.concatStringsSep " " fixture.machine.security.acme.certs.fixture.reloadServices;
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/acme-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
}
