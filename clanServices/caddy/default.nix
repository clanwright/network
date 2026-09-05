{ self }: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-caddy";
    description = "Pinned Caddy ingress and consumer-owned site declarations";
    readme = builtins.readFile ./README.md;
  };
  roles.ingress = {
    interface = _: { };
    perInstance = _: {
      nixosModule = { config, pkgs, ... }: {
        imports = [ ../../modules/caddy ];
        assertions = [
          {
            assertion =
              config.services.caddy.package.outPath == self.packages.x86_64-linux.caddy-custom.outPath;
            message = "network-caddy requires its release-pinned caddy-custom package.";
          }
          {
            assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
            message = "network-caddy supports x86_64-linux only.";
          }
        ];
        services.caddy.package = self.packages.x86_64-linux.caddy-custom;
      };
    };
  };
}
