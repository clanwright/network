{
  self,
  inputs,
  pkgs,
  root,
  gate,
  diagnostics ? false,
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
  routedIPv4 = {
    address = "198.51.100.5";
    prefixLength = 24;
    gateway = "198.51.100.1";
    routeTable = 1002;
    rulePriority = 10012;
  };
  anotherRoutedIPv4 = {
    address = "203.0.113.5";
    prefixLength = 24;
    gateway = "203.0.113.1";
    routeTable = 1003;
    rulePriority = 10013;
  };
  staticSettings = dhcpSettings // {
    primaryIPv4 = "192.0.2.2";
    prefixLength = 24;
    gateway = "192.0.2.1";
    additionalIPv4s = [
      { address = "192.0.2.3"; }
      { address = "192.0.2.4"; }
      routedIPv4
    ];
  };
  selection = instances: consume { inherit instances; };
  staticWith =
    settings: extraModule:
    consume {
      instances.fixture = instance "network-wan-static" settings;
      inherit extraModule;
    };
  static = settings: staticWith settings { };
  fixtures = {
    wan-dhcp = instance "network-wan-dhcp" dhcpSettings;
    wan-static = instance "network-wan-static" staticSettings;
  };
  consumers = lib.mapAttrs (_: value: selection { fixture = value; }) fixtures;
  valid = consumer: consumer.valid && consumer.evaluated;
  rejectedWith =
    fragment: consumer:
    let
      result = builtins.tryEval (
        lib.any (a: !a.assertion && lib.hasInfix fragment a.message) consumer.machine.assertions
      );
    in
    result.success && result.value;
  withAdditional =
    extra: staticSettings // { additionalIPv4s = staticSettings.additionalIPv4s ++ extra; };
  routedSettings = entry: staticSettings // { additionalIPv4s = [ entry ]; };
  rulesFor = consumer: consumer.machine.systemd.network.networks."40-wan0".routingPolicyRules;
  stableRules = consumer: lib.sort (a: b: a.Priority < b.Priority) (rulesFor consumer);
  reorderedSettings = staticSettings // {
    additionalIPv4s = lib.reverseList (staticSettings.additionalIPv4s ++ [ anotherRoutedIPv4 ]);
  };
  orderedSettings = staticSettings // {
    additionalIPv4s = staticSettings.additionalIPv4s ++ [ anotherRoutedIPv4 ];
  };
  singleAddress = static (staticSettings // { additionalIPv4s = [ ]; });
  distinctDhcp = selection {
    first = fixtures.wan-dhcp;
    second = instance "network-wan-dhcp" {
      interface = "uplink1";
      macAddress = "02:00:00:00:00:02";
    };
  };
  conflicts = [
    {
      fragment = "an interface must have exactly one";
      consumer = selection { inherit (fixtures) wan-dhcp wan-static; };
      nativeConflict = machine: machine.networking.interfaces.wan0.useDHCP;
    }
    {
      fragment = "physical MAC address";
      consumer = selection {
        first = fixtures.wan-dhcp;
        second = instance "network-wan-dhcp" {
          interface = "uplink1";
          inherit (dhcpSettings) macAddress;
        };
      };
    }
    {
      fragment = "physical MAC address";
      consumer = selection {
        first = instance "network-wan-dhcp" (dhcpSettings // { macAddress = "02:00:00:00:00:aa"; });
        second = instance "network-wan-dhcp" {
          interface = "uplink1";
          macAddress = "02:00:00:00:00:AA";
        };
      };
    }
    {
      fragment = "at most one static WAN instance";
      nativeConflict = machine: machine.networking.defaultGateway.interface;
      consumer = selection {
        first = fixtures.wan-static;
        second = instance "network-wan-static" (
          staticSettings
          // {
            interface = "uplink1";
            macAddress = "02:00:00:00:00:02";
          }
        );
      };
    }
  ];
  assertionCases = [
    {
      fragment = "requires distinct IPv4 addresses";
      settings = withAdditional [ { address = "192.0.2.2"; } ];
    }
    {
      fragment = "requires distinct IPv4 addresses";
      settings = withAdditional [ { address = "192.0.2.3"; } ];
    }
    {
      fragment = "lies outside the primary prefix";
      settings = withAdditional [ { address = "198.51.100.9"; } ];
    }
    {
      fragment = "without a gateway must use the primary prefix length";
      settings = withAdditional [
        {
          address = "192.0.2.9";
          prefixLength = 16;
        }
      ];
    }
    {
      fragment = "gateway 203.0.113.1 lies outside";
      settings = routedSettings (routedIPv4 // { gateway = "203.0.113.1"; });
    }
    {
      fragment = "gateway 203.0.113.1 lies outside";
      settings = staticSettings // {
        gateway = "203.0.113.1";
      };
    }
    {
      fragment = "must not be a host address";
      settings = staticSettings // {
        gateway = "192.0.2.3";
      };
    }
    {
      fragment = "required exactly when gateway is declared";
      settings = routedSettings (builtins.removeAttrs routedIPv4 [ "routeTable" ]);
    }
    {
      fragment = "required exactly when gateway is declared";
      settings = routedSettings (builtins.removeAttrs routedIPv4 [ "rulePriority" ]);
    }
    {
      fragment = "required exactly when gateway is declared";
      settings = withAdditional [
        {
          address = "192.0.2.9";
          routeTable = 1003;
          rulePriority = 10013;
        }
      ];
    }
    {
      fragment = "distinct routeTable IDs";
      settings = withAdditional [ (anotherRoutedIPv4 // { routeTable = 1002; }) ];
    }
    {
      fragment = "distinct rulePriority IDs";
      settings = withAdditional [ (anotherRoutedIPv4 // { rulePriority = 10012; }) ];
    }
  ]
  ++
    map
      (routeTable: {
        fragment = "is reserved";
        settings = routedSettings (routedIPv4 // { inherit routeTable; });
      })
      [
        52
        253
        254
        255
      ];
  typeRejected =
    settings:
    let
      inherit (static settings) machine;
    in
    !(builtins.tryEval (
      builtins.deepSeq {
        claims = map (claim: {
          inherit (claim) interface macAddress primaryIPv4;
        }) machine.networking.networkWanClaims;
        addresses = map (address: {
          inherit (address) address prefixLength;
        }) machine.networking.interfaces.${settings.interface}.ipv4.addresses;
        policies = machine.systemd.network.networks."40-${settings.interface}".routingPolicyRules;
      } true
    )).success;
  typeCases = [
    (staticSettings // { primaryIPv4 = "999.0.2.2"; })
    (staticSettings // { primaryIPv4 = "192.000.2.2"; })
    (staticSettings // { interface = "*"; })
    (staticSettings // { macAddress = "00:00:invalid"; })
    (routedSettings (routedIPv4 // { rulePriority = 10000; }))
    (routedSettings (routedIPv4 // { rulePriority = 32766; }))
    (routedSettings (routedIPv4 // { routeTable = 0; }))
    (routedSettings (routedIPv4 // { routeTable = 4294967296; }))
    (withAdditional [ { address = "999.0.2.9"; } ])
    (withAdditional [
      {
        address = "192.0.2.9";
        prefixLength = 33;
      }
    ])
    (staticSettings // { routeTableBase = 1000; })
    (staticSettings // { rulePriorityBase = 10010; })
    (staticSettings // { enableIPv6 = false; })
    (staticSettings // { secondaryIPv4 = "192.0.2.3"; })
  ];
  nativeForeign = claims: {
    systemd.network.networks.foreign = {
      matchConfig.Name = "foreign0";
    }
    // claims;
  };
  nativeConflicts = [
    {
      fragment = "rule priority 10000 conflicts";
      extra = nativeForeign {
        routingPolicyRules = [
          {
            Family = "ipv4";
            Table = 77;
            Priority = 10000;
          }
        ];
      };
    }
    {
      fragment = "rule priority 10012 conflicts";
      extra = nativeForeign {
        routingPolicyRules = [
          {
            Family = "ipv4";
            Table = 77;
            Priority = 10012;
          }
        ];
      };
    }
    {
      fragment = "route table 1002 conflicts";
      extra = nativeForeign {
        routingPolicyRules = [
          {
            Family = "ipv4";
            Table = 1002;
            Priority = 9000;
          }
        ];
      };
    }
    {
      fragment = "route table 1002 conflicts";
      extra = nativeForeign {
        routes = [
          {
            Destination = "0.0.0.0/0";
            Gateway = "192.0.2.1";
            Table = 1002;
          }
        ];
      };
    }
  ];
  disabledForeign = staticWith staticSettings (nativeForeign {
    enable = false;
    routes = [
      {
        Destination = "0.0.0.0/0";
        Gateway = "192.0.2.1";
        Table = 1002;
      }
    ];
    routingPolicyRules = [
      {
        Family = "ipv4";
        Table = 1002;
        Priority = 10012;
      }
    ];
  });
  aliasConflict = {
    systemd.network.config.routeTables.foreignAlias = 1002;
    imports = [
      (nativeForeign {
        routes = [
          {
            Destination = "0.0.0.0/0";
            Gateway = "192.0.2.1";
            Table = "foreignAlias";
          }
        ];
      })
    ];
  };
  identicalForeignRoute = nativeForeign {
    routes = [
      {
        Destination = "198.51.100.0/24";
        Scope = "link";
        Table = 1002;
        PreferredSource = "198.51.100.5";
      }
    ];
  };
  dhcpTableConflict = nativeForeign {
    DHCP = "ipv4";
    dhcpV4Config.RouteTable = 1002;
  };
  canonicalTableValues = staticWith staticSettings {
    systemd.network.config.routeTables = {
      foreignAlias = 77;
      "0x3ea" = 78;
    };
    imports = [
      (nativeForeign {
        DHCP = "ipv4";
        dhcpV4Config.RouteTable = "79";
        routes = [
          {
            Destination = "10.77.0.0/24";
            Table = "77";
          }
          {
            Destination = "10.78.0.0/24";
            Table = "0x3ea";
          }
          {
            Destination = "10.79.0.0/24";
            Table = "main";
          }
        ];
        routingPolicyRules = [
          {
            Family = "ipv4";
            Table = "foreignAlias";
            Priority = 9000;
          }
        ];
      })
    ];
  };
  aliasMapValues =
    aliases:
    staticWith staticSettings {
      systemd.network.config.routeTables = aliases;
      imports = [
        (nativeForeign {
          routes = [
            {
              Destination = "10.78.0.0/24";
              Table = "0x3ea";
            }
          ];
        })
      ];
    };
  aliasTableValues =
    tableId:
    aliasMapValues {
      "+" = 77;
      "0x3ea" = tableId;
    };
  distinctAliasIds = aliasTableValues 78;
  rawAliasValues =
    override:
    staticWith staticSettings (
      { lib, ... }:
      {
        systemd.network.config = {
          routeTables."0x3ea" = 78;
          networkConfig.RouteTable = override lib;
        };
        imports = [
          (nativeForeign {
            routes = [
              {
                Destination = "10.78.0.0/24";
                Table = "0x3ea";
              }
            ];
          })
        ];
      }
    );
  repeatedSelectorCases = {
    policy-newline = {
      fragment = "native policy Family, From and To must be scalar strings";
      extra = nativeForeign {
        routingPolicyRules = [
          {
            From = "2001:db8::/64\nFrom=192.0.2.0/24";
            Table = 1002;
            Priority = 10012;
          }
        ];
      };
    };
    route-newline = {
      fragment = "native route Destination, Gateway, Source and PreferredSource must be scalar strings";
      extra = nativeForeign {
        routes = [
          {
            Destination = "2001:db8::/64\nDestination=192.0.2.0/24";
            Table = 1002;
          }
        ];
      };
    };
    policy-From = {
      fragment = "native policy Family, From and To must be scalar strings";
      extra = nativeForeign {
        routingPolicyRules = [
          {
            From = [
              "2001:db8::/64"
              "192.0.2.0/24"
            ];
            Table = 1002;
            Priority = 10012;
          }
        ];
      };
    };
    policy-To = {
      fragment = "native policy Family, From and To must be scalar strings";
      extra = nativeForeign {
        routingPolicyRules = [
          {
            To = [
              "2001:db8::/64"
              "192.0.2.0/24"
            ];
            Table = 1002;
            Priority = 10012;
          }
        ];
      };
    };
    route-Destination = {
      fragment = "native route Destination, Gateway, Source and PreferredSource must be scalar strings";
      extra = nativeForeign {
        routes = [
          {
            Destination = [
              "2001:db8::/64"
              "192.0.2.0/24"
            ];
            Table = 1002;
          }
        ];
      };
    };
    route-Gateway = {
      fragment = "native route Destination, Gateway, Source and PreferredSource must be scalar strings";
      extra = nativeForeign {
        routes = [
          {
            Gateway = [
              "fe80::1"
              "192.0.2.1"
            ];
            Table = 1002;
          }
        ];
      };
    };
  };
  nativeDataCases = {
    route-protocol-injection = nativeForeign {
      routes = [
        {
          Destination = "2001:db8::/64";
          Protocol = "static\n[Route]\nDestination=0.0.0.0/0\nGateway=192.0.2.1\nTable=1002";
        }
      ];
    };
    description-injection = nativeForeign {
      networkConfig.Description = "foreign\n[Route]\nDestination=0.0.0.0/0\nTable=1002";
    };
    route-protocol-carriage-return = nativeForeign {
      routes = [ { Protocol = "static\rTable=1002"; } ];
    };
    field-key-injection = nativeForeign {
      matchConfig."Name\n[Route]\nTable" = "1002";
    };
    path-injection = nativeForeign {
      networkConfig.Description = /. + "/tmp/foreign\nTable=1002";
    };
    function-value = nativeForeign {
      networkConfig.Description = _: "foreign";
    };
    coercible-object = nativeForeign {
      networkConfig.Description.__toString = _: "foreign\n[Route]\nTable=1002";
    };
  };
  repeatedNativeData = staticWith staticSettings (nativeForeign {
    networkConfig = {
      Description = "ordinary native data";
      DNS = [
        "192.0.2.53"
        "192.0.2.54"
      ];
      IPv4Forwarding = false;
    };
    routes = [
      {
        Destination = "2001:db8::/64";
        Protocol = [
          "static"
          "static"
        ];
        Table = 1002;
        Metric = 42;
      }
    ];
  });
  tableSpellings = [
    "0x3ea"
    "01752"
    "+1002"
    "0b1111101010"
  ];
  nativeTableForms = {
    route = table: nativeForeign { routes = [ { Table = table; } ]; };
    policy =
      table:
      nativeForeign {
        routingPolicyRules = [
          {
            Family = "ipv4";
            Table = table;
            Priority = 9000;
          }
        ];
      };
    dhcp =
      table:
      nativeForeign {
        DHCP = "ipv4";
        dhcpV4Config.RouteTable = table;
      };
  };
  inactiveDhcpTable = staticWith staticSettings (nativeForeign {
    DHCP = "no";
    dhcpV4Config.RouteTable = 1002;
  });
  ipv6TableReuse = staticWith staticSettings (nativeForeign {
    routes = [
      {
        Destination = "2001:db8::/64";
        Gateway = "fe80::1";
        Table = 1002;
      }
    ];
    routingPolicyRules = [
      {
        Family = "ipv6";
        Table = 1002;
        Priority = 10012;
      }
    ];
  });
  waitPolicyConsumer = staticWith staticSettings {
    networking.enableIPv6 = false;
    systemd.network.wait-online = {
      enable = false;
      anyInterface = true;
      timeout = 17;
      extraArgs = [ "--ignore=private0" ];
    };
  };
  noWait = static (staticSettings // { waitOnline.enable = false; });
  staticConfig = consumers.wan-static.machine;
  waitInstance = waitPolicyConsumer.machine.systemd.services."systemd-networkd-wait-online@wan0";
  bootstrapConsumer =
    publicIPv4:
    consume {
      instances = {
        wan = fixtures.wan-static;
        firewall = instance "network-firewall" {
          bootstrapSsh = {
            enable = true;
            inherit publicIPv4;
          };
        };
      };
    };
  orderedConsumer = static orderedSettings;
  reorderedConsumer = static reorderedSettings;
  primaryBootstrap = bootstrapConsumer "192.0.2.2";
  typeLabels = [
    "primary-malformed"
    "primary-leading-zero"
    "interface-invalid"
    "mac-invalid"
    "priority-before-main-nondefault"
    "priority-main-reserved"
    "table-zero"
    "table-overflow"
    "additional-malformed"
    "prefix-overflow"
    "retired-table-base"
    "retired-priority-base"
    "retired-enableIPv6"
    "retired-secondaryIPv4"
  ];
  selectionCases = {
    valid-static-types = !typeRejected staticSettings;
    native-static-useDHCP-positive = !staticConfig.networking.interfaces.wan0.useDHCP;
    native-static-defaultGateway-positive = staticConfig.networking.defaultGateway.interface == "wan0";
    native-dhcp-useDHCP-positive = consumers.wan-dhcp.machine.networking.interfaces.wan0.useDHCP;
    native-alias-conflict = rejectedWith "route table 1002 conflicts" (
      staticWith staticSettings aliasConflict
    );
    native-identical-foreign-route-conflict = rejectedWith "route table 1002 conflicts" (
      staticWith staticSettings identicalForeignRoute
    );
    native-active-dhcp-conflict = rejectedWith "route table 1002 conflicts" (
      staticWith staticSettings dhcpTableConflict
    );
    native-canonical-table-values-positive = valid canonicalTableValues;
    native-distinct-alias-ids-positive = valid distinctAliasIds;
    native-raw-alias-prepend-rejected = rejectedWith "networkConfig.RouteTable must equal" (
      rawAliasValues (lib: lib.mkBefore [ "0x3ea:1002" ])
    );
    native-raw-alias-reset-rejected = rejectedWith "networkConfig.RouteTable must equal" (
      rawAliasValues (lib: lib.mkAfter [ "" ])
    );
    native-raw-alias-override-rejected = rejectedWith "networkConfig.RouteTable must equal" (
      rawAliasValues (lib: lib.mkForce [ "0x3ea:1002" ])
    );
    native-duplicate-alias-ids-rejected = rejectedWith "routeTables aliases require distinct IDs" (
      aliasTableValues 77
    );
    native-alias-pair-injection-rejected =
      rejectedWith "routeTables aliases must use canonical names"
        (aliasMapValues {
          "!:77 0x3ea" = 1002;
          "0x3ea" = 78;
        });
    native-inactive-dhcp-positive = valid inactiveDhcpTable;
    native-ipv6-reuse-positive = valid ipv6TableReuse;
    native-disabled-network-positive = valid disabledForeign;
    native-repeated-nonclassifier-positive = valid repeatedNativeData;
    native-raw-extraConfig-rejected = rejectedWith "native extraConfig must be empty" (
      staticWith staticSettings (nativeForeign {
        extraConfig = "[Route]\nDestination=0.0.0.0/0\nGateway=192.0.2.1\nTable=1002";
      })
    );
    native-global-data-injection-rejected = rejectedWith "native global networkd data must use" (
      staticWith staticSettings {
        systemd.network.config.dhcpV4Config.DUIDRawData = "00\n[Network]\nRouteTable=0x3ea:1002";
      }
    );
    distinct-dhcp-positive = valid distinctDhcp;
    distinct-dhcp-claims = lib.length distinctDhcp.machine.networking.networkWanClaims == 2;
    distinct-dhcp-first-enabled = distinctDhcp.machine.networking.interfaces.wan0.useDHCP;
    distinct-dhcp-second-enabled = distinctDhcp.machine.networking.interfaces.uplink1.useDHCP;
    ordered-positive = valid orderedConsumer;
    reordered-positive = valid reorderedConsumer;
    reordered-rule-identity = stableRules orderedConsumer == stableRules reorderedConsumer;
    bootstrap-primary-positive = valid primaryBootstrap;
    bootstrap-additional-same-prefix-rejected = rejectedWith "primary management IPv4" (
      bootstrapConsumer "192.0.2.3"
    );
    bootstrap-additional-separate-gateway-rejected = rejectedWith "primary management IPv4" (
      bootstrapConsumer "198.51.100.5"
    );
  }
  // lib.mapAttrs' (name: extra: {
    name = "native-data-${name}-rejected";
    value = rejectedWith "native network data must use" (staticWith staticSettings extra);
  }) nativeDataCases
  // lib.mapAttrs' (name: case: {
    name = "native-repeated-${name}-rejected";
    value = rejectedWith case.fragment (staticWith staticSettings case.extra);
  }) repeatedSelectorCases
  // lib.listToAttrs (
    lib.concatLists (
      lib.mapAttrsToList (
        form: extraFor:
        map (table: {
          name = "native-${form}-noncanonical-${table}";
          value = rejectedWith "must use an integer, canonical positive decimal string" (
            staticWith staticSettings (extraFor table)
          );
        }) tableSpellings
        ++ [
          {
            name = "native-${form}-canonical-decimal-collision";
            value = rejectedWith "route table 1002 conflicts" (staticWith staticSettings (extraFor "1002"));
          }
        ]
      ) nativeTableForms
    )
  )
  // lib.listToAttrs (
    lib.imap0 (index: case: {
      name = "selection-${toString index}-${case.fragment}";
      value =
        if case ? nativeConflict then
          # The precise native unique option throws before static assertions
          # can be collected for these invalid selections.
          !(builtins.tryEval (case.nativeConflict case.consumer.machine)).success
        else
          rejectedWith case.fragment case.consumer;
    }) conflicts
  )
  // lib.listToAttrs (
    lib.imap0 (index: settings: {
      name = "typed-${builtins.elemAt typeLabels index}";
      value = typeRejected settings;
    }) typeCases
  )
  // lib.listToAttrs (
    lib.imap0 (index: case: {
      name = "assertion-${toString index}-${case.fragment}";
      value = rejectedWith case.fragment (static case.settings);
    }) assertionCases
  )
  // lib.listToAttrs (
    lib.imap0 (index: case: {
      name = "native-${toString index}-${case.fragment}";
      value = rejectedWith case.fragment (staticWith staticSettings case.extra);
    }) nativeConflicts
  );
  positiveConfigurations = {
    inherit
      distinctDhcp
      inactiveDhcpTable
      ipv6TableReuse
      disabledForeign
      canonicalTableValues
      distinctAliasIds
      repeatedNativeData
      ;
    ordered = orderedConsumer;
    reordered = reorderedConsumer;
    bootstrapPrimary = primaryBootstrap;
  };
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
          pkgs.jq
          pkgs.bash
          pkgs.gnugrep
          pkgs.dnsmasq
          pkgs.socat
          pkgs.nmap
          pkgs.dig
          pkgs.procps
          pkgs.gnused
          pkgs.gawk
          pkgs.coreutils
        ];
        NETWORK_FILE = c.environment.etc."systemd/network/40-wan0.network".source;
        NETWORKD_CONF = c.environment.etc."systemd/networkd.conf".source;
        NETWORKD = "${c.systemd.package}/lib/systemd/systemd-networkd";
        WAIT_ONLINE = "${c.systemd.package}/lib/systemd/systemd-networkd-wait-online";
        WAIT_COMMAND =
          if mode == "static" then
            builtins.elemAt c.systemd.services."systemd-networkd-wait-online@wan0".serviceConfig.ExecStart 1
          else
            "";
        MODE = mode;
      }
      ''
        mkdir -p "$out"
        export out
        cp "$NETWORK_FILE" "$out/generated.network"
        started=$(date +%s%N)
        timeout 150 bash ${../tests/wan-runtime.sh} 2>&1 | tee "$out/runtime.log"
        ended=$(date +%s%N)
        printf '%s\n' "$(( (ended - started) / 1000000 ))" > "$out/body-milliseconds"
      '';
in
if diagnostics then
  {
    results = selectionCases;
    positiveFailures = lib.mapAttrs (
      _: consumer:
      map (assertion: assertion.message) (
        lib.filter (assertion: !assertion.assertion) consumer.machine.assertions
      )
    ) positiveConfigurations;
  }
else
  {
    consumer-wan-dhcp = gate "network-consumer-wan-dhcp" (
      valid consumers.wan-dhcp
      && consumers.wan-dhcp.machine.networking.useNetworkd
      && consumers.wan-dhcp.machine.networking.interfaces.wan0.useDHCP
      &&
        consumers.wan-dhcp.machine.systemd.network.links."10-wan0".matchConfig.MACAddress
        == dhcpSettings.macAddress
    );
    consumer-wan-static = gate "network-consumer-wan-static" (
      valid consumers.wan-static
      && !staticConfig.networking.interfaces.wan0.useDHCP
      &&
        map (a: a.address) staticConfig.networking.interfaces.wan0.ipv4.addresses == [
          "192.0.2.2"
          "192.0.2.3"
          "192.0.2.4"
          "198.51.100.5"
        ]
      &&
        map (a: a.prefixLength) staticConfig.networking.interfaces.wan0.ipv4.addresses == [
          24
          24
          24
          24
        ]
      && staticConfig.networking.defaultGateway.source == "192.0.2.2"
      &&
        rulesFor consumers.wan-static == [
          {
            Family = "ipv4";
            Table = 254;
            Priority = 10000;
            SuppressPrefixLength = 0;
          }
          {
            Family = "ipv4";
            From = "198.51.100.5/32";
            Table = 1002;
            Priority = 10012;
          }
        ]
      &&
        staticConfig.systemd.network.networks."40-wan0".routes == [
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
      && rulesFor singleAddress == [ ]
      && valid waitPolicyConsumer
      && !waitPolicyConsumer.machine.networking.enableIPv6
      && !waitPolicyConsumer.machine.systemd.network.wait-online.enable
      && waitPolicyConsumer.machine.systemd.network.wait-online.anyInterface
      && waitPolicyConsumer.machine.systemd.network.wait-online.timeout == 17
      && builtins.elem "--ignore=private0" waitPolicyConsumer.machine.systemd.network.wait-online.extraArgs
      && waitInstance.overrideStrategy == "asDropin"
      && waitInstance.wantedBy == [ "network-online.target" ]
      && waitInstance.serviceConfig.TimeoutStartSec == 65
      && lib.hasSuffix "systemd-networkd-wait-online --interface=wan0:routable --timeout=60" (
        builtins.elemAt waitInstance.serviceConfig.ExecStart 1
      )
      && !(noWait.machine.systemd.services ? "systemd-networkd-wait-online@wan0")
    );
    wan-selection-contracts = gate "network-wan-selection-contracts" (
      lib.all (result: result) (lib.attrValues selectionCases)
    );
    wan-static-runtime = runtime "static";
    wan-dhcp-runtime = runtime "dhcp";
  }
