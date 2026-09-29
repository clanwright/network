{ settings }:
{
  config,
  lib,
  ...
}:
let
  toInt =
    address: lib.foldl' (acc: octet: acc * 256 + lib.toInt octet) 0 (lib.splitString "." address);
  blockSize = prefixLength: lib.foldl' (acc: _: acc * 2) 1 (lib.range 1 (32 - prefixLength));
  networkOf = prefixLength: address: toInt address / blockSize prefixLength * blockSize prefixLength;
  inPrefix =
    base: prefixLength: address:
    networkOf prefixLength base == networkOf prefixLength address;
  fromInt =
    value:
    lib.concatMapStringsSep "." (shift: toString (lib.mod (value / shift) 256)) [
      16777216
      65536
      256
      1
    ];
  primaryPrefix = "${settings.primaryIPv4}/${toString settings.prefixLength}";
  additional = lib.imap0 (
    index: entry:
    entry
    // {
      declaredPrefixLength = entry.prefixLength;
      prefixLength = if entry.prefixLength == null then settings.prefixLength else entry.prefixLength;
      table = settings.routeTableBase + index;
      priority = settings.rulePriorityBase + index;
    }
  ) settings.additionalIPv4s;
  routed = builtins.filter (entry: entry.gateway != null) additional;
  addresses = [
    {
      address = settings.primaryIPv4;
      inherit (settings) prefixLength;
    }
  ]
  ++ map (entry: { inherit (entry) address prefixLength; }) additional;
  hostAddresses = map (entry: entry.address) addresses;
  gatewayAssertions =
    {
      address,
      prefixLength,
      gateway,
    }:
    [
      {
        assertion = inPrefix address prefixLength gateway;
        message = "network WAN static gateway ${gateway} lies outside ${address}/${toString prefixLength}.";
      }
      {
        assertion = !builtins.elem gateway hostAddresses;
        message = "network WAN static gateway ${gateway} must not be a host address.";
      }
    ];
in
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
      assertion = lib.length (lib.unique hostAddresses) == lib.length hostAddresses;
      message = "network WAN static requires distinct IPv4 addresses.";
    }
  ]
  ++ gatewayAssertions {
    address = settings.primaryIPv4;
    inherit (settings) prefixLength gateway;
  }
  ++ map (entry: {
    assertion =
      entry.gateway != null || inPrefix settings.primaryIPv4 settings.prefixLength entry.address;
    message = "network WAN static additional IPv4 ${entry.address} lies outside the primary prefix ${primaryPrefix}; declare its prefixLength and gateway.";
  }) additional
  ++ map (entry: {
    assertion =
      entry.gateway != null
      || entry.declaredPrefixLength == null
      || entry.declaredPrefixLength == settings.prefixLength;
    message = "network WAN static additional IPv4 ${entry.address} without a gateway must use the primary prefix length ${toString settings.prefixLength}.";
  }) additional
  ++ lib.concatMap (entry: gatewayAssertions { inherit (entry) address prefixLength gateway; }) routed
  ++ map (entry: {
    assertion =
      !(builtins.elem entry.table [
        253
        254
        255
      ])
      && entry.table <= 4294967295;
    message = "network WAN static route table ${toString entry.table} for ${entry.address} is reserved or out of range.";
  }) routed
  ++ map (entry: {
    assertion = entry.priority <= 32765;
    message = "network WAN static rule priority ${toString entry.priority} for ${entry.address} must precede the main table rule (32766).";
  }) routed;
  networking = {
    useDHCP = false;
    useNetworkd = true;
    enableIPv6 = lib.mkIf (settings.enableIPv6 != null) settings.enableIPv6;
    interfaces.${settings.interface} = {
      useDHCP = false;
      ipv4.addresses = addresses;
    };
    defaultGateway = {
      address = settings.gateway;
      inherit (settings) interface;
      source = settings.primaryIPv4;
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
      networks."40-${settings.interface}" = {
        routingPolicyRules = map (entry: {
          Family = "ipv4";
          From = "${entry.address}/32";
          Table = entry.table;
          Priority = entry.priority;
        }) routed;
        routes = lib.concatMap (entry: [
          {
            Destination = "${fromInt (networkOf entry.prefixLength entry.address)}/${toString entry.prefixLength}";
            Scope = "link";
            Table = entry.table;
            PreferredSource = entry.address;
          }
          {
            Destination = "0.0.0.0/0";
            Gateway = entry.gateway;
            Table = entry.table;
            PreferredSource = entry.address;
          }
        ]) routed;
      };
    };
  };
}
