{ settings }: { lib, ... }: {
  imports = [ ./wan-claims.nix ];
  networkCore.wan.claims = [
    {
      owner = "static:${settings.interface}";
      inherit (settings) interface;
      mode = "static";
      tableId = settings.routeTableId;
      tableName = settings.routeTableName;
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
  systemd.network = {
    links."10-${settings.interface}" = {
      matchConfig.MACAddress = settings.macAddress;
      linkConfig.Name = settings.interface;
    };
    wait-online = {
      enable = lib.mkForce settings.waitOnline.enable;
      anyInterface = lib.mkForce false;
      extraArgs = [ "--interface=${settings.interface}:routable" ];
      timeout = settings.waitOnline.timeout;
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
}
