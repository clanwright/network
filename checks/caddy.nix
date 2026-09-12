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
  caddyInstance = instance "network-caddy" "ingress" { };
  claim = {
    hostName = "vaultwarden.fixture.invalid";
    listenAddresses = [ "127.0.0.1" ];
    useACMEHost = "fixture";
    logFile = "/tmp/network-vaultwarden-fixture-access.log";
    publicSite = true;
    siteOwners = [ "vaultwarden" ];
    capabilities = [ "forward-proxy" ];
    siteAddress = ":443";
    extraConfig = ''
      @vaultwardenAuth path /identity/connect/token /identity/accounts/prelogin /identity/accounts/register
      route @vaultwardenAuth {
        rate_limit {
          zone vaultwarden_auth_public {
            key {remote_host}
            events 14
            window 1m
          }
        }
        respond "vaultwarden auth fixture"
      }
      respond "vaultwarden fixture"
    '';
    preRouteConfigFragments = [
      ''
        forward_proxy {
          hide_ip
          hide_via
        }
      ''
    ];
  };
  site = consume {
    instances.caddy = caddyInstance;
    extraModule = {
      security.acme = {
        acceptTerms = true;
        defaults.email = "fixture@example.invalid";
        certs.fixture = {
          domain = "vaultwarden.fixture.invalid";
          webroot = "/tmp/acme-fixture";
        };
      };
      networkCore.caddy = {
        fragments.vaultwarden = claim // {
          capabilities = [ ];
          preRouteConfigFragments = [ ];
        };
        contributions.vaultwarden = {
          inherit (claim) capabilities siteAddress preRouteConfigFragments;
          requiresUnits = [ "fixture-auth.service" ];
          afterUnits = [ "fixture-auth.service" ];
        };
      };
      systemd.services.fixture-auth = {
        serviceConfig.Type = "oneshot";
        script = "true";
      };
      services.caddy = {
        globalConfig = lib.mkAfter "admin off";
        virtualHosts.vaultwarden = {
          hostName = lib.mkForce "https://vaultwarden.fixture.invalid:18080";
          useACMEHost = lib.mkForce null;
          extraConfig = lib.mkAfter ''
            tls /tmp/network-caddy-runtime-cert.pem /tmp/network-caddy-runtime-key.pem
          '';
        };
      };
    };
  };
  rejected =
    fixture:
    !(builtins.tryEval (builtins.deepSeq fixture.machine.networkCore.caddy.effectiveFragments true))
    .success;
  wildcardCollision =
    capability:
    consume {
      instances.caddy = caddyInstance;
      extraModule.networkCore.caddy.fragments = {
        wildcard = claim // {
          listenAddresses = [ "0.0.0.0" ];
          capabilities = lib.optional capability "forward-proxy";
        };
        specific = claim // {
          hostName = if capability then "other.fixture.invalid" else claim.hostName;
          listenAddresses = [ "192.0.2.1" ];
          capabilities = lib.optional capability "forward-proxy";
        };
      };
    };
  ownerlessPublicSite = consume {
    instances.caddy = caddyInstance;
    extraModule = {
      security.acme.certs.fixture = {
        domain = "vaultwarden.fixture.invalid";
        webroot = "/tmp/acme-fixture";
      };
      networkCore.caddy.fragments.vaultwarden = claim // {
        siteOwners = [ ];
        capabilities = [ ];
        preRouteConfigFragments = [ ];
      };
    };
  };
  incompleteForwardProxy =
    fragment: contribution:
    consume {
      instances.caddy = caddyInstance;
      extraModule = {
        security.acme = {
          acceptTerms = true;
          defaults.email = "fixture@example.invalid";
          certs.fixture = {
            domain = "vaultwarden.fixture.invalid";
            webroot = "/tmp/acme-fixture";
          };
        };
        networkCore.caddy = {
          fragments.vaultwarden =
            claim
            // {
              capabilities = [ ];
              siteAddress = null;
            }
            // fragment;
          contributions.vaultwarden = contribution;
        };
      };
    };
  completedForwardProxy = incompleteForwardProxy { capabilities = [ "forward-proxy" ]; } {
    siteAddress = ":443";
  };
  malformedLog =
    logFile:
    consume {
      instances.caddy = caddyInstance;
      extraModule = {
        security.acme.certs.fixture = {
          domain = "vaultwarden.fixture.invalid";
          webroot = "/tmp/acme-fixture";
        };
        networkCore.caddy.fragments.vaultwarden = claim // {
          inherit logFile;
          capabilities = [ ];
          siteAddress = null;
        };
      };
    };
