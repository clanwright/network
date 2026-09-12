{ settings }:
{
  config,
  lib,
  ...
}:
{
  imports = [ ./wan-claims.nix ];
  networkCore.wan.claims = [
    {
      owner = "static:${settings.interface}";
      inherit (settings) interface macAddress;
      mode = "static";
    }
  ];
  assertions = [
    {
      assertion = settings.primaryIPv4 != settings.secondaryIPv4;
      message = "network WAN static requires two distinct IPv4 addresses.";
    }
    {
      assertion =
        !(builtins.elem settings.routeTableId [
          253
          254
          255
        ]);
      message = "network WAN static route table must not use a reserved ID.";
    }
  ];
  networking = {
    useDHCP = false;
    useNetworkd = true;
    enableIPv6 = lib.mkIf (settings.enableIPv6 != null) settings.enableIPv6;
    interfaces.${settings.interface} = {
      useDHCP = false;
      ipv4.addresses =
        map
          (address: {
            inherit address;
            inherit (settings) prefixLength;
          })
          [
            settings.primaryIPv4
            settings.secondaryIPv4
          ];
    };
    defaultGateway = {
      address = settings.gateway;
      inherit (settings) interface;
    };
  };
  systemd = {
    services.network-wan-static-wait-online = lib.mkIf settings.waitOnline.enable {
      description = "Wait for the Network static WAN interface";
      documentation = [ "man:systemd-networkd-wait-online.service(8)" ];
      wantedBy = [ "network-online.target" ];
      before = [
        "network-online.target"
        "shutdown.target"
      ];
      requires = [ "systemd-networkd.service" ];
      after = [ "systemd-networkd.service" ];
      conflicts = [ "shutdown.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = settings.waitOnline.timeout + 5;
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-networkd-wait-online --interface=${settings.interface}:routable --timeout=${toString settings.waitOnline.timeout}";
      };
    };
    network = {
      links."10-${settings.interface}" = {
        matchConfig.MACAddress = settings.macAddress;
        linkConfig.Name = settings.interface;
      };
      config.routeTables.${settings.routeTableName} = settings.routeTableId;
      networks."40-${settings.interface}" = {
        routingPolicyRules = [
          {
            Family = "ipv4";
            From = "${settings.secondaryIPv4}/32";
            Table = settings.routeTableName;
            Priority = settings.rulePriority;
          }
        ];
        routes = [
          {
            Destination = "0.0.0.0/0";
            Gateway = settings.gateway;
            Table = settings.routeTableName;
            PreferredSource = settings.secondaryIPv4;
          }
        ];
      };
    };
  };
}
