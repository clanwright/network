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
  artifact = pkgs.runCommand "network-static-site-fixture" { } ''
    mkdir -p "$out/docs"
    printf '%s\n' 'network static index v1' > "$out/index.html"
    printf '%s\n' 'network static document v1' > "$out/docs/page.html"
    printf '%s\n' 'network custom missing page' > "$out/404.html"
  '';
  replacement = pkgs.runCommand "network-static-site-replacement" { } ''
    mkdir -p "$out"
    printf '%s\n' 'network static index v2' > "$out/index.html"
  '';
  caddy = instance "network-caddy" "ingress" { };
  settings = {
    claimName = "main-site";
    hostName = "www.fixture.invalid";
    serverAliases = [ "alias.fixture.invalid" ];
    artifact = "${artifact}";
    useACMEHost = "fixture";
    listenAddresses = [ "127.0.0.1" ];
    publicSite = true;
  };
  staticSite = value: instance "network-static-site" "site" value;
  certificates = {
    security.acme = {
      acceptTerms = true;
      defaults.email = "fixture@example.invalid";
      certs.fixture = {
        domain = "www.fixture.invalid";
        webroot = "/tmp/acme-fixture";
      };
    };
  };
  withSites =
    {
      primary ? settings,
      secondary ? null,
      ingress ? true,
      extraModule ? { },
    }:
    consume {
      instances =
        (lib.optionalAttrs ingress { inherit caddy; })
        // {
          primary = staticSite primary;
        }
        // (lib.optionalAttrs (secondary != null) { secondary = staticSite secondary; });
      extraModule.imports = [
        certificates
        extraModule
      ];
    };
  secondarySettings = settings // {
    claimName = "secondary-site";
    hostName = "secondary.fixture.invalid";
    serverAliases = [ ];
    publicSite = false;
  };
  evaluated = withSites { secondary = secondarySettings; };
  rejected =
    fixture:
    !(builtins.tryEval (builtins.deepSeq fixture.machine.system.build.toplevel.drvPath true)).success;
  invalidSetting =
    override:
    rejected (withSites {
      primary = settings // override;
    });
  runtime = withSites {
    secondary = secondarySettings // {
      artifact = "${replacement}";
    };
    extraModule = {
      networkCore.caddy.contributions."main-site" = {
        capabilities = [ "forward-proxy" ];
        siteAddress = ":443";
        preRouteConfigFragments = [
          ''
            forward_proxy {
              hide_ip
              hide_via
            }
          ''
        ];
      };
      services.caddy = {
        globalConfig = lib.mkAfter "admin off";
        virtualHosts."main-site" = {
          useACMEHost = lib.mkForce null;
          extraConfig = lib.mkAfter ''
            tls /tmp/network-static-site-cert.pem /tmp/network-static-site-key.pem
          '';
        };
        virtualHosts."secondary-site" = {
          useACMEHost = lib.mkForce null;
          extraConfig = lib.mkAfter ''
            tls /tmp/network-static-site-cert.pem /tmp/network-static-site-key.pem
          '';
        };
      };
    };
  };
