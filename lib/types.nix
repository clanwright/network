{ lib }:
let
  isIPv4 =
    address:
    let
      octets = lib.splitString "." address;
      validOctet = octet: builtins.match "(0|[1-9][0-9]{0,2})" octet != null && lib.toInt octet <= 255;
    in
    builtins.length octets == 4 && lib.all validOctet octets;
in
{
  ipv4 = lib.types.addCheck lib.types.str isIPv4;
}
