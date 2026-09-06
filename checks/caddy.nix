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
          inherit (claim) capabilities preRouteConfigFragments;
          requiresUnits = [ "fixture-auth.service" ];
          afterUnits = [ "fixture-auth.service" ];
        };
      };
      systemd.services.fixture-auth = {
        serviceConfig.Type = "oneshot";
        script = "true";
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
in
{
  caddy-contribution-dependencies = gate "network-caddy-contribution-dependencies" (
    site.valid
    && site.evaluated
    && builtins.elem "fixture-auth.service" site.machine.systemd.services.caddy.requires
    && builtins.elem "fixture-auth.service" site.machine.systemd.services.caddy.after
    && site.machine.networkCore.caddy.effectiveFragments.vaultwarden.capabilities == [ "forward-proxy" ]
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
        openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out fullchain.pem -days 1 -subj /CN=vaultwarden.fixture.invalid 2> >(tee "$out/certificate-generation.log" >&2)
        cp fullchain.pem cert.pem
        cp ${site.machine.services.caddy.configFile} "$out/Caddyfile.original"
        sed "s|/var/lib/acme/fixture|$PWD|g" "$out/Caddyfile.original" > "$out/Caddyfile"
        caddy adapt --config "$out/Caddyfile" --adapter caddyfile > "$out/config.json" 2> >(tee "$out/adapt.log" >&2)
        grep -F '"handler":"rate_limit"' "$out/config.json"
        grep -F '"protocols":["h1","h2"]' "$out/config.json"
        caddy validate --config "$out/config.json" 2>&1 | tee "$out/validate.log"
      '';

  caddy-ratelimit-runtime =
    pkgs.runCommand "network-caddy-ratelimit-runtime"
      {
        nativeBuildInputs = [
          self.packages.x86_64-linux.caddy-custom
          pkgs.curl
          pkgs.gnugrep
        ];
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/caddy-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
}
