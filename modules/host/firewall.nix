{ settings }:
{ lib, ... }:
let
  bootstrap = settings.bootstrapSsh;
in
{
  imports = lib.optional bootstrap.enable (import ./bootstrap-ssh.nix { inherit settings; });

  assertions = [
    {
      assertion = !bootstrap.enable || bootstrap.publicIPv4 != null;
      message = "network firewall bootstrap SSH requires publicIPv4.";
    }
  ];

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
    tables.network-edge-policy = lib.mkIf settings.rejectHttp {
      family = "inet";
      content = ''
        chain input_guard {
          type filter hook input priority filter - 10; policy accept;

          iifname != "lo" tcp dport 80 drop comment "network: reject non-loopback HTTP"
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
    extraInputRules = lib.mkIf bootstrap.enable (
      lib.mkBefore ''
        ip daddr @bootstrap_ssh_v4 tcp dport 22 accept comment "network: active bootstrap SSH"
      ''
    );
  };
}
