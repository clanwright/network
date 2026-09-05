{
  self,
  inputs,
  pkgs,
  root,
}:
let
  lib = inputs.nixpkgs.lib;
  consume = import ./consumer.nix { inherit self inputs root; };
  instance = name: role: settings: {
    module = {
      input = "network";
      name = "@clanwright/${name}";
    };
    roles.${role}.machines.network-node.settings = settings;
  };
  dhcpSettings = {
    interface = "wan0";
    macAddress = "02:00:00:00:00:01";
  };
  staticSettings = dhcpSettings // {
    primaryIPv4 = "192.0.2.2";
    secondaryIPv4 = "192.0.2.3";
    prefixLength = 24;
    gateway = "192.0.2.1";
    routeTableName = "secondary";
    routeTableId = 100;
  };
  fixtures = {
    firewall = instance "network-firewall" "host" {
      public = {
        allowedTCPPorts = [ 443 ];
        allowedUDPPorts = [ 443 ];
      };
      interfaces.fixture0.allowedTCPPorts = [ 22 ];
      bootstrapSsh = {
        enable = true;
        publicIPv4 = "192.0.2.2";
        markerPath = "/tmp/network-bootstrap-marker";
      };
      rejectHttp = true;
    };
    wan-dhcp = instance "network-wan-dhcp" "host" dhcpSettings;
    wan-static = instance "network-wan-static" "host" staticSettings;
    tcp-tuning = instance "network-tcp-tuning" "host" { };
    caddy = instance "network-caddy" "ingress" { };
  };
  consumers = lib.mapAttrs (name: value: consume { instances.${name} = value; }) fixtures;
  contracts = {
    firewall =
      c:
      c.networking.firewall.enable
      && !c.networking.firewall.allowPing
      && c.networking.firewall.allowedTCPPorts == [ 443 ]
      && c.networking.firewall.interfaces.fixture0.allowedTCPPorts == [ 22 ]
      && !c.services.openssh.openFirewall;
    wan-dhcp =
      c:
      c.networking.useNetworkd
      && c.networking.interfaces.wan0.useDHCP
      && c.systemd.network.links."10-wan0".linkConfig.Name == "wan0";
    wan-static =
      c:
      !c.networking.interfaces.wan0.useDHCP
      &&
        map (a: a.address) c.networking.interfaces.wan0.ipv4.addresses == [
          "192.0.2.2"
          "192.0.2.3"
        ]
      && c.systemd.network.config.routeTables.secondary == 100
      && builtins.any (
        r: r.From or "" == "192.0.2.3/32" && r.Table == "secondary"
      ) c.systemd.network.networks."40-wan0".routingPolicyRules;
    tcp-tuning =
      c:
      c.boot.kernel.sysctl."net.ipv4.tcp_congestion_control" == "bbr"
      && builtins.elem "tcp_bbr" c.boot.kernelModules;
    caddy =
      c: c.services.caddy.enable && c.services.caddy.package == self.packages.x86_64-linux.caddy-custom;
  };
  wanRuntime =
    mode:
    let
      c = consumers.${"wan-${mode}"}.machine;
    in
    pkgs.runCommand "network-wan-${mode}-runtime"
      {
        nativeBuildInputs = [
          pkgs.util-linux
          pkgs.iproute2
          pkgs.bash
          pkgs.gnugrep
          pkgs.dnsmasq
        ];
        NETWORK_FILE = c.environment.etc."systemd/network/40-wan0.network".source;
        NETWORKD_CONF = c.environment.etc."systemd/networkd.conf".source;
        NETWORKD = "${c.systemd.package}/lib/systemd/systemd-networkd";
        MODE = mode;
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/wan-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
  gate =
    name: condition:
    if condition then
      pkgs.runCommand name { } ''touch "$out"''
    else
      throw "${name}: evaluated consumer contract failed";
  conflict = consume { instances = { inherit (fixtures) wan-dhcp wan-static; }; };
  reserved = consume {
    instances.wan-static = instance "network-wan-static" "host" (
      staticSettings // { routeTableId = 254; }
    );
  };
  missingBootstrap = consume {
    instances.firewall = instance "network-firewall" "host" { bootstrapSsh.enable = true; };
  };
  claim = {
    hostName = "fixture.invalid";
    useACMEHost = "fixture";
    logFile = "/tmp/network-fixture-access.log";
    publicSite = true;
    siteOwners = [ "fixture-site" ];
    capabilities = [ "forward-proxy" ];
    extraConfig = ''respond "network fixture"'';
    preRouteConfigFragments = [
      ''
        forward_proxy {
              hide_ip
              hide_via
            }''
    ];
  };
  site = consume {
    instances.caddy = fixtures.caddy;
    extraModule = {
      security.acme = {
        acceptTerms = true;
        defaults.email = "fixture@example.invalid";
        certs.fixture = {
          domain = "fixture.invalid";
          webroot = "/tmp/acme-fixture";
        };
      };
      networkCore.caddy = {
        fragments.fixture = claim // {
          capabilities = [ ];
          preRouteConfigFragments = [ ];
        };
        contributions.fixture = {
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
  wildcardCollision =
    capability:
    consume {
      instances.caddy = fixtures.caddy;
      extraModule.networkCore.caddy.fragments = {
        wildcard = claim // {
          listenAddresses = [ "0.0.0.0" ];
          capabilities = lib.optional capability "forward-proxy";
        };
        specific = claim // {
          hostName = if capability then "other.invalid" else claim.hostName;
          listenAddresses = [ "192.0.2.1" ];
          capabilities = lib.optional capability "forward-proxy";
        };
      };
    };
  collisionRejected =
    fixture:
    !(builtins.tryEval (builtins.deepSeq fixture.machine.networkCore.caddy.effectiveFragments true))
    .success;
  duplicateSite = consume {
    instances.caddy = fixtures.caddy;
    extraModule.networkCore.caddy.fragments = {
      one = claim;
      two = claim;
    };
  };
in
(lib.mapAttrs' (
  name: consumer:
  lib.nameValuePair "consumer-${name}" (
    gate "network-consumer-${name}" (
      consumer.valid && consumer.evaluated && contracts.${name} consumer.machine
    )
  )
) consumers)
// {
  incompatible-selections = gate "network-incompatible-selections" (
    !conflict.valid
    && !reserved.valid
    && !missingBootstrap.valid
    && !(builtins.tryEval (
      builtins.deepSeq duplicateSite.machine.networkCore.caddy.effectiveFragments true
    )).success
  );
  caddy-contribution-dependencies = gate "network-caddy-contribution-dependencies" (
    site.valid
    && site.evaluated
    && builtins.elem "fixture-auth.service" site.machine.systemd.services.caddy.requires
    && builtins.elem "fixture-auth.service" site.machine.systemd.services.caddy.after
    && site.machine.networkCore.caddy.effectiveFragments.fixture.capabilities == [ "forward-proxy" ]
  );
  caddy-wildcard-listener-collisions = gate "network-caddy-wildcard-listener-collisions" (
    collisionRejected (wildcardCollision false) && collisionRejected (wildcardCollision true)
  );
  wan-static-runtime = wanRuntime "static";
  wan-dhcp-runtime = wanRuntime "dhcp";
  firewall-runtime =
    pkgs.runCommand "network-firewall-runtime"
      {
        nativeBuildInputs = [
          pkgs.util-linux
          pkgs.iproute2
          pkgs.iptables
          pkgs.bash
          pkgs.gnugrep
        ];
        FIREWALL_START = pkgs.writeShellScript "firewall-start" consumers.firewall.machine.networking.firewall.extraCommands;
        FIREWALL_STOP = pkgs.writeShellScript "firewall-stop" consumers.firewall.machine.networking.firewall.extraStopCommands;
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/firewall-runtime.sh} 2>&1 | tee "$out/runtime.log"
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
        openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out fullchain.pem -days 1 -subj /CN=fixture.invalid 2> >(tee "$out/certificate-generation.log" >&2)
        cp fullchain.pem cert.pem
        cp ${site.machine.services.caddy.configFile} "$out/Caddyfile.original"
        sed "s|/var/lib/acme/fixture|$PWD|g" "$out/Caddyfile.original" > "$out/Caddyfile"
        caddy adapt --config "$out/Caddyfile" --adapter caddyfile > "$out/config.json" 2> >(tee "$out/adapt.log" >&2)
        caddy validate --config "$out/config.json" 2>&1 | tee "$out/validate.log"
      '';
}
// import ./acme.nix {
  inherit
    self
    inputs
    pkgs
    root
    ;
}
