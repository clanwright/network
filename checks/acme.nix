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
  settings = {
    email = "fixture@example.invalid";
    secretName = "timeweb-dns-api-token";
    dnsResolver = "1.1.1.1:53";
  };
  networkModule = import ../clanServices/certificates/module.nix { inherit settings; };
  nativeModule = import (inputs.nixpkgs + "/nixos/modules/security/acme/default.nix");
  # Native certificate options own defaults, identity, scalar/list merging and
  # read-only directory semantics. Narrow negatives cannot fail due to an
  # unrelated host filesystem or package closure.
  evaluate =
    modules:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        ({ config, ... }: {
          options = (nativeModule { inherit config lib pkgs; }).options // {
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.unspecified;
              default = [ ];
            };
            systemd.services = lib.mkOption {
              type = lib.types.attrsOf lib.types.unspecified;
              default = { };
            };
            sops.secrets = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (
                lib.types.submodule (
                  { name, ... }: {
                    options = {
                      owner = lib.mkOption { type = lib.types.str; };
                      group = lib.mkOption { type = lib.types.str; };
                      mode = lib.mkOption { type = lib.types.str; };
                      path = lib.mkOption {
                        type = lib.types.str;
                        default = "/run/secrets/${name}";
                      };
                    };
                  }
                )
              );
            };
          };
        })
        networkModule
      ]
      ++ modules;
    };
  attempt = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  cert = {
    domain = "fixture.invalid";
    dnsProvider = "timewebcloud";
    group = "acme";
  };
  declaration.security.acme.certs.stable-id = cert // {
    extraDomainNames = [ "*.fixture.invalid" ];
    reloadServices = [ "fixture-consumer.service" ];
  };
  good = evaluate [ declaration ];
  noCertificates = evaluate [ ];
  external = evaluate [ { security.acme.certs.external.dnsProvider = "synthetic"; } ];
  merged = evaluate [
    {
      security.acme.certs.stable-id = cert // {
        extraDomainNames = [ "one.fixture.invalid" ];
        reloadServices = [ "reader.service" ];
      };
    }
    {
      security.acme.certs.stable-id = cert // {
        extraDomainNames = [ "two.fixture.invalid" ];
        reloadServices = [ "reader.service" ];
      };
    }
  ];
  # These are the upstream module's own assertion records, not a copied
  # challenge predicate. In this pinned module the first merge contains them.
  nativeFailures =
    evaluated:
    let
      native = nativeModule {
        inherit lib pkgs;
        inherit (evaluated) config;
      };
    in
    lib.filter (a: !a.assertion) (builtins.head native.config.contents).content.assertions;
  implicit = evaluate [ { security.acme.certs.reload-only.reloadServices = [ "reader.service" ]; } ];
  conflictingChallenge = evaluate [
    {
      security.acme.certs.fixture = cert // {
        webroot = "/tmp/challenges";
      };
    }
  ];
  hostDefault = evaluate [ { security.acme.defaults.dnsProvider = lib.mkForce "timewebcloud"; } ];
  instances.certificates = {
    module = {
      input = "network";
      name = "@clanwright/network-certificates";
    };
    roles.server.machines.network-node.settings = settings;
  };
  production = consume {
    inherit instances;
    extraModule = declaration;
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
  base = {
    imports = [ declaration ];
    security.acme.certs.external = {
      dnsProvider = "synthetic";
      credentialFiles.EXTERNAL_TOKEN_FILE = "/run/secrets/external-token";
      reloadServices = [
        "external.service"
        "external.service"
      ];
    };
    services.caddy.virtualHosts."fixture.invalid" = {
      owner = "fixture:reader";
      listenAddresses = [ "127.0.0.1" ];
      useACMEHost = "stable-id";
      extraConfig = "route { respond fixture }";
    };
  };
  combined = consume {
    instances = combinedInstances;
    extraModule = base;
  };
  missingReader = consume {
    instances = combinedInstances;
    extraModule = { lib, ... }: {
      imports = [ base ];
      services.caddy.virtualHosts."fixture.invalid".useACMEHost = lib.mkForce "missing-native-id";
    };
  };
  # Compare native retry/start-limit policy and external units against the exact
  # same host module/package pair without Network's selected-provider additions.
  native = import (inputs.nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      {
        imports = [ declaration ];
        system.stateVersion = "26.11";
        security.acme = {
          acceptTerms = true;
          defaults = { inherit (settings) email dnsResolver; };
          certs = { inherit (base.security.acme.certs) external; };
        };
      }
    ];
  };
  unit = combined.machine.systemd.services.acme-order-renew-stable-id;
  nativeUnit = native.config.systemd.services.acme-order-renew-stable-id;
  policy = service: {
    serviceConfig = lib.filterAttrs (
      name: _:
      builtins.elem name [
        "Restart"
        "RestartSec"
        "SuccessExitStatus"
        "TimeoutStartSec"
      ]
    ) service.serviceConfig;
    inherit (service) unitConfig;
  };
  renewal = consume {
    instances = combinedInstances;
    extraModule = { lib, ... }: {
      imports = [ base ];
      services.caddy = {
        httpsPort = 8443;
        globalConfig = lib.mkAfter "admin unix//tmp/network-acme-admin.sock";
      };
      security.acme.certs.stable-id = {
        dnsProvider = lib.mkForce null;
        credentialFiles = lib.mkForce { };
        dnsResolver = lib.mkForce null;
        # The local HTTP-01 transport cannot issue wildcard SANs. Native
        # wildcard declaration/identity semantics are covered above.
        extraDomainNames = lib.mkForce [ ];
        server = "https://localhost:14000/dir";
        listenHTTP = "127.0.0.1:5002";
        validMinDays = 99999;
      };
    };
  };
  renewalUnit = renewal.machine.systemd.services.acme-order-renew-stable-id;
