{
  consume,
  gate,
  instance,
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;
  destination = {
    destinationIPv4 = "192.0.2.2";
    allowedTCPPorts = [ 8443 ];
    allowedUDPPorts = [ 8443 ];
  };
  # The destination must be a host address evaluated through networking.interfaces.
  hostAddresses.networking.interfaces.server0.ipv4.addresses = [
    {
      address = "192.0.2.2";
      prefixLength = 24;
    }
    {
      address = "192.0.2.4";
      prefixLength = 24;
    }
  ];
  fixture = instance "network-firewall" "host" {
    public = {
      allowedTCPPorts = [ 443 ];
      allowedUDPPorts = [ 443 ];
      destinations = [ destination ];
    };
    interfaces.fixture0.allowedTCPPorts = [ 22 ];
    bootstrapSsh = {
      enable = true;
      publicIPv4 = "192.0.2.2";
      markerPath = "/build/network-bootstrap/allow-wan-ssh";
      durationSeconds = 120;
    };
    rejectHttp = true;
  };
  consumer = consume {
    instances.firewall = fixture;
    extraModule = hostAddresses;
  };
  firewallConfig = consumer.machine;
  stricterConsumer = consume {
    instances.firewall = fixture;
    extraModule = {
      imports = [ hostAddresses ];
      services.openssh.settings.AuthenticationMethods = "publickey,publickey";
    };
  };
  destinationConsumer =
    destinations:
    consume {
      instances.firewall = instance "network-firewall" "host" {
        public.allowedTCPPorts = [ 443 ];
        public.destinations = destinations;
      };
      extraModule = hostAddresses;
    };
  destinationRejectedWith =
    fragment: destinations:
    let
      failed = builtins.filter (a: !a.assertion) (destinationConsumer destinations).machine.assertions;
      result = builtins.tryEval (builtins.any (a: lib.hasInfix fragment a.message) failed);
    in
    result.success && result.value;
  nativeOverlapRejected =
    protocol: native:
    let
      candidate = consume {
        instances.firewall = instance "network-firewall" "host" {
          public.destinations = [
            {
              destinationIPv4 = "192.0.2.2";
              "allowed${protocol}Ports" = [ 8443 ];
            }
          ];
        };
        extraModule = {
          imports = [ hostAddresses ];
          networking.firewall = native;
        };
      };
    in
    builtins.any (
      a: !a.assertion && lib.hasInfix "also accepted" a.message
    ) candidate.machine.assertions;
  nativeOverlapCases = protocol: [
    { "allowed${protocol}Ports" = [ 8443 ]; }
    {
      "allowed${protocol}PortRanges" = [
        {
          from = 8440;
          to = 8450;
        }
      ];
    }
    { interfaces.default."allowed${protocol}Ports" = [ 8443 ]; }
    {
      interfaces.default."allowed${protocol}PortRanges" = [
        {
          from = 8440;
          to = 8450;
        }
      ];
    }
    { interfaces.ordinary0."allowed${protocol}Ports" = [ 8443 ]; }
    {
      interfaces.ordinary0."allowed${protocol}PortRanges" = [
        {
          from = 8440;
          to = 8450;
        }
      ];
    }
  ];
  # Force only the typed rendering, so assertions cannot mask a missing type check.
  destinationTypeRejected =
    destinations:
    !(builtins.tryEval (
      builtins.deepSeq (destinationConsumer destinations).machine.networking.firewall.extraInputRules true
    )).success;
  rejectPacketsRejected =
    let
      rejecting = consume {
        instances.firewall = instance "network-firewall" "host" { public.destinations = [ destination ]; };
        extraModule = {
          imports = [ hostAddresses ];
          networking.firewall.rejectPackets = true;
        };
      };
    in
    builtins.any (
      a: !a.assertion && lib.hasInfix "disable networking.firewall.rejectPackets" a.message
    ) rejecting.machine.assertions;
  scopedMultiple = {
    destinationIPv4 = "192.0.2.4";
    allowedTCPPorts = [
      8443
      47291
    ];
  };
  nativeInputRules = firewallConfig.networking.firewall.extraInputRules;
  missingAddress = consume {
    instances.firewall = instance "network-firewall" "host" { bootstrapSsh.enable = true; };
  };
  invalidAddress =
    address:
    builtins.tryEval
      (consume {
        instances.firewall = instance "network-firewall" "host" {
          bootstrapSsh = {
            enable = true;
            publicIPv4 = address;
          };
        };
      }).machine.system.build.toplevel.drvPath;
  malformedAddress = invalidAddress "999.0.2.2";
  nonCanonicalAddress = invalidAddress "192.000.2.2";
  privateClaim = destinationIPv4: trustedInterfaces: { inherit destinationIPv4 trustedInterfaces; };
  privateFixture = instance "network-firewall" "host" {
    public.allowedTCPPorts = [ 443 ];
    public.allowedUDPPorts = [ 443 ];
    interfaces.fixture0.allowedTCPPorts = [ 22 ];
    rejectHttp = true;
  };
  privateConsumer =
    claims:
    consume {
      instances.firewall = privateFixture;
      extraModule.networking.firewall.privateIngress = claims;
    };
  oneClaim = {
    app = privateClaim "192.0.2.2" [ "fixture0" ];
  };
  composedClaims = oneClaim // {
    second = privateClaim "192.0.2.2" [
      "lo"
      "fixture0"
      "fixture0"
    ];
    other = privateClaim "198.51.100.2" [ ];
  };
  privateConfig = (privateConsumer composedClaims).machine;
  privateTable = privateConfig.networking.nftables.tables.network-edge-policy.content;
  privateInvalid =
    claims:
    builtins.tryEval (
      builtins.deepSeq (privateConsumer claims).machine.system.build.toplevel.drvPath true
    );
  privateConflict = privateConsumer (
    oneClaim // { second = privateClaim "192.0.2.2" [ "tailscale0" ]; }
  );
  privateRemovedConfig = (privateConsumer { inherit (composedClaims) other; }).machine;
  privateOneRemovedConfig = (privateConsumer { inherit (composedClaims) second other; }).machine;
  privateUpdatedConfig = (privateConsumer { app = privateClaim "192.0.2.2" [ "public0" ]; }).machine;
  privateLastConfig = (privateConsumer { }).machine;
  defaultPrivateConsumer =
    claims:
    consume {
      instances.firewall = instance "network-firewall" "host" {
        public.allowedTCPPorts = [ 443 ];
        public.allowedUDPPorts = [ 443 ];
      };
      extraModule.networking.firewall.privateIngress = claims;
    };
  defaultClaimConfig = (defaultPrivateConsumer oneClaim).machine;
  defaultEmptyConfig = (defaultPrivateConsumer { }).machine;
  httpPositiveConfig =
    (consume {
      instances.firewall = instance "network-firewall" "host" {
        public.allowedTCPPorts = [
          80
          443
        ];
      };
      extraModule = hostAddresses;
    }).machine;
  udpPositiveConfig =
    (consume {
      instances.firewall = instance "network-firewall" "host" {
        public.allowedUDPPorts = [ 8443 ];
      };
      extraModule = hostAddresses;
    }).machine;
  httpGuardConfig =
    (consume {
      instances.firewall = instance "network-firewall" "host" {
        public.allowedTCPPorts = [
          80
          443
        ];
        rejectHttp = true;
      };
      extraModule = hostAddresses;
    }).machine;
  duplicateOwner = builtins.tryEval (
    builtins.deepSeq
      (consume {
        instances = {
          first = instance "network-firewall" "host" { };
          second = instance "network-firewall" "host" { };
        };
      }).machine.networking.firewall.networkBaseOwner
      true
  );
  # Execute evaluated systemd command chains unchanged, including native state
  # bookkeeping and Network bootstrap hooks. The runtime supplies StateDirectory.
  commandChain =
    name: commands:
    pkgs.writeShellScript name (
      "set -euo pipefail\n" + lib.concatMapStringsSep "\n" toString (lib.toList commands)
    );
  lifecycle =
    name: config:
    let
      service = config.systemd.services.nftables.serviceConfig;
    in
    {
      start = commandChain (name + "-start") (
        lib.toList service.ExecStart ++ lib.toList (service.ExecStartPost or [ ])
      );
      reload = commandChain (name + "-reload") service.ExecReload;
      stop = commandChain (name + "-stop") service.ExecStop;
    };
  native = lifecycle "network-firewall" firewallConfig;
  httpPositive = lifecycle "network-http-positive" httpPositiveConfig;
  udpPositive = lifecycle "network-udp-positive" udpPositiveConfig;
  httpGuard = lifecycle "network-http-guard" httpGuardConfig;
  privateNative = lifecycle "network-private" privateConfig;
  privateOneRemoved = lifecycle "network-private-one-removed" privateOneRemovedConfig;
  privateRemoved = lifecycle "network-private-removed" privateRemovedConfig;
  privateUpdated = lifecycle "network-private-updated" privateUpdatedConfig;
  privateLast = lifecycle "network-private-last" privateLastConfig;
  defaultClaim = lifecycle "network-default-claim" defaultClaimConfig;
  defaultEmpty = lifecycle "network-default-empty" defaultEmptyConfig;
  refreshPackage =
    lib.findFirst (package: lib.getName package == "network-bootstrap-ssh-refresh")
      (throw "network firewall check could not find the bootstrap refresh package")
      firewallConfig.environment.systemPackages;
  refresh = lib.getExe refreshPackage;
  renewPackage =
    lib.findFirst (package: lib.getName package == "network-bootstrap-ssh-renew")
      (throw "network firewall check could not find the bootstrap renewal package")
      firewallConfig.environment.systemPackages;
  runtime =
    pkgs.runCommand "network-firewall-runtime"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.iproute2
          pkgs.socat
          pkgs.nmap
          pkgs.jq
          pkgs.nftables
          pkgs.util-linux
        ];
        NATIVE_START = native.start;
        NATIVE_RELOAD = native.reload;
        NATIVE_STOP = native.stop;
        HTTP_POSITIVE_RELOAD = httpPositive.reload;
        UDP_POSITIVE_RELOAD = udpPositive.reload;
        HTTP_GUARD_RELOAD = httpGuard.reload;
        RUNTIME_SCRIPT = pkgs.writeText "network-firewall-runtime.sh" (
          builtins.readFile ../tests/firewall-runtime.sh
        );
        REFRESH = refresh;
        RENEW = lib.getExe renewPackage;
        MARKER_PATH = "/build/network-bootstrap/allow-wan-ssh";
        PUBLIC_IPV4 = "192.0.2.2";
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/firewall-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
  privateRuntime =
    pkgs.runCommand "network-firewall-private-ingress-runtime"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.iproute2
          pkgs.iputils
          pkgs.socat
          pkgs.nmap
          pkgs.jq
          pkgs.nftables
          pkgs.util-linux
        ];
        NATIVE_START = privateNative.start;
        NATIVE_RELOAD = privateNative.reload;
        NATIVE_STOP = privateNative.stop;
        ONE_REMOVED_RELOAD = privateOneRemoved.reload;
        REMOVED_RELOAD = privateRemoved.reload;
        UPDATED_RELOAD = privateUpdated.reload;
        LAST_START = privateLast.start;
        LAST_RELOAD = privateLast.reload;
        DEFAULT_CLAIM_RELOAD = defaultClaim.reload;
        DEFAULT_EMPTY_RELOAD = defaultEmpty.reload;
        RUNTIME_SCRIPT = pkgs.writeText "network-firewall-private-ingress-runtime.sh" (
          builtins.readFile ../tests/firewall-private-ingress-runtime.sh
        );
      }
      ''
        mkdir -p "$out"
        export out
        bash ${../tests/firewall-private-ingress-runtime.sh} 2>&1 | tee "$out/runtime.log"
      '';
