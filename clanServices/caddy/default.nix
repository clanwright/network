{ self }: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-caddy";
    description = "Pinned native Caddy ingress and consumer-owned virtual hosts";
    readme = builtins.readFile ./README.md;
  };
  roles.ingress = {
    description = "Run the pinned Caddy ingress with native virtual hosts";
    interface = _: { };
    perInstance = _: {
      nixosModule = import ./module.nix {
        package = self.packages.x86_64-linux.caddy-custom;
      };
    };
  };
}
