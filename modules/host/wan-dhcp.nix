{ settings }: { lib, ... }: {
  imports = [ ./wan-claims.nix ];
  networkCore.wan.claims = [
    {
      owner = "dhcp:${settings.interface}";
      inherit (settings) interface;
      mode = "dhcp";
    }
  ];
  networking = {
    useDHCP = false;
    useNetworkd = true;
    enableIPv6 = lib.mkIf (settings.enableIPv6 != null) settings.enableIPv6;
    interfaces.${settings.interface}.useDHCP = true;
  };
  systemd.network = {
    links."10-${settings.interface}" = {
      matchConfig.MACAddress = settings.macAddress;
      linkConfig.Name = settings.interface;
    };
  };
}
