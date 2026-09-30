{ settings }:
{ config, lib, ... }:
let
  toInt =
    address: lib.foldl' (acc: octet: acc * 256 + lib.toInt octet) 0 (lib.splitString "." address);
  blockSize = prefix: lib.foldl' (acc: _: acc * 2) 1 (lib.range 1 (32 - prefix));
  networkOf = prefix: address: toInt address / blockSize prefix * blockSize prefix;
  inPrefix =
    address: prefix: other:
    networkOf prefix address == networkOf prefix other;
  fromInt =
    value:
    lib.concatMapStringsSep "." (shift: toString (lib.mod (value / shift) 256)) [
      16777216
      65536
      256
      1
    ];
  additional = map (
    entry:
    entry
    // {
      declaredPrefixLength = entry.prefixLength;
      prefixLength = if entry.prefixLength == null then settings.prefixLength else entry.prefixLength;
    }
  ) settings.additionalIPv4s;
  routed = lib.filter (entry: entry.gateway != null) additional;
  # Null fallbacks only allow a useful assertion for a missing required ID.
  # An invalid configuration never reaches a build or operational deployment.
  tableOf = entry: if entry.routeTable == null then 1 else entry.routeTable;
  priorityOf = entry: if entry.rulePriority == null then 10001 else entry.rulePriority;
  addresses = [
    {
      address = settings.primaryIPv4;
      inherit (settings) prefixLength;
    }
  ]
  ++ map (entry: { inherit (entry) address prefixLength; }) additional;
  hostAddresses = map (entry: entry.address) addresses;
  sourceRules = map (entry: {
    Family = "ipv4";
    From = "${entry.address}/32";
    Table = tableOf entry;
    Priority = priorityOf entry;
  }) routed;
  mainRule = {
    Family = "ipv4";
    Table = 254;
    Priority = 10000;
    SuppressPrefixLength = 0;
  };
  rules = lib.optional (routed != [ ]) mainRule ++ sourceRules;
  routes = lib.concatMap (entry: [
    {
      Destination = "${fromInt (networkOf entry.prefixLength entry.address)}/${toString entry.prefixLength}";
      Scope = "link";
      Table = tableOf entry;
      PreferredSource = entry.address;
    }
    {
      Destination = "0.0.0.0/0";
      Gateway = entry.gateway;
      Table = tableOf entry;
      PreferredSource = entry.address;
    }
  ]) routed;
  ownNetwork = "40-${settings.interface}";
  enabledNetworks = lib.filterAttrs (_: network: network.enable) config.systemd.network.networks;
  singleLineSelector =
    value: builtins.isString value && !lib.hasInfix "\n" value && !lib.hasInfix "\r" value;
  # Check the evaluated native data, not rendered INI or arbitrary unit files.
  # unitOption is permissive: reject unknown/coercible objects and functions.
  singleLineData =
    value:
    if builtins.isString value then
      singleLineSelector value
    else if builtins.isPath value || lib.isDerivation value then
      singleLineSelector (toString value)
    else if builtins.isList value then
      lib.all singleLineData value
    else if builtins.isAttrs value then
      !(value ? __toString)
      && lib.all (name: singleLineSelector name && singleLineData value.${name}) (lib.attrNames value)
    else
      value == null || builtins.isBool value || builtins.isInt value || builtins.isFloat value;
  scalarRuleSelectors =
    rule:
    lib.all singleLineSelector [
      (rule.Family or "both")
      (rule.From or "")
      (rule.To or "")
    ];
  scalarRouteSelectors =
    route:
    lib.all singleLineSelector [
      (route.Destination or "")
      (route.Gateway or "")
      (route.Source or "")
      (route.PreferredSource or "")
    ];
  ipv4Rule =
    rule:
    if (rule.Family or "both") == "ipv4" then
      true
    else
      (rule.Family or "both") != "ipv6"
      && !lib.any (selector: lib.hasInfix ":" (toString selector)) [
        (rule.From or "")
        (rule.To or "")
      ];
  ipv4Route =
    route:
    if route ? Destination && route.Destination != "" then
      !lib.hasInfix ":" (toString route.Destination)
    else
      !lib.any (selector: lib.hasInfix ":" (toString selector)) [
        (route.Gateway or "")
        (route.Source or "")
        (route.PreferredSource or "")
      ];
  allRules = lib.concatLists (
    lib.mapAttrsToList (
      networkName: network:
      map (rule: { inherit networkName rule; }) (lib.filter ipv4Rule network.routingPolicyRules)
    ) enabledNetworks
  );
  allRoutes = lib.concatLists (
    lib.mapAttrsToList (
      networkName: network:
      map (route: { inherit networkName route; }) (lib.filter ipv4Route network.routes)
    ) enabledNetworks
  );
  validTableId = table: builtins.isInt table && table > 0 && table <= 4294967295;
  builtinTableIds = {
    local = 255;
    main = 254;
    default = 253;
  };
  # Native networkd resolves names before its base-0 number parser. Restrict
  # claims to unambiguous literals rather than copying that numeric parser.
  # A declared single-token alias may itself look like a hexadecimal number.
  validAlias =
    name: table:
    builtins.match "[A-Za-z0-9_.+-]+" name != null
    && builtins.match "[0-9]+" name == null
    && !(builtinTableIds ? ${name})
    && validTableId table
    && !builtins.elem table [
      253
      254
      255
    ];
  tableAliases = config.systemd.network.config.routeTables;
  tableIds = tableAliases // builtinTableIds;
  aliasPairs = lib.mapAttrsToList (name: table: "${name}:${toString table}") tableAliases;
  # Networkd removes a later alias with an already used numeric ID. Check all
  # declared IDs so that alias lookup cannot silently fall back to base-0.
  aliasIds = lib.attrValues tableAliases;
  resolveTable =
    table:
    if builtins.isInt table then
      if validTableId table then table else null
    else if !builtins.isString table then
      null
    else
      tableIds.${table} or (
        if builtins.match "[1-9][0-9]*" table != null && builtins.stringLength table <= 10 then
          let
            number = lib.toInt table;
          in
          if validTableId number then number else null
        else
          null
      );
  equalTable = left: right: resolveTable left == resolveTable right;
  dhcpTableClaims = lib.concatLists (
    lib.mapAttrsToList (
      networkName: network:
      lib.optional
        (
          builtins.elem (network.networkConfig.DHCP or "no") [
            true
            "yes"
            "true"
            "1"
            "ipv4"
            "both"
            "v4"
          ]
          && network.dhcpV4Config ? RouteTable
        )
        {
          context = "${networkName}.dhcpV4Config.RouteTable";
          table = network.dhcpV4Config.RouteTable or 254;
        }
    ) enabledNetworks
  );
  nativeTableClaims =
    map (claim: {
      context = "${claim.networkName}.routes.Table";
      table = claim.route.Table or 254;
    }) allRoutes
    ++ map (claim: {
      context = "${claim.networkName}.routingPolicyRules.Table";
      table = claim.rule.Table or 254;
    }) allRules
    ++ dhcpTableClaims;
  equalId = left: right: toString left == toString right;
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
  imports = [
    ../../lib/platform.nix
    ../../lib/wan.nix
  ];
  assertions = [
    {
      assertion = lib.length (lib.unique hostAddresses) == lib.length hostAddresses;
      message = "network WAN static requires distinct IPv4 addresses.";
    }
    {
      assertion = lib.length (lib.unique (map tableOf routed)) == lib.length routed;
      message = "network WAN static separate gateways require distinct routeTable IDs.";
    }
    {
      assertion = lib.length (lib.unique (map priorityOf routed)) == lib.length routed;
      message = "network WAN static separate gateways require distinct rulePriority IDs.";
    }
  ]
  ++ gatewayAssertions {
    address = settings.primaryIPv4;
    inherit (settings) prefixLength gateway;
  }
  ++ lib.concatMap (entry: [
    {
      assertion =
        entry.gateway != null || inPrefix settings.primaryIPv4 settings.prefixLength entry.address;
      message = "network WAN static additional IPv4 ${entry.address} lies outside the primary prefix ${settings.primaryIPv4}/${toString settings.prefixLength}; declare its prefixLength and gateway.";
    }
    {
      assertion =
        entry.gateway != null
        || entry.declaredPrefixLength == null
        || entry.declaredPrefixLength == settings.prefixLength;
      message = "network WAN static additional IPv4 ${entry.address} without a gateway must use the primary prefix length ${toString settings.prefixLength}.";
    }
    {
      assertion =
        if entry.gateway == null then
          entry.routeTable == null && entry.rulePriority == null
        else
          entry.routeTable != null && entry.rulePriority != null;
      message = "network WAN static additional IPv4 ${entry.address}: routeTable and rulePriority are required exactly when gateway is declared.";
    }
  ]) additional
  ++ lib.concatMap (entry: gatewayAssertions { inherit (entry) address prefixLength gateway; }) routed
  ++ map (entry: {
    assertion =
      !(builtins.elem (tableOf entry) [
        52
        253
        254
        255
      ]);
    message = "network WAN static route table ${toString (tableOf entry)} for ${entry.address} is reserved (transport 52 or kernel 253–255).";
  }) routed
  ++ map (rule: {
    assertion =
      lib.filter (claim: equalId (claim.rule.Priority or (-1)) rule.Priority) allRules == [
        {
          networkName = ownNetwork;
          inherit rule;
        }
      ];
    message = "network WAN static rule priority ${toString rule.Priority} conflicts with another native routing-policy claim.";
  }) rules
  ++ lib.optionals (routed != [ ]) (
    [
      {
        assertion = singleLineData (builtins.removeAttrs config.systemd.network.config [ "_module" ]);
        message = "network WAN static native global networkd data must use single-line keys and supported values without LF/CR while separate-gateway IPv4 tables are owned.";
      }
      {
        assertion = lib.all (name: validAlias name tableAliases.${name}) (lib.attrNames tableAliases);
        message = "network WAN static native routeTables aliases must use canonical names and positive uint32 IDs other than 253–255 while separate-gateway IPv4 tables are owned.";
      }
      {
        assertion = lib.length (lib.unique aliasIds) == lib.length aliasIds;
        message = "network WAN static native routeTables aliases require distinct IDs while separate-gateway IPv4 tables are owned.";
      }
      {
        assertion = (config.systemd.network.config.networkConfig.RouteTable or [ ]) == aliasPairs;
        message = "network WAN static native networkConfig.RouteTable must equal the canonical routeTables alias pairs while separate-gateway IPv4 tables are owned; raw additions, overrides and resets are unsupported.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (networkName: network: [
        {
          # These retired options throw even when unset and are not rendered
          # by the pinned native networkToUnit function.
          assertion = singleLineData (
            builtins.removeAttrs network [
              "_module"
              "extraConfig"
              "dhcpConfig"
              "dhcpV6PrefixDelegationConfig"
              "ipv6PrefixDelegationConfig"
            ]
          );
          message = "network WAN static ${networkName} native network data must use single-line keys and supported values without LF/CR while separate-gateway IPv4 tables are owned.";
        }
        {
          assertion = network.extraConfig == "";
          message = "network WAN static ${networkName} native extraConfig must be empty while separate-gateway IPv4 tables are owned; raw INI is outside typed table ownership.";
        }
        {
          assertion = lib.all scalarRuleSelectors network.routingPolicyRules;
          message = "network WAN static ${networkName} native policy Family, From and To must be scalar strings without LF/CR while separate-gateway IPv4 tables are owned.";
        }
        {
          assertion = lib.all scalarRouteSelectors network.routes;
          message = "network WAN static ${networkName} native route Destination, Gateway, Source and PreferredSource must be scalar strings without LF/CR while separate-gateway IPv4 tables are owned.";
        }
      ]) enabledNetworks
    )
    ++ map (claim: {
      assertion = resolveTable claim.table != null;
      message = "network WAN static ${claim.context} must use an integer, canonical positive decimal string, built-in table name or valid declared routeTables alias while separate-gateway IPv4 tables are owned.";
    }) nativeTableClaims
  )
  ++ map (entry: {
    assertion =
      lib.all (claim: claim.networkName == ownNetwork && builtins.elem claim.route routes) (
        lib.filter (claim: equalTable (claim.route.Table or 254) (tableOf entry)) allRoutes
      )
      && lib.all (claim: claim.networkName == ownNetwork && builtins.elem claim.rule sourceRules) (
        lib.filter (claim: equalTable (claim.rule.Table or 254) (tableOf entry)) allRules
      )
      && !lib.any (claim: equalTable claim.table (tableOf entry)) dhcpTableClaims;
    message = "network WAN static route table ${toString (tableOf entry)} conflicts with another native route, policy or active DHCP route-table claim.";
  }) routed;
  networking = {
    networkWanClaims = [
      {
        inherit (settings) interface macAddress primaryIPv4;
        mode = "static";
      }
    ];
    useDHCP = false;
    useNetworkd = true;
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
    # Reuse the native template and override only this instance's readiness.
    services."systemd-networkd-wait-online@${settings.interface}" =
      lib.mkIf settings.waitOnline.enable
        {
          overrideStrategy = "asDropin";
          wantedBy = [ "network-online.target" ];
          serviceConfig = {
            TimeoutStartSec = settings.waitOnline.timeout + 5;
            ExecStart = [
              ""
              "${config.systemd.package}/lib/systemd/systemd-networkd-wait-online --interface=${settings.interface}:routable --timeout=${toString settings.waitOnline.timeout}"
            ];
          };
        };
    network = {
      links."10-${settings.interface}" = {
        matchConfig.MACAddress = settings.macAddress;
        linkConfig.Name = settings.interface;
      };
      networks."40-${settings.interface}" = {
        routingPolicyRules = rules;
        inherit routes;
      };
    };
  };
}