in
{
  caddy-contribution-dependencies = gate "network-caddy-contribution-dependencies" (
    site.valid
    && site.evaluated
    && builtins.elem "fixture-auth.service" site.machine.systemd.services.caddy.requires
    && builtins.elem "fixture-auth.service" site.machine.systemd.services.caddy.after
    && site.machine.networkCore.caddy.effectiveFragments.vaultwarden.capabilities == [ "forward-proxy" ]
    && site.machine.networkCore.caddy.effectiveFragments.vaultwarden.siteAddress == ":443"
    && completedForwardProxy.valid
    && completedForwardProxy.evaluated
    && completedForwardProxy.machine.services.caddy.virtualHosts.vaultwarden.hostName == ":443"
    && rejected (incompleteForwardProxy { capabilities = [ "forward-proxy" ]; } { })
    && rejected (incompleteForwardProxy { siteAddress = ":443"; } { })
    && rejected (incompleteForwardProxy { } { capabilities = [ "forward-proxy" ]; })
    && rejected (incompleteForwardProxy { } { siteAddress = ":443"; })
    && builtins.all (value: rejected (malformedLog value)) [
      "relative.log"
      "/tmp/with space.log"
      "/tmp/with\nnewline.log"
      "/tmp/%n.log"
      "/tmp/{env}.log"
      "/tmp/../escaped.log"
      "/tmp/./dot.log"
      "/tmp//empty.log"
      "/tmp/trailing/"
      "/tmp/quote\".log"
      "/tmp/backslash\\.log"
      "/tmp/semi;colon.log"
    ]
  );

  caddy-wildcard-listener-collisions = gate "network-caddy-wildcard-listener-collisions" (
    rejected (wildcardCollision false) && rejected (wildcardCollision true)
  );

  caddy-public-site-owner = gate "network-caddy-public-site-owner" (rejected ownerlessPublicSite);

  caddy-module-inventory =
    pkgs.runCommand "network-caddy-module-inventory"
      {
        nativeBuildInputs = [ self.packages.x86_64-linux.caddy-custom ];
      }
      ''
        mkdir -p "$out"
        caddy list-modules 2>&1 | tee "$out/modules.log"
        grep -Fx 'http.handlers.forward_proxy' "$out/modules.log"
        grep -Fx 'http.handlers.rate_limit' "$out/modules.log"
        if grep -Eq '^layer4([.]|$)' "$out/modules.log"; then
          echo "unexpected caddy-l4 module" >&2
          exit 1
        fi
      '';

  caddy-config =
    assert site.valid && site.evaluated;
    pkgs.runCommand "network-caddy-config"
      {
        nativeBuildInputs = [
          pkgs.openssl
          self.packages.x86_64-linux.caddy-custom
        ];
      }
      ''
        mkdir -p "$out"
        openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/network-caddy-runtime-key.pem -out /tmp/network-caddy-runtime-cert.pem -days 1 -subj /CN=vaultwarden.fixture.invalid 2> >(tee "$out/certificate-generation.log" >&2)
        cp ${site.machine.services.caddy.configFile} "$out/Caddyfile.original"
        caddy adapt --config "$out/Caddyfile.original" --adapter caddyfile > "$out/config.json" 2> >(tee "$out/adapt.log" >&2)
        grep -F 'https://vaultwarden.fixture.invalid:18080' "$out/Caddyfile.original"
        grep -F 'forward_proxy' "$out/Caddyfile.original"
        grep -F '"handler":"rate_limit"' "$out/config.json"
        grep -F '"handler":"forward_proxy"' "$out/config.json"
        grep -F '"protocols":["h1","h2"]' "$out/config.json"
        caddy validate --config "$out/config.json" 2>&1 | tee "$out/validate.log"
        rm -f /tmp/network-caddy-runtime-key.pem /tmp/network-caddy-runtime-cert.pem
      '';

  caddy-ratelimit-runtime =
    pkgs.runCommand "network-caddy-ratelimit-runtime"
      {
        nativeBuildInputs = [
          self.packages.x86_64-linux.caddy-custom
          pkgs.curl
          pkgs.gnugrep
          pkgs.iproute2
          pkgs.openssl
          pkgs.util-linux
        ];
      }
      ''
        mkdir -p "$out"
        export out
        export CADDY_CONFIG=${site.machine.services.caddy.configFile}
        bash ${../tests/caddy-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
}