in
{
  consumer-static-site = gate "network-consumer-static-site" (
    evaluated.valid
    && evaluated.evaluated
    && evaluated.machine.services.caddy.enable
    && evaluated.machine.services.caddy.package == self.packages.x86_64-linux.caddy-custom
    && builtins.hasAttr "main-site" evaluated.machine.networkCore.caddy.effectiveFragments
    && builtins.hasAttr "secondary-site" evaluated.machine.networkCore.caddy.effectiveFragments
    && evaluated.machine.networkCore.caddy.effectiveFragments."main-site".publicSite
    && evaluated.machine.networkCore.caddy.effectiveFragments."main-site".siteOwners != [ ]
    && !evaluated.machine.networkCore.caddy.effectiveFragments."secondary-site".publicSite
    && evaluated.machine.networkCore.caddy.effectiveFragments."secondary-site".siteOwners == [ ]
    &&
      evaluated.machine.networkCore.caddy.effectiveFragments."main-site".logFile
      == "/var/log/caddy/main-site.log"
    &&
      builtins.getContext evaluated.machine.networkCore.caddy.effectiveFragments."main-site".extraConfig
      != { }
    && rejected (withSites {
      ingress = false;
    })
  );

  static-site-contracts = gate "network-static-site-contracts" (
    builtins.all invalidSetting [
      { claimName = ""; }
      { claimName = "../bad"; }
      { claimName = "bad name"; }
      { hostName = "bad host"; }
      { hostName = "bad/name"; }
      {
        serverAliases = [
          "alias.fixture.invalid"
          "ALIAS.fixture.invalid"
        ];
      }
      { serverAliases = [ "www.fixture.invalid" ]; }
      { listenAddresses = [ "not-an-ip" ]; }
      { artifact = "/tmp/mutable-site"; }
      { artifact = builtins.unsafeDiscardStringContext "${artifact}"; }
    ]
    && rejected (withSites {
      primary = builtins.removeAttrs settings [ "listenAddresses" ];
    })
    && rejected (withSites {
      primary = settings // {
        useACMEHost = "missing";
      };
    })
    && rejected (withSites {
      secondary = secondarySettings // {
        claimName = "main-site";
      };
    })
    && rejected (withSites {
      secondary = secondarySettings // {
        hostName = "www.fixture.invalid";
      };
    })
    && rejected (withSites {
      extraModule.networkCore.caddy.contributions."main-site" = {
        capabilities = [ "forward-proxy" ];
      };
    })
    && rejected (withSites {
      primary = settings // {
        publicSite = false;
      };
      extraModule.networkCore.caddy.contributions."main-site" = {
        capabilities = [ "forward-proxy" ];
        siteAddress = ":443";
      };
    })
  );

  static-site-invalid-artifacts = pkgs.runCommand "network-static-site-invalid-artifacts" { } ''
    mkdir -p "$out" fixtures
    assert_rejected() {
      local label="$1" source="$2"
      if bash ${../modules/static-site/validate-artifact.sh} "$source" "result-$label" >"$out/$label.log" 2>&1; then
        echo "invalid artifact accepted: $label" >&2
        exit 1
      fi
      printf 'rejected invalid artifact: %s\n' "$label"
    }

    assert_rejected nonexistent fixtures/nonexistent
    mkdir fixtures/missing-index
    assert_rejected missing-index fixtures/missing-index
    mkdir fixtures/empty-index
    : > fixtures/empty-index/index.html
    assert_rejected empty-index fixtures/empty-index
    mkdir fixtures/empty-404
    printf 'index\n' > fixtures/empty-404/index.html
    : > fixtures/empty-404/404.html
    assert_rejected empty-404 fixtures/empty-404
    mkdir fixtures/symlink
    printf 'index\n' > fixtures/symlink/index.html
    ln -s index.html fixtures/symlink/linked.html
    assert_rejected symlink fixtures/symlink
    mkdir fixtures/fifo
    printf 'index\n' > fixtures/fifo/index.html
    mkfifo fixtures/fifo/pipe
    assert_rejected fifo fixtures/fifo
    mkdir fixtures/unreadable
    printf 'index\n' > fixtures/unreadable/index.html
    chmod 000 fixtures/unreadable/index.html
    assert_rejected unreadable fixtures/unreadable
  '';

  static-site-runtime =
    assert runtime.valid && runtime.evaluated;
    pkgs.runCommand "network-static-site-runtime"
      {
        nativeBuildInputs = [
          self.packages.x86_64-linux.caddy-custom
          pkgs.curl
          pkgs.gnugrep
          pkgs.iproute2
          pkgs.openssl
          pkgs.python3
          pkgs.util-linux
        ];
      }
      ''
        mkdir -p "$out"
        export out
        export CADDY_CONFIG=${runtime.machine.services.caddy.configFile}
        bash ${../tests/static-site-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
}
