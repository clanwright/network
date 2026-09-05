{ self }: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-certificates";
    description = "Machine-local Timeweb DNS-01 certificate lifecycle";
    readme = builtins.readFile ./README.md;
  };
  roles.server = {
    interface = { lib, ... }: {
      options = {
        email = lib.mkOption {
          type = lib.types.str;
          description = "ACME account contact email.";
        };
        secretName = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*";
          default = "timeweb-dns-api-token";
          description = "Consumer-owned named SOPS Timeweb DNS credential.";
        };
        dnsResolver = lib.mkOption {
          type = lib.types.str;
          default = "1.1.1.1:53";
          description = "DNS resolver used for DNS-01 propagation.";
        };
      };
    };
    perInstance = { settings, ... }: {
      nixosModule = import ../../modules/certificates { inherit settings self; };
    };
  };
}
