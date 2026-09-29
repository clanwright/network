{
  self,
  inputs,
  pkgs,
  root,
  gate,
}:
let
  inherit (pkgs) lib;
  consume = import ./consumer.nix { inherit self inputs root; };
  instance = name: settings: {
    module = {
      input = "network";
      name = "@clanwright/${name}";
    };
    roles.host.machines.network-node.settings = settings;
  };
  dhcpSettings = {
    interface = "wan0";
    macAddress = "02:00:00:00:00:01";
  };
  staticSettings = dhcpSettings // {
    primaryIPv4 = "192.0.2.2";
    prefixLength = 24;
    gateway = "192.0.2.1";
    additionalIPv4s = [
      { address = "192.0.2.3"; }
      { address = "192.0.2.4"; }
      {
        address = "198.51.100.5";
        prefixLength = 24;
        gateway = "198.51.100.1";
      }
    ];
  };
  routedIPv4 = builtins.elemAt staticSettings.additionalIPv4s 2;
  withAdditional =
    extra: staticSettings // { additionalIPv4s = staticSettings.additionalIPv4s ++ extra; };
  fixtures = {
    wan-dhcp = instance "network-wan-dhcp" dhcpSettings;
    wan-static = instance "network-wan-static" staticSettings;
  };
  consumers = builtins.mapAttrs (_: value: consume { instances.fixture = value; }) fixtures;
  singleAddress = static (staticSettings // { additionalIPv4s = [ ]; });
  waitPolicyConsumer = consume {
    instances.fixture = fixtures.wan-static;
    extraModule.systemd.network.wait-online = {
      enable = false;
      anyInterface = true;
      timeout = 17;
    };
  };
  valid = consumer: consumer.valid && consumer.evaluated;
  rejected =
    consumer:
    let
      result = builtins.tryEval consumer.valid;
    in
    !result.success || !result.value;
  rejectedWith =
    fragment: consumer:
    let
      failed = builtins.filter (a: !a.assertion) consumer.machine.assertions;
      result = builtins.tryEval (builtins.any (a: lib.hasInfix fragment a.message) failed);
    in
    result.success && result.value;
  selection = instances: consume { inherit instances; };
  conflicts = {
    interface = selection { inherit (fixtures) wan-dhcp wan-static; };
    physical-mac = selection {
      first = instance "network-wan-dhcp" dhcpSettings;
      second = instance "network-wan-dhcp" {
        interface = "uplink1";
        macAddress = "02:00:00:00:00:01";
      };
    };
    physical-mac-case = selection {
      first = instance "network-wan-dhcp" (dhcpSettings // { macAddress = "02:00:00:00:00:aa"; });
      second = instance "network-wan-dhcp" {
        interface = "uplink1";
        macAddress = "02:00:00:00:00:AA";
      };
    };
    two-static = selection {
      first = instance "network-wan-static" staticSettings;
      second = instance "network-wan-static" (
        staticSettings
        // {
          interface = "uplink1";
          macAddress = "02:00:00:00:00:02";
          routeTableBase = 2000;
        }
      );
    };
  };
  static = settings: selection { fixture = instance "network-wan-static" settings; };
  staticRejections = [
    {
      fragment = "requires distinct IPv4 addresses";
      settings = withAdditional [ { address = "192.0.2.2"; } ];
    }
    {
      fragment = "requires distinct IPv4 addresses";
      settings = withAdditional [ { address = "192.0.2.3"; } ];
    }
    {
      fragment = "additional IPv4 198.51.100.9 lies outside the primary prefix 192.0.2.2/24";
      settings = withAdditional [ { address = "198.51.100.9"; } ];
    }
    {
      fragment = "additional IPv4 192.0.2.9 without a gateway must use the primary prefix length 24";
      settings = withAdditional [
        {
          address = "192.0.2.9";
          prefixLength = 16;
        }
      ];
    }
    {
      fragment = "gateway 203.0.113.1 lies outside 198.51.100.5/24";
      settings = staticSettings // {
        additionalIPv4s = [ (routedIPv4 // { gateway = "203.0.113.1"; }) ];
      };
    }
    {
      fragment = "gateway 203.0.113.1 lies outside 192.0.2.2/24";
      settings = staticSettings // {
        gateway = "203.0.113.1";
      };
    }
    {
      fragment = "gateway 192.0.2.3 must not be a host address";
      settings = staticSettings // {
        gateway = "192.0.2.3";
      };
    }
    {
      fragment = "route table 254 for 198.51.100.5 is reserved";
      settings = staticSettings // {
        additionalIPv4s = [ routedIPv4 ];
        routeTableBase = 254;
      };
    }
    {
      fragment = "rule priority 32767 for 198.51.100.5";
      settings = staticSettings // {
        rulePriorityBase = 32765;
      };
    }
  ];
  typeRejected =
    settings: !(builtins.tryEval (static settings).machine.system.build.toplevel.drvPath).success;
  malformedIPv4 =
    builtins.tryEval
      (selection {
        fixture = instance "network-wan-static" (staticSettings // { primaryIPv4 = "999.0.2.2"; });
      }).machine.system.build.toplevel.drvPath;
  nonCanonicalIPv4 =
    builtins.tryEval
      (selection {
        fixture = instance "network-wan-static" (staticSettings // { primaryIPv4 = "192.000.2.2"; });
      }).machine.system.build.toplevel.drvPath;
  invalidTypes = [
    (staticSettings // { rulePriorityBase = 0; })
    (staticSettings // { rulePriorityBase = 32766; })
    (staticSettings // { routeTableBase = 0; })
    (staticSettings // { routeTableBase = 4294967296; })
    (withAdditional [ { address = "999.0.2.9"; } ])
    (withAdditional [
      {
        address = "192.0.2.9";
        prefixLength = 33;
      }
    ])
    (staticSettings // { secondaryIPv4 = "192.0.2.3"; })
  ];
  distinctDhcpMachine =
    (inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        {
          boot.isContainer = true;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "26.11";
        }
        (import ../modules/host/wan-dhcp.nix {
          settings = dhcpSettings // {
            enableIPv6 = null;
          };
        })
        (import ../modules/host/wan-dhcp.nix {
          settings = {
            interface = "uplink1";
            macAddress = "02:00:00:00:00:02";
            enableIPv6 = null;
          };
        })
      ];
    }).config;
  runtime =
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
          pkgs.python3
        ];
        NETWORK_FILE = c.environment.etc."systemd/network/40-wan0.network".source;
        NETWORKD_CONF = c.environment.etc."systemd/networkd.conf".source;
        NETWORKD = "${c.systemd.package}/lib/systemd/systemd-networkd";
        WAIT_ONLINE = "${c.systemd.package}/lib/systemd/systemd-networkd-wait-online";
        WAIT_INTERFACE = if mode == "static" then "wan0:routable" else "";
        WAIT_TIMEOUT = if mode == "static" then "60" else "";
        MODE = mode;
        WAN_TRAFFIC = ../tests/wan-traffic.py;
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/wan-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
in
{
  consumer-wan-dhcp = gate "network-consumer-wan-dhcp" (
    valid consumers.wan-dhcp
    && consumers.wan-dhcp.machine.networking.useNetworkd
    && consumers.wan-dhcp.machine.networking.interfaces.wan0.useDHCP
  );
  consumer-wan-static = gate "network-consumer-wan-static" (
    valid consumers.wan-static
    && !consumers.wan-static.machine.networking.interfaces.wan0.useDHCP
    &&
      map (
        address: address.address
      ) consumers.wan-static.machine.networking.interfaces.wan0.ipv4.addresses == [
        "192.0.2.2"
        "192.0.2.3"
        "192.0.2.4"
        "198.51.100.5"
      ]
    &&
      map (
        address: address.prefixLength
      ) consumers.wan-static.machine.networking.interfaces.wan0.ipv4.addresses == [
        24
        24
        24
        24
      ]
    && consumers.wan-static.machine.networking.defaultGateway.source == "192.0.2.2"
    &&
      consumers.wan-static.machine.systemd.network.networks."40-wan0".routingPolicyRules == [
        {
          Family = "ipv4";
          From = "198.51.100.5/32";
          Table = 1002;
          Priority = 10012;
        }
      ]
    &&
      consumers.wan-static.machine.systemd.network.networks."40-wan0".routes == [
        {
          Gateway = "192.0.2.1";
          PreferredSource = "192.0.2.2";
        }
        {
          Destination = "198.51.100.0/24";
          Scope = "link";
          Table = 1002;
          PreferredSource = "198.51.100.5";
        }
        {
          Destination = "0.0.0.0/0";
          Gateway = "198.51.100.1";
          Table = 1002;
          PreferredSource = "198.51.100.5";
        }
      ]
    && valid singleAddress
    && singleAddress.machine.systemd.network.networks."40-wan0".routingPolicyRules == [ ]
    && !waitPolicyConsumer.machine.systemd.network.wait-online.enable
    && waitPolicyConsumer.machine.systemd.network.wait-online.anyInterface
    && waitPolicyConsumer.machine.systemd.network.wait-online.timeout == 17
    && waitPolicyConsumer.machine.systemd.services.network-wan-static-wait-online.enable
    && builtins.elem "network-online.target" waitPolicyConsumer.machine.systemd.services.network-wan-static-wait-online.before
    && builtins.elem "shutdown.target" waitPolicyConsumer.machine.systemd.services.network-wan-static-wait-online.before
    &&
      waitPolicyConsumer.machine.systemd.services.network-wan-static-wait-online.serviceConfig.TimeoutStartSec
      == 65
    && lib.hasSuffix "systemd-networkd-wait-online --interface=wan0:routable --timeout=60" waitPolicyConsumer.machine.systemd.services.network-wan-static-wait-online.serviceConfig.ExecStart
  );
  wan-selection-contracts = gate "network-wan-selection-contracts" (
    builtins.all rejected (builtins.attrValues conflicts)
    && !malformedIPv4.success
    && !nonCanonicalIPv4.success
    && !typeRejected staticSettings
    && builtins.all typeRejected invalidTypes
    && !rejectedWith "network WAN static" (static staticSettings)
    && builtins.all (case: rejectedWith case.fragment (static case.settings)) staticRejections
    && builtins.length distinctDhcpMachine.networkCore.wan.claims == 2
    && distinctDhcpMachine.networking.interfaces.wan0.useDHCP
    && distinctDhcpMachine.networking.interfaces.uplink1.useDHCP
  );
  wan-static-runtime = runtime "static";
  wan-dhcp-runtime = runtime "dhcp";
}