in
{
  consumer-firewall = gate "network-consumer-firewall" (
    consumer.valid
    && consumer.evaluated
    && firewallConfig.networking.nftables.enable
    && !firewallConfig.networking.nftables.flushRuleset
    && firewallConfig.networking.firewall.backend == "nftables"
    && firewallConfig.networking.firewall.allowedTCPPorts == [ 443 ]
    && firewallConfig.networking.firewall.interfaces.fixture0.allowedTCPPorts == [ 22 ]
    && firewallConfig.networking.nftables.checkRuleset
    && !duplicateOwner.success
    && !firewallConfig.networking.firewall.allowPing
    && !firewallConfig.services.openssh.openFirewall
    && !firewallConfig.services.openssh.settings.PasswordAuthentication
    && !firewallConfig.services.openssh.settings.KbdInteractiveAuthentication
    && firewallConfig.services.openssh.settings.AuthenticationMethods == "publickey"
    && stricterConsumer.valid
    && stricterConsumer.evaluated
    && stricterConsumer.machine.services.openssh.settings.AuthenticationMethods == "publickey,publickey"
  );
  firewall-invalid-bootstrap = gate "network-firewall-invalid-bootstrap" (
    !missingAddress.valid && !malformedAddress.success && !nonCanonicalAddress.success
  );
  firewall-public-destination-contracts = gate "network-firewall-public-destination-contracts" (
    lib.hasInfix ''ip daddr 192.0.2.2 tcp dport { 8443 } accept comment "network: public destination ingress"'' nativeInputRules
    && lib.hasInfix ''ip daddr 192.0.2.2 udp dport { 8443 } accept comment "network: public destination ingress"'' nativeInputRules
    && lib.hasInfix "network: active bootstrap SSH" nativeInputRules
    && firewallConfig.networking.firewall.allowedTCPPorts == [ 443 ]
    && (destinationConsumer [ ]).valid
    && (destinationConsumer [ ]).machine.networking.firewall.extraInputRules == ""
    && (destinationConsumer [ scopedMultiple ]).valid
    &&
      lib.hasInfix "ip daddr 192.0.2.4 tcp dport { 8443, 47291 } accept"
        (destinationConsumer [ scopedMultiple ]).machine.networking.firewall.extraInputRules
    && !(lib.hasInfix "udp dport"
      (destinationConsumer [ scopedMultiple ]).machine.networking.firewall.extraInputRules
    )
    && !destinationRejectedWith "network firewall public destination" [ destination ]
    && destinationRejectedWith "public destinations must be distinct" [
      destination
      destination
    ]
    && destinationRejectedWith "public destination 192.0.2.2 declares no ports" [
      {
        destinationIPv4 = "192.0.2.2";
      }
    ]
    && destinationRejectedWith "public destination 192.0.2.2 TCP port 443 is also accepted" [
      (destination // { allowedTCPPorts = [ 443 ]; })
    ]
    && lib.all (protocol: lib.all (nativeOverlapRejected protocol) (nativeOverlapCases protocol)) [
      "TCP"
      "UDP"
    ]
    && rejectPacketsRejected
    && destinationRejectedWith "public destination 198.51.100.9 is not configured" [
      (destination // { destinationIPv4 = "198.51.100.9"; })
    ]
    && !destinationTypeRejected [ destination ]
    && destinationTypeRejected [ (destination // { destinationIPv4 = "999.0.2.2"; }) ]
    && destinationTypeRejected [ (destination // { destinationIPv4 = "2001:db8::2"; }) ]
    && destinationTypeRejected [ (destination // { allowedTCPPorts = [ 65536 ]; }) ]
  );
  firewall-private-ingress-contracts = gate "network-firewall-private-ingress-contracts" (
    (privateConsumer composedClaims).valid
    && (privateConsumer composedClaims).evaluated
    && (privateConsumer oneClaim).valid
    && (privateConsumer {
      inherit (composedClaims) second other;
    }).valid
    && (privateConsumer { inherit (composedClaims) other; }).valid
    && (privateConsumer { }).valid
    && !privateConflict.valid
    && !(privateInvalid { bad = privateClaim "2001:db8::2" [ "fixture0" ]; }).success
    && !(privateInvalid { bad = privateClaim "999.0.2.2" [ "fixture0" ]; }).success
    && !(privateInvalid { bad = privateClaim "192.000.2.2" [ "fixture0" ]; }).success
    && !(privateInvalid { bad = privateClaim "192.0.2.2" [ "*" ]; }).success
    && !(privateInvalid { bad = privateClaim "192.0.2.2" [ "abcdefghijklmnop" ]; }).success
    &&
      builtins.length (
        lib.filter (line: lib.hasInfix "192.0.2.2" line) (lib.splitString "\n" privateTable)
      ) == 1
    && lib.hasInfix "network: private IPv4 ingress" privateTable
    && lib.hasInfix "network: reject non-loopback HTTP" privateTable
    && !(lib.hasInfix "192.0.2.2" privateRemovedConfig.networking.nftables.tables.network-edge-policy.content)
    && privateLastConfig.networking.nftables.tables.network-edge-policy.enable
    && !(lib.hasInfix "network: private IPv4 ingress" privateLastConfig.networking.nftables.tables.network-edge-policy.content)
    && defaultClaimConfig.networking.nftables.tables.network-edge-policy.enable
    && !(builtins.hasAttr "network-edge-policy" defaultEmptyConfig.networking.nftables.tables)
  );
  firewall-runtime = runtime;
  firewall-private-ingress-runtime = privateRuntime;
}
