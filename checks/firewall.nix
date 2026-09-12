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
  firewall-runtime = runtime;
}
