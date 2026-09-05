{
  self,
  inputs,
  pkgs,
  root,
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
  fixture = consume {
    inherit instances;
    extraModule = { lib, ... }: {
      imports = [ base ];
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
in
{
  consumer-wildcard =
    assert
      wildcard.valid
      && wildcard.evaluated
      && wildcard.machine.security.acme.certs.wildcard.extraDomainNames == [ "*.fixture.invalid" ]
      && wildcard.machine.security.acme.certs.wildcard.reloadServices == [ ]
      && !wildcard.machine.services.caddy.enable;
    pkgs.runCommand "network-consumer-wildcard" { } ''touch "$out"'';
  incompatible-certificate-reload =
    assert !badReload.valid;
    pkgs.runCommand "network-incompatible-certificate-reload" { } ''touch "$out"'';
  certificate-owner-consistency =
    assert
      matchingOwner.valid
      && matchingOwner.evaluated
      && !conflictingOwner.valid
      && !conflictingSource.valid
      && !missingOwnedCertificate.valid;
    pkgs.runCommand "network-certificate-owner-consistency" { } ''touch "$out"'';
  consumer-certificates =
    assert contract;
    pkgs.runCommand "network-consumer-certificates" { } ''touch "$out"'';
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
          self.packages.x86_64-linux.lego
        ];
        ORDER_SCRIPT = pkgs.writeShellScript "native-acme-order" unit.script;
        POST_SCRIPT = lib.removePrefix "+" unit.serviceConfig.ExecStartPost;
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/acme-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
}
