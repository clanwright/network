{ settings }:
{ lib, pkgs, ... }:
let
  rules = import ./firewall-rules.nix {
    inherit lib pkgs;
    publicIPv4 =
      if settings.bootstrapSsh.publicIPv4 == null then "" else settings.bootstrapSsh.publicIPv4;
    bootstrapWanSshMarkerPath = settings.bootstrapSsh.markerPath;
    bootstrapSsh = settings.bootstrapSsh.enable;
    inherit (settings) rejectHttp;
  };
in
{
  assertions = [
    {
      assertion = !settings.bootstrapSsh.enable || settings.bootstrapSsh.publicIPv4 != null;
      message = "network firewall bootstrap SSH requires publicIPv4.";
    }
  ];
  services.openssh.openFirewall = false;
  networking.firewall = {
    enable = true;
    allowPing = lib.mkForce false;
    inherit (settings.public) allowedTCPPorts allowedUDPPorts;
    inherit (settings) interfaces;
    inherit (rules) extraCommands extraStopCommands;
  };
}
