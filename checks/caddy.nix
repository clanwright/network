{
  self,
  inputs,
  pkgs,
  consume,
  instance,
  gate,
}:
let
  lib = inputs.nixpkgs.lib;
  package = self.packages.x86_64-linux.caddy-custom;
  networkModule = import ../clanServices/caddy/module.nix { inherit package; };
  nativeModule = import (inputs.nixpkgs + "/nixos/modules/services/web-servers/caddy/default.nix");
  types = import ../lib/types.nix { inherit lib; };
  # Reuse upstream option declarations, without evaluating an unrelated host
  # closure for each owner, listener, or type error. Rendering is tested below
  # from an actual catalog consumer, never from this narrow fixture.
  evaluate =
    modules:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        ({ config, options, ... }: {
          options =
            (nativeModule {
              inherit
                config
                options
                lib
                pkgs
                ;
            }).options
            // {
              assertions = lib.mkOption {
                type = lib.types.listOf lib.types.unspecified;
                default = [ ];
              };
              users.users = lib.mkOption {
                type = lib.types.attrsOf lib.types.unspecified;
                default = { };
              };
              security.acme.certs = lib.mkOption {
                type = lib.types.attrsOf lib.types.unspecified;
                default = { };
              };
            };
        })
        networkModule
      ]
      ++ modules;
    };
  site = {
    owner = "fixture:base";
    serverAliases = [ "alias.fixture.invalid" ];
    listenAddresses = [ "192.0.2.1" ];
    extraConfig = "route { respond base }";
  };
  base.services.caddy.virtualHosts."www.fixture.invalid" = site;
  good = evaluate [ base ];
  attempt = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  accepted =
    result:
    attempt (
      assert builtins.all (a: a.assertion) result.config.assertions;
      result.config.services.caddy.virtualHosts
    );
  rejected = modules: !accepted (evaluate modules);
  replace = value: { services.caddy.virtualHosts."www.fixture.invalid" = site // value; };
  other = name: value: {
    services.caddy.virtualHosts.${name} =
      site
      // {
        owner = "fixture:other";
        serverAliases = [ ];
      }
      // value;
  };
  collision =
    value:
    rejected [
      base
      (other "alias.fixture.invalid" value)
    ];
  invalidDNS = [
    ""
    "UPPER.invalid"
    "site.invalid."
    "127.0.0.1"
    ":443"
    "*.invalid"
    "site:443"
    "https://site.invalid"
    "one,two"
    "bad_name.invalid"
    "-host.invalid"
    "host-.invalid"
  ];
  ordered = evaluate [
    base
    ({ config, lib, ... }: {
      services.caddy.virtualHosts."www.fixture.invalid".extraConfig = lib.mkBefore ''
        route {
          @alias host ${
            lib.concatStringsSep " " config.services.caddy.virtualHosts."www.fixture.invalid".serverAliases
          }
          respond @alias extension
        }
      '';
    })
  ];
  runtime = consume {
    instances.caddy = instance "network-caddy" "ingress" { };
    extraModule = { lib, ... }: {
      services.caddy = {
        globalConfig = lib.mkAfter "admin unix//tmp/network-caddy-admin.sock";
        virtualHosts = {
          "vaultwarden.fixture.invalid" = {
            owner = "fixture:ratelimit";
            listenAddresses = [ "127.0.0.1" ];
            extraConfig = ''
              tls /tmp/network-caddy-runtime-cert.pem /tmp/network-caddy-runtime-key.pem
              route {
                @auth path /identity/connect/token /identity/accounts/prelogin /identity/accounts/register
                handle @auth {
                  rate_limit {
                    zone fixture_auth {
                      key {remote_host}
                      events 14
                      window 1m
                    }
                  }
                  respond "vaultwarden auth fixture"
                }
                @private path /fail/* /ok/*
                log_skip @private
                respond /ok/* ok 200
                error /fail/* "first {http.request.uri}" 500
                respond "vaultwarden fixture"
              }
            '';
          };
          "nested.fixture.invalid" = {
            owner = "fixture:nested-errors";
            # A distinct native server keeps this host's error route from
            # handling another host's error at DEBUG level. Both native error
            # paths must actually emit records for the encoder controls.
            listenAddresses = [ "127.0.0.2" ];
            extraConfig = ''
              tls /tmp/network-caddy-runtime-cert.pem /tmp/network-caddy-runtime-key.pem
              route {
                log_skip
                respond /ok/* ok 200
                error "first {http.request.uri}" 500
              }
              handle_errors {
                error "second {http.request.uri}" 502
              }
            '';
          };
        };
      };
      systemd.services = {
        caddy.requires = [ "fixture-auth.service" ];
        caddy.after = [ "fixture-auth.service" ];
        fixture-auth = {
          serviceConfig.Type = "oneshot";
          script = "true";
        };
      };
    };
  };
in
{
  caddy-native-contracts = gate "network-caddy-native-contracts" (
    accepted good
    && builtins.all (value: rejected [ (replace value) ]) [
      { owner = ""; }
      { owner = "two owners"; }
      {
        serverAliases = [
          "alias.fixture.invalid"
          "alias.fixture.invalid"
        ];
      }
      { serverAliases = [ "www.fixture.invalid" ]; }
      { serverAliases = [ "UPPER.invalid" ]; }
      { listenAddresses = [ "192.0.2.256" ]; }
    ]
    && rejected [ { services.caddy.virtualHosts."orphan.invalid".extraConfig = "respond orphan"; } ]
    && rejected [
      base
      { services.caddy.virtualHosts."www.fixture.invalid".owner = "fixture:base"; }
    ]
    && rejected [
      base
      { services.caddy.virtualHosts."www.fixture.invalid".owner = "fixture:other"; }
    ]
    && builtins.all (name: rejected [ (other name { }) ]) invalidDNS
    && !types.dnsName.check (
      lib.concatStringsSep "." (lib.replicate 5 (lib.concatStrings (lib.replicate 60 "a")))
    )
    && !types.dnsName.check ((lib.concatStrings (lib.replicate 64 "a")) + ".invalid")
    && types.dnsName.check (
      lib.concatStringsSep "." (
        map (size: lib.concatStrings (lib.replicate size "a")) [
          63
          63
          63
          61
        ]
      )
    )
    && builtins.all types.ipv4.check [
      "0.0.0.0"
      "127.0.0.1"
      "255.255.255.255"
    ]
    && builtins.all (address: !types.ipv4.check address) [
      "192.0.2.256"
      "192.0.2.-1"
      "192.0.2.01"
      "192.0.2"
      "::1"
    ]
    && collision { }
    && collision { listenAddresses = [ ]; }
    && collision { listenAddresses = [ "0.0.0.0" ]; }
    && accepted (evaluate [
      base
      (other "alias.fixture.invalid" { listenAddresses = [ "192.0.2.2" ]; })
    ])
    && rejected [
      base
      { services.caddy.virtualHosts."www.fixture.invalid".hostName = lib.mkForce ":443"; }
    ]
    &&
      (evaluate [
        base
        { services.caddy.virtualHosts."www.fixture.invalid".forwardProxy = true; }
      ]).config.services.caddy.virtualHosts."www.fixture.invalid".hostName == ":443"
    && accepted (evaluate [
      base
      { services.caddy.httpsPort = 8443; }
    ])
    && rejected [
      (replace { forwardProxy = true; })
      { services.caddy.httpsPort = 8443; }
    ]
    && rejected [
      base
      { services.caddy.virtualHosts."www.fixture.invalid".forwardProxy = true; }
      { services.caddy.virtualHosts."www.fixture.invalid".forwardProxy = true; }
    ]
    && rejected [
      (replace { forwardProxy = true; })
      (other "other.invalid" { forwardProxy = true; })
    ]
    && accepted (evaluate [
      (replace { forwardProxy = true; })
      (other "other.invalid" {
        forwardProxy = true;
        listenAddresses = [ "192.0.2.2" ];
      })
    ])
    && accepted ordered
    &&
      lib.hasPrefix "route {"
        ordered.config.services.caddy.virtualHosts."www.fixture.invalid".extraConfig
    &&
      builtins.all
        (
          value:
          rejected [
            base
            { services.caddy = value; }
          ]
        )
        [
          { settings.apps.http = { }; }
          { extraConfig = "hidden.invalid { respond bypass }"; }
          { configFile = "/tmp/bypass"; }
          { configFile = lib.mkForce "/tmp/bypass"; }
          { adapter = lib.mkForce null; }
          { resume = true; }
          { globalConfig = lib.mkForce "admin off"; }
          { logFormat = lib.mkForce "output stderr\nformat json"; }
          { package = lib.mkForce pkgs.caddy; }
        ]
    &&
      good.config.services.caddy.virtualHosts."www.fixture.invalid".logFormat
      == "output stderr\nformat json\n"
    && accepted (evaluate [ (replace { logFormat = null; }) ])
    && runtime.valid
    && runtime.evaluated
    && builtins.elem "fixture-auth.service" runtime.machine.systemd.services.caddy.requires
    && builtins.elem "fixture-auth.service" runtime.machine.systemd.services.caddy.after
    && builtins.head runtime.machine.systemd.services.caddy.serviceConfig.ExecReload == ""
    && runtime.machine.systemd.services.caddy.serviceConfig.Restart == "on-failure"
  );
  caddy-module-inventory =
    pkgs.runCommand "network-caddy-module-inventory"
      {
        nativeBuildInputs = [ package ];
      }
      ''
        mkdir -p "$out"
        caddy list-modules 2>&1 | tee "$out/modules.log"
        grep -Fx 'http.handlers.forward_proxy' "$out/modules.log"
        grep -Fx 'http.handlers.rate_limit' "$out/modules.log"
        if grep -Eq '^layer4([.]|$)' "$out/modules.log"; then exit 1; fi
      '';
  caddy-runtime =
    assert runtime.valid && runtime.evaluated;
    pkgs.runCommand "network-caddy-runtime"
      {
        nativeBuildInputs = [
          package
          pkgs.curl
          pkgs.gnugrep
          pkgs.iproute2
          pkgs.openssl
          pkgs.util-linux
          pkgs.jq
        ];
        CADDY_CONFIG = runtime.machine.services.caddy.configFile;
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/caddy-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
}
