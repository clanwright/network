{ lib }:
let
  isIPv4 =
    address:
    let
      octets = lib.splitString "." address;
      validOctet = octet: builtins.match "(0|[1-9][0-9]{0,2})" octet != null && lib.toInt octet <= 255;
    in
    builtins.length octets == 4 && lib.all validOctet octets;
  isDNSName =
    name:
    builtins.stringLength name <= 253
    && builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*" name != null
    && builtins.all (label: builtins.stringLength label <= 63) (lib.splitString "." name)
    && builtins.match "[0-9]+(\\.[0-9]+)*" name == null;
  isInterfaceName =
    name:
    builtins.stringLength name <= 15
    && builtins.match "[A-Za-z0-9_.-]+" name != null
    && builtins.match "[0-9]+" name == null
    && !(builtins.elem name [
      "."
      ".."
      "all"
      "default"
    ]);
in
{
  ipv4 = lib.types.addCheck lib.types.str isIPv4;
  dnsName = lib.types.addCheck lib.types.str isDNSName;
  interfaceName = lib.types.addCheck lib.types.str isInterfaceName;
}
