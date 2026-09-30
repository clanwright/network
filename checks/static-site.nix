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
    mkdir -p "$out/docs" "$out/published"
    printf '%s\n' 'network static index v1' > "$out/index.html"
    printf '%s\n' 'network static document v1' > "$out/docs/page.html"
    printf '%s\n' 'static must lose to publisher' > "$out/published/payload"
    printf '%s\n' 'network custom missing page' > "$out/404.html"
  '';
  replacement = pkgs.runCommand "network-static-site-replacement" { } ''
    mkdir -p "$out"
    printf '%s\n' 'network static index v2' > "$out/index.html"
  '';
  settings = {
    hostName = "www.fixture.invalid";
    serverAliases = [
      "alias.fixture.invalid"
      "second-alias.fixture.invalid"
    ];
    artifact = "${artifact}";
    useACMEHost = "fixture";
    listenAddresses = [
      "192.0.2.1"
      "192.0.2.2"
    ];
  };
  secondary = settings // {
    hostName = "secondary.fixture.invalid";
    serverAliases = [ ];
    listenAddresses = [ "192.0.2.3" ];
    artifact = "${replacement}";
  };
  # One complete synthetic VPN policy source. Runtime expands its disposable
  # credential; every native attachment imports this same handler.
  proxyPolicy = pkgs.writeText "network-static-proxy-policy.caddy" ''
    forward_proxy {
      basic_auth fixture {$STATIC_PROXY_PASSWORD}
      probe_resistance proxy.fixture.invalid
      hide_ip
      hide_via
      ports 18081
      disable_insecure_upstreams_check
      acl {
        deny 127.0.0.0/8
        deny 203.0.113.9/32
        allow 203.0.113.8/32
        deny all
      }
    }
  '';
  localProxyBind = ''
    expression `{http.request.local.host} in ["192.0.2.1", "192.0.2.2"] && {http.request.local.port} == 443`
  '';
  connectRoute = ''
    route {
      @fixture_connect {
        method CONNECT
        ${localProxyBind}
      }
      handle @fixture_connect {
        import ${proxyPolicy}
      }
    }
  '';
  # Existing generic absolute-form HTTP coverage is a separate root-only
  # request class; it is not part of the VPN CONNECT attachment contract.
  forwardGetRoute = ''
    route {
      @fixture_forward_get {
        method GET
        header Proxy-Authorization *
        ${localProxyBind}
      }
      handle @fixture_forward_get {
        import ${proxyPolicy}
      }
    }
  '';
  withSites =
    primaryArtifact: attachNamed:
    consume {
      instances = {
        primary = instance "network-static-site" "site" (settings // { artifact = "${primaryArtifact}"; });
        secondary = instance "network-static-site" "site" secondary;
        caddy = instance "network-caddy" "ingress" { };
      };
      extraModule = { config, lib, ... }: {
        security.acme = {
          acceptTerms = true;
          defaults.email = "fixture@example.invalid";
          certs.fixture = {
            domain = "www.fixture.invalid";
            webroot = "/tmp/acme-fixture";
          };
        };
        services.caddy = {
          globalConfig = lib.mkAfter "admin unix//tmp/network-static-admin.sock";
          virtualHosts = {
            "www.fixture.invalid" = {
              forwardProxy = true;
              useACMEHost = lib.mkForce null;
              extraConfig = lib.mkMerge [
                (lib.mkBefore connectRoute)
                (lib.mkBefore forwardGetRoute)
                ''
                  @sensitive_publisher {
                    host ${lib.concatStringsSep " " ([ settings.hostName ] ++ settings.serverAliases)}
                    path /published/*
                  }
                  log_skip @sensitive_publisher
                ''
                (lib.mkAfter ''
                  route {
                    @publisher {
                      host ${
                        lib.concatStringsSep " " (
                          [ settings.hostName ] ++ config.services.caddy.virtualHosts.${settings.hostName}.serverAliases
                        )
                      }
                      path /published/*
                    }
                    respond @publisher publisher 200
                  }
                '')
                (lib.mkOrder 2500 "tls /tmp/network-static-site-cert.pem /tmp/network-static-site-key.pem")
              ];
            };
            "secondary.fixture.invalid" = {
              useACMEHost = lib.mkForce null;
              extraConfig = lib.mkOrder 2500 "tls /tmp/network-static-site-cert.pem /tmp/network-static-site-key.pem";
            };
            "sibling.fixture.invalid" = {
              owner = "fixture:sibling";
              inherit (settings) listenAddresses;
              serverAliases = [ "sibling-alias.fixture.invalid" ];
              extraConfig = lib.mkMerge (
                lib.optional attachNamed (lib.mkBefore connectRoute)
                ++ [
                  (lib.mkOrder 2000 ''
                    route {
                      respond sibling 200
                    }
                  '')
                  (lib.mkOrder 2500 "tls /tmp/network-static-site-cert.pem /tmp/network-static-site-key.pem")
                ]
              );
            };
            "private.fixture.invalid" = {
              owner = "fixture:private";
              listenAddresses = [ "192.0.2.3" ];
              extraConfig = lib.mkMerge [
                (lib.mkBefore connectRoute)
                (lib.mkOrder 2000 ''
                  route {
                    respond private-site 200
                  }
                '')
                (lib.mkOrder 2500 "tls /tmp/network-static-site-cert.pem /tmp/network-static-site-key.pem")
              ];
            };
          };
        };
      };
    };
  runtime = withSites artifact true;
  replaced = withSites replacement true;
  shadowed = withSites artifact false;
  withoutIngress =
    (import ../clanServices/static-site/module.nix {
      instanceName = "primary";
      inherit settings;
    })
      {
        config.services.caddy.enable = false;
        inherit lib pkgs;
      };
  interface = ((import ../clanServices/static-site/default.nix) { } { }).roles.site.interface;
  settingAccepted =
    value:
    (builtins.tryEval (
      builtins.deepSeq
        (lib.evalModules {
          modules = [
            interface
            { config = value; }
          ];
        }).config
        true
    )).success;
  views = runtime.machine.services.caddy.virtualHosts;
  validator = ../clanServices/static-site/validate-artifact.sh;
in
{
  consumer-static-site = gate "network-consumer-static-site" (
    runtime.valid
    && runtime.evaluated
    && replaced.valid
    && replaced.evaluated
    && shadowed.valid
    && shadowed.evaluated
    && views."www.fixture.invalid".owner == "static-site:primary"
    && views."secondary.fixture.invalid".owner == "static-site:secondary"
    && views."www.fixture.invalid".hostName == ":443"
    && views."www.fixture.invalid".serverAliases == settings.serverAliases
    && builtins.getContext views."www.fixture.invalid".extraConfig != { }
    && views."sibling.fixture.invalid".owner == "fixture:sibling"
    && !views."sibling.fixture.invalid".forwardProxy
    && views."sibling.fixture.invalid".hostName == "sibling.fixture.invalid"
    && views."sibling.fixture.invalid".listenAddresses == settings.listenAddresses
    && views."sibling.fixture.invalid".serverAliases == [ "sibling-alias.fixture.invalid" ]
    &&
      builtins.getContext views."sibling.fixture.invalid".extraConfig == builtins.getContext connectRoute
    && builtins.getContext connectRoute != { }
    && !views."private.fixture.invalid".forwardProxy
    && builtins.any (
      a: !a.assertion && lib.hasPrefix "network-static-site requires" a.message
    ) withoutIngress.config.assertions
  );
  static-site-contracts = gate "network-static-site-contracts" (
    settingAccepted settings
    && settingAccepted (settings // { listenAddresses = [ ]; })
    && builtins.all (override: !settingAccepted (settings // override)) [
      { hostName = "bad host"; }
      { hostName = "bad/name"; }
      { hostName = "UPPER.invalid"; }
      { serverAliases = [ "UPPER.invalid" ]; }
      { listenAddresses = [ "not-an-ip" ]; }
      { artifact = "/tmp/mutable-site"; }
      { artifact = builtins.unsafeDiscardStringContext "${artifact}"; }
      { claimName = "retired"; }
      { publicSite = false; }
      { listenAddresses = null; }
    ]
    && !settingAccepted (builtins.removeAttrs settings [ "listenAddresses" ])
    && !settingAccepted (builtins.removeAttrs settings [ "useACMEHost" ])
  );
  static-site-invalid-artifacts = pkgs.runCommand "network-static-site-invalid-artifacts" { } ''
    mkdir -p "$out" fixtures
    assert_rejected() {
      local label="$1" source="$2" expected="$3"
      if bash ${validator} "$source" "result-$label" >"$out/$label.log" 2>&1; then
        echo "invalid artifact accepted: $label" >&2; exit 1
      fi
      grep -Fx "$expected" "$out/$label.log"
    }
    assert_rejected nonexistent fixtures/nonexistent 'Static site artifact must be a directory.'
    mkdir fixtures/missing-index
    assert_rejected missing-index fixtures/missing-index 'Static site artifact requires a nonempty readable regular index.html.'
    mkdir fixtures/empty-index
    : > fixtures/empty-index/index.html
    assert_rejected empty-index fixtures/empty-index 'Static site artifact requires a nonempty readable regular index.html.'
    mkdir fixtures/empty-404
    printf 'index\n' > fixtures/empty-404/index.html
    : > fixtures/empty-404/404.html
    assert_rejected empty-404 fixtures/empty-404 'Static site artifact has an invalid 404.html.'
    mkdir fixtures/symlink
    printf 'index\n' > fixtures/symlink/index.html
    ln -s index.html fixtures/symlink/linked.html
    assert_rejected symlink fixtures/symlink 'Static site artifact contains a link or unsupported entry.'
    mkdir fixtures/fifo
    printf 'index\n' > fixtures/fifo/index.html
    mkfifo fixtures/fifo/pipe
    assert_rejected fifo fixtures/fifo 'Static site artifact contains a link or unsupported entry.'
    mkdir fixtures/unreadable
    printf 'index\n' > fixtures/unreadable/index.html
    chmod 000 fixtures/unreadable/index.html
    assert_rejected unreadable fixtures/unreadable 'Static site artifact contains unreadable content.'
  '';
  static-site-runtime =
    assert runtime.valid && runtime.evaluated && replaced.valid && replaced.evaluated;
    pkgs.runCommand "network-static-site-runtime"
      {
        nativeBuildInputs = [
          self.packages.x86_64-linux.caddy-custom
          pkgs.curl
          pkgs.dnsmasq
          pkgs.gnugrep
          pkgs.iproute2
          pkgs.openssl
          pkgs.util-linux
          pkgs.jq
        ];
        CADDY_CONFIG = runtime.machine.services.caddy.configFile;
        SHADOW_CADDY_CONFIG = shadowed.machine.services.caddy.configFile;
        REPLACEMENT_CADDY_CONFIG = replaced.machine.services.caddy.configFile;
        PROXY_POLICY = proxyPolicy;
        CONNECT_ROUTE = pkgs.writeText "network-static-connect-route.caddy" connectRoute;
        ORIGINAL_ARTIFACT = artifact;
        REPLACEMENT_ARTIFACT = replacement;
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/static-site-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
}
