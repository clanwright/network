{ settings }:
{ config, lib, ... }:
let
  bootstrap = settings.bootstrapSsh;
  destinations = settings.public.destinations;
  destinationAddresses = map (entry: entry.destinationIPv4) destinations;
  hostAddresses = lib.concatMap (interface: map (address: address.address) interface.ipv4.addresses) (
    lib.attrValues config.networking.interfaces
  );
  hostWide =
    protocol: port:
    builtins.elem port config.networking.firewall."allowed${protocol}Ports"
    || lib.any (
      range: range.from <= port && port <= range.to
    ) config.networking.firewall."allowed${protocol}PortRanges";
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
    ./private-ingress.nix
  ]
  ++ lib.optional bootstrap.enable (import ./bootstrap-ssh.nix { inherit settings; });

  assertions = [
    {
      assertion = !bootstrap.enable || bootstrap.publicIPv4 != null;
      message = "network firewall bootstrap SSH requires publicIPv4.";
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
    # A TCP reset from the native reject policy would expose the other addresses.
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
            assertion = !hostWide protocol port;
            message = "network firewall public destination ${entry.destinationIPv4} ${protocol} port ${toString port} is also accepted host-wide.";
          }) entry."allowed${protocol}Ports"
        )
        [
          "TCP"
          "UDP"
        ]
  ) destinations;

  networking.nftables = {
    enable = true;
    # The NixOS table manager emits per-table atomic replacement.  Never flush
    # runtime tables owned by Tailscale, fail2ban, containers, or an operator.
    flushRuleset = lib.mkForce false;
    tables."nixos-fw".content = lib.mkIf bootstrap.enable (
      lib.mkBefore ''
        set bootstrap_ssh_v4 {
          type ipv4_addr
          flags timeout
        }
      ''
    );
    tables.network-edge-policy =
      lib.mkIf (settings.rejectHttp || config.networkCore.firewall.privateIngressClaims != { })
        {
          family = "inet";
          content = ''
            chain input_guard {
              type filter hook input priority filter - 10; policy accept;

              ${lib.optionalString settings.rejectHttp ''iifname != "lo" tcp dport 80 drop comment "network: reject non-loopback HTTP"''}
              ${config.networkCore.firewall.privateIngressRules}
            }
          '';
        };
  };

  services.openssh.openFirewall = false;
  networking.firewall = {
    enable = true;
    backend = "nftables";
    allowPing = lib.mkForce false;
    inherit (settings.public) allowedTCPPorts;
    inherit (settings.public) allowedUDPPorts;
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
