{
  self,
  inputs,
  pkgs,
  root,
  gate,
}:
let
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
    secondaryIPv4 = "192.0.2.3";
    prefixLength = 24;
    gateway = "192.0.2.1";
    routeTableName = "secondary";
    routeTableId = 100;
  };
  fixtures = {
    wan-dhcp = instance "network-wan-dhcp" dhcpSettings;
    wan-static = instance "network-wan-static" staticSettings;
  };
  consumers = builtins.mapAttrs (_: value: consume { instances.fixture = value; }) fixtures;
  valid = consumer: consumer.valid && consumer.evaluated;
  rejected =
    consumer:
    let
      result = builtins.tryEval consumer.valid;
    in
    !result.success || !result.value;
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
          routeTableName = "tertiary";
          routeTableId = 101;
        }
      );
    };
    reserved-table = selection {
      fixture = instance "network-wan-static" (staticSettings // { routeTableId = 254; });
    };
  };
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
  invalidPriority =
    builtins.tryEval
      (selection {
        fixture = instance "network-wan-static" (staticSettings // { rulePriority = 0; });
      }).machine.system.build.toplevel.drvPath;
  oversizedPriority =
    builtins.tryEval
      (selection {
        fixture = instance "network-wan-static" (staticSettings // { rulePriority = 4294967296; });
      }).machine.system.build.toplevel.drvPath;
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
      ]
  );
  wan-selection-contracts = gate "network-wan-selection-contracts" (
    builtins.all rejected (builtins.attrValues conflicts)
    && !malformedIPv4.success
    && !nonCanonicalIPv4.success
    && !invalidPriority.success
    && !oversizedPriority.success
    && builtins.length distinctDhcpMachine.networkCore.wan.claims == 2
    && distinctDhcpMachine.networking.interfaces.wan0.useDHCP
    && distinctDhcpMachine.networking.interfaces.uplink1.useDHCP
  );
  wan-static-runtime = runtime "static";
  wan-dhcp-runtime = runtime "dhcp";
}
