{ settings }:
{ ... }:
{
  imports = [
    ../../lib/platform.nix
    ../../lib/wan.nix
  ];
  networking = {
    networkWanClaims = [
      {
        inherit (settings) interface macAddress;
        mode = "dhcp";
      }
    ];
    useDHCP = false;
    useNetworkd = true;
    interfaces.${settings.interface}.useDHCP = true;
  };
  systemd.network.links."10-${settings.interface}" = {
    matchConfig.MACAddress = settings.macAddress;
    linkConfig.Name = settings.interface;
  };
}
