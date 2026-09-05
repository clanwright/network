_: _: {
  _class = "clan.service";
  manifest = {
    name = "@clanwright/network-tcp-tuning";
    description = "Native host tcp-tuning capability";
    readme = builtins.readFile ./README.md;
  };
  roles.host = {
    description = "Enable native tcp-tuning configuration on the host";
    interface = _: {
      options = {

      };
    };
    perInstance = { settings, ... }: {
      nixosModule = _: {
        imports = [
          ../../modules/host/platform.nix
          (import ../../modules/host/tcp-tuning.nix { inherit settings; })
        ];
      };
    };
  };
}
