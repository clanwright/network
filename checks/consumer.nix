{
  inputs,
  root,
  self,
}:
{
  instances,
  extraModule ? { },
}:
let
  consumer = inputs.clan-core.lib.clan {
    self.inputs = {
      network = self;
      self.clan = consumer.config;
    };
    specialArgs.clan-core = inputs.clan-core;
    # The fixture has no machine inventory on disk. Give Clan a materialized,
    # isolated directory instead of re-coercing the virtual Git flake root.
    directory = builtins.path {
      path = root + "/tests";
      name = "network-consumer-fixtures";
      filter = path: type: type == "directory" || builtins.baseNameOf path == "empty-sops.yaml";
    };
    imports = [
      {
        machines.network-node = _: {
          imports = [ extraModule ];
          nixpkgs.hostPlatform = "x86_64-linux";
          boot.isContainer = true;
          sops.defaultSopsFile = ../tests/empty-sops.yaml;
          sops.age.keyFile = "/run/network-fixture/age-key";
          system.stateVersion = "26.11";
        };
        inventory = {
          meta.name = "network-consumer-fixture";
          machines.network-node = { };
          inherit instances;
        };
      }
    ];
  };
  machine = consumer.config.nixosConfigurations.network-node.config;
in
{
  inherit machine;
  inherit (consumer) config;
  valid = builtins.all (a: a.assertion) machine.assertions;
  # Unit rendering proves the selected native integration. Forcing the whole
  # host closure adds unrelated filesystem/boot/package checks to every case.
  evaluated = builtins.deepSeq (builtins.mapAttrs (_: u: u.text) machine.systemd.units) true;
}