in
{
  certificate-native-contracts = gate "network-certificate-native-contracts" (
    nativeFailures good == [ ]
    && builtins.all (a: a.assertion) good.config.assertions
    && good.config.security.acme.certs.stable-id.directory == "/var/lib/acme/stable-id"
    && good.config.security.acme.certs.stable-id.extraDomainNames == [ "*.fixture.invalid" ]
    && good.config.security.acme.certs.stable-id.s3Bucket == null
    && builtins.all (name: good.config.security.acme.defaults.${name} == null) [
      "dnsProvider"
      "webroot"
      "listenHTTP"
    ]
    && !(
      good.options.security.acme.defaults.type.getSubOptions [
        "security"
        "acme"
        "defaults"
      ]
      ? s3Bucket
    )
    && noCertificates.config.sops.secrets == { }
    && external.config.sops.secrets == { }
    && merged.config.security.acme.certs.stable-id.domain == "fixture.invalid"
    &&
      merged.config.security.acme.certs.stable-id.extraDomainNames == [
        "one.fixture.invalid"
        "two.fixture.invalid"
      ]
    &&
      merged.config.security.acme.certs.stable-id.reloadServices == [
        "reader.service"
        "reader.service"
      ]
    && !attempt
      (evaluate [
        declaration
        { security.acme.certs.stable-id.domain = "other.invalid"; }
      ]).config.security.acme.certs.stable-id.domain
    && !attempt
      (evaluate [
        declaration
        { security.acme.certs.stable-id.directory = "/tmp/renamed"; }
      ]).config.security.acme.certs.stable-id.directory
    && builtins.length (nativeFailures implicit) == 1
    && lib.hasInfix "Exactly one of the options" (builtins.head (nativeFailures implicit)).message
    && builtins.length (nativeFailures conflictingChallenge) == 1
    && builtins.any (
      a: !a.assertion && lib.hasPrefix "network-certificates requires null" a.message
    ) hostDefault.config.assertions
    && !attempt
      (evaluate [ { security.acme.defaults.webroot = "/tmp/challenges"; } ])
      .config.security.acme.defaults.webroot
    &&
      builtins.length (nativeFailures (evaluate [ { security.acme.certs."*.fixture.invalid" = cert; } ]))
      == 1
  );
  consumer-certificates = gate "network-consumer-certificates" (
    production.valid
    && production.evaluated
    && !production.machine.services.caddy.enable
    && production.machine.security.acme.certs.stable-id.dnsProvider == "timewebcloud"
    && production.machine.security.acme.certs.stable-id.reloadServices == [ "fixture-consumer.service" ]
    &&
      production.machine.security.acme.certs.stable-id.credentialFiles.TIMEWEBCLOUD_AUTH_TOKEN_FILE
      == production.machine.sops.secrets.timeweb-dns-api-token.path
  );
  certificates-caddy-integration = gate "network-certificates-caddy-integration" (
    combined.valid
    && combined.evaluated
    && combined.machine.sops.secrets.timeweb-dns-api-token.owner == "acme"
    && combined.machine.sops.secrets.timeweb-dns-api-token.group == "acme"
    && combined.machine.sops.secrets.timeweb-dns-api-token.mode == "0400"
    && combined.machine.security.acme.certs.stable-id.group == "acme"
    && builtins.elem "acme" combined.machine.users.users.caddy.extraGroups
    && builtins.length combined.machine.security.acme.certs.stable-id.reloadServices == 2
    && builtins.elem "fixture-consumer.service" combined.machine.security.acme.certs.stable-id.reloadServices
    && builtins.elem "caddy.service" combined.machine.security.acme.certs.stable-id.reloadServices
    &&
      combined.machine.security.acme.certs.external.reloadServices == [
        "external.service"
        "external.service"
      ]
    && builtins.any (
      a:
      !a.assertion
      && lib.hasInfix "Exactly one of the options" a.message
      && lib.hasInfix "security.acme.certs.missing-native-id.dnsProvider" a.message
    ) missingReader.machine.assertions
    && policy unit == policy nativeUnit
    &&
      combined.machine.systemd.services.acme-order-renew-external.serviceConfig
      == native.config.systemd.services.acme-order-renew-external.serviceConfig
    &&
      unit.serviceConfig.RestrictAddressFamilies == [
        "AF_INET"
        "AF_UNIX"
        "AF_NETLINK"
      ]
    && unit.serviceConfig.IPAddressDeny == [ "::/0" ]
    && !(unit.environment ? GODEBUG)
    && !(unit.environment ? TIMEWEBCLOUD_HTTP_TIMEOUT)
  );
  acme-local-renewal =
    assert renewal.valid && renewal.evaluated;
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
          pkgs.lego
        ];
        ORDER_SCRIPT = pkgs.writeShellScript "native-acme-order" renewalUnit.script;
        POST_SCRIPT = lib.removePrefix "+" renewalUnit.serviceConfig.ExecStartPost;
        CADDY_CONFIG = renewal.machine.services.caddy.configFile;
        EXPECTED_RELOADS = lib.concatStringsSep " " renewal.machine.security.acme.certs.stable-id.reloadServices;
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/acme-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
}
