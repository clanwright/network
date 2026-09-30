{ settings }:
{ config, lib, ... }:
let
  bootstrap = settings.bootstrapSsh;
  destinations = settings.public.destinations;
  destinationAddresses = map (entry: entry.destinationIPv4) destinations;
  hostAddresses = lib.concatMap (interface: map (address: address.address) interface.ipv4.addresses) (
    lib.attrValues config.networking.interfaces
  );
  staticClaims = lib.filter (claim: claim.mode == "static") config.networking.networkWanClaims;
  acceptsPort =
    protocol: port: scope:
    builtins.elem port scope."allowed${protocol}Ports"
    || lib.any (range: range.from <= port && port <= range.to) scope."allowed${protocol}PortRanges";
  contradictory =
    protocol: port:
    acceptsPort protocol port config.networking.firewall
    || lib.any (acceptsPort protocol port) (lib.attrValues config.networking.firewall.interfaces);
  destinationRule =
    protocol: address: ports:
    lib.optionalString (ports != [ ]) ''
      ip daddr ${address} ${protocol} dport { ${
        lib.concatMapStringsSep ", " toString ports
      } } accept comment "network: public destination ingress"
    '';
in
{
  imports = [
    ../../lib/platform.nix
    ../../lib/wan.nix
    ./private-ingress.nix
  ]
  ++ lib.optional (bootstrap.enable && bootstrap.publicIPv4 != null) (
    import ./bootstrap-ssh.nix { inherit settings; }
  );
  assertions = [
    {
      assertion = config.networking.firewall.networkBaseOwner;
      message = "network firewall requires one base owner.";
    }
    {
      assertion = !bootstrap.enable || bootstrap.publicIPv4 != null;
      message = "network firewall bootstrap SSH requires publicIPv4.";
    }
    {
      assertion =
        !bootstrap.enable || lib.all (claim: claim.primaryIPv4 == bootstrap.publicIPv4) staticClaims;
      message = "network firewall bootstrap SSH on a static WAN must use its primary management IPv4, never an additional protocol address.";
    }
    {
      assertion = lib.length (lib.unique destinationAddresses) == lib.length destinationAddresses;
      message = "network firewall public destinations must be distinct IPv4 addresses.";
    }
  ]
  ++ map (address: {
    assertion = builtins.elem address hostAddresses;
    message = "network firewall public destination ${address} is not configured in networking.interfaces on this host.";
  }) destinationAddresses
  ++ lib.optional (destinations != [ ]) {
    assertion = !config.networking.firewall.rejectPackets;
    message = "network firewall public destinations require the native silent drop; disable networking.firewall.rejectPackets.";
  }
  ++ lib.concatMap (
    entry:
    [
      {
        assertion = entry.allowedTCPPorts != [ ] || entry.allowedUDPPorts != [ ];
        message = "network firewall public destination ${entry.destinationIPv4} declares no ports.";
      }
    ]
    ++
      lib.concatMap
        (
          protocol:
          map (port: {
            assertion = !contradictory protocol port;
            message = "network firewall public destination ${entry.destinationIPv4} ${protocol} port ${toString port} is also accepted by a global or interface-wide native port declaration.";
          }) entry."allowed${protocol}Ports"
        )
        [
          "TCP"
          "UDP"
        ]
  ) destinations;
  networking.nftables = {
    enable = true;
    flushRuleset = lib.mkForce false;
    tables."nixos-fw".content = lib.mkIf bootstrap.enable (
      lib.mkBefore ''
        set bootstrap_ssh_v4 {
          type ipv4_addr
          flags timeout
        }
      ''
    );
    tables.network-edge-policy = lib.mkIf settings.rejectHttp {
      family = "inet";
      content = ''
        chain http_guard {
          type filter hook input priority filter - 10; policy accept;
          iifname != "lo" tcp dport 80 drop comment "network: reject non-loopback HTTP"
        }
      '';
    };
  };
  services.openssh.openFirewall = false;
  networking.firewall = {
    networkBaseOwner = true;
    enable = true;
    backend = "nftables";
    allowPing = lib.mkForce false;
    inherit (settings.public) allowedTCPPorts allowedUDPPorts;
    inherit (settings) interfaces;
    extraInputRules = lib.mkMerge [
      (lib.mkIf bootstrap.enable (
        lib.mkBefore ''
          ip daddr @bootstrap_ssh_v4 tcp dport 22 accept comment "network: active bootstrap SSH"
        ''
      ))
      (lib.concatMapStrings (
        entry:
        destinationRule "tcp" entry.destinationIPv4 entry.allowedTCPPorts
        + destinationRule "udp" entry.destinationIPv4 entry.allowedUDPPorts
      ) destinations)
    ];
  };
}
