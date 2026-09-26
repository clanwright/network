{
  consume,
  gate,
  instance,
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;
  fixture = instance "network-firewall" "host" {
    public = {
      allowedTCPPorts = [ 443 ];
      allowedUDPPorts = [ 443 ];
    };
    interfaces.fixture0.allowedTCPPorts = [ 22 ];
    bootstrapSsh = {
      enable = true;
      publicIPv4 = "192.0.2.2";
      markerPath = "/build/network-bootstrap/allow-wan-ssh";
    };
    rejectHttp = true;
  };
  consumer = consume { instances.firewall = fixture; };
  firewallConfig = consumer.machine;
  stricterConsumer = consume {
    instances.firewall = fixture;
    extraModule.services.openssh.settings.AuthenticationMethods = "publickey,publickey";
  };
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
      extraModule.networkCore.firewall.privateIngressClaims = claims;
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
  privateApply = pkgs.writeText "network-private-ingress-apply.nft" (
    lib.concatStrings (
      lib.mapAttrsToList tableDeletion (
        lib.filterAttrs (_: table: table.enable) privateConfig.networking.nftables.tables
      )
    )
    + lib.concatStrings (
      lib.mapAttrsToList tableDefinition (
        lib.filterAttrs (_: table: table.enable) privateConfig.networking.nftables.tables
      )
    )
  );
  privateRemovedConfig = (privateConsumer { inherit (composedClaims) other; }).machine;
  privateOneRemovedConfig =
    (privateConsumer {
      inherit (composedClaims) second other;
    }).machine;
  privateOneRemovedApply = pkgs.writeText "network-private-ingress-one-removed.nft" (
    lib.concatStrings (
      lib.mapAttrsToList tableDeletion (
        lib.filterAttrs (_: table: table.enable) privateOneRemovedConfig.networking.nftables.tables
      )
    )
    + lib.concatStrings (
      lib.mapAttrsToList tableDefinition (
        lib.filterAttrs (_: table: table.enable) privateOneRemovedConfig.networking.nftables.tables
      )
    )
  );
  privateRemovedApply = pkgs.writeText "network-private-ingress-removed.nft" (
    lib.concatStrings (
      lib.mapAttrsToList tableDeletion (
        lib.filterAttrs (_: table: table.enable) privateRemovedConfig.networking.nftables.tables
      )
    )
    + lib.concatStrings (
      lib.mapAttrsToList tableDefinition (
        lib.filterAttrs (_: table: table.enable) privateRemovedConfig.networking.nftables.tables
      )
    )
  );
  privateLastConfig = (privateConsumer { }).machine;
  privateLastApply = pkgs.writeText "network-private-ingress-last.nft" (
    lib.concatStrings (
      lib.mapAttrsToList tableDeletion (
        lib.filterAttrs (_: table: table.enable) privateLastConfig.networking.nftables.tables
      )
    )
    + lib.concatStrings (
      lib.mapAttrsToList tableDefinition (
        lib.filterAttrs (_: table: table.enable) privateLastConfig.networking.nftables.tables
      )
    )
  );
  defaultPrivateConsumer =
    claims:
    consume {
      instances.firewall = instance "network-firewall" "host" { public.allowedTCPPorts = [ 443 ]; };
      extraModule.networkCore.firewall.privateIngressClaims = claims;
    };
  defaultClaimConfig = (defaultPrivateConsumer oneClaim).machine;
  defaultEmptyConfig = (defaultPrivateConsumer { }).machine;
  defaultClaimApply = pkgs.writeText "network-private-ingress-default-claim.nft" (
    lib.concatStrings (
      lib.mapAttrsToList tableDeletion (
        lib.filterAttrs (_: table: table.enable) defaultClaimConfig.networking.nftables.tables
      )
    )
    + lib.concatStrings (
      lib.mapAttrsToList tableDefinition (
        lib.filterAttrs (_: table: table.enable) defaultClaimConfig.networking.nftables.tables
      )
    )
  );
  defaultEmptyApply = pkgs.writeText "network-private-ingress-default-empty.nft" (
    # The pinned native nftables reload deletes tables declared by the previous
    # generation before applying the new generation, even when no longer declared.
    ''
      table inet network-edge-policy
      delete table inet network-edge-policy
    ''
    + lib.concatStrings (
      lib.mapAttrsToList tableDeletion (
        lib.filterAttrs (_: table: table.enable) defaultEmptyConfig.networking.nftables.tables
      )
    )
    + lib.concatStrings (
      lib.mapAttrsToList tableDefinition (
        lib.filterAttrs (_: table: table.enable) defaultEmptyConfig.networking.nftables.tables
      )
    )
  );
  enabledTables = lib.filterAttrs (_: table: table.enable) firewallConfig.networking.nftables.tables;
  tableDeletion = _: table: ''
    table ${table.family} ${table.name}
    delete table ${table.family} ${table.name}
  '';
  tableDefinition = _: table: ''
    table ${table.family} ${table.name} {
      ${table.content}
    }
  '';
  applyRules = pkgs.writeText "network-firewall-apply.nft" (
    lib.concatStrings (lib.mapAttrsToList tableDeletion enabledTables)
    + lib.concatStrings (lib.mapAttrsToList tableDefinition enabledTables)
  );
  stopRules = pkgs.writeText "network-firewall-stop.nft" (
    lib.concatStrings (lib.mapAttrsToList tableDeletion enabledTables)
  );
  refresh = firewallConfig.systemd.services.network-bootstrap-ssh-refresh.serviceConfig.ExecStart;
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
          pkgs.netcat-openbsd
          pkgs.nftables
          pkgs.util-linux
        ];
        APPLY_RULES = applyRules;
        STOP_RULES = stopRules;
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
          pkgs.netcat-openbsd
          pkgs.nftables
          pkgs.python3
          pkgs.util-linux
        ];
        APPLY_RULES = privateApply;
        ONE_REMOVED_RULES = privateOneRemovedApply;
        REMOVED_RULES = privateRemovedApply;
        LAST_RULES = privateLastApply;
        DEFAULT_CLAIM_RULES = defaultClaimApply;
        DEFAULT_EMPTY_RULES = defaultEmptyApply;
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
