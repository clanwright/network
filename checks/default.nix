{
  self,
  inputs,
  pkgs,
  root,
}:
let
  consume = import ./consumer.nix { inherit self inputs root; };
  instance = name: role: settings: {
    module = {
      input = "network";
      name = "@clanwright/${name}";
    };
    roles.${role}.machines.network-node.settings = settings;
  };
  gate =
    name: condition:
    let
      contract = if condition then true else throw "${name}: evaluated consumer contract failed";
    in
    if contract then
      pkgs.runCommand name { passthru = { inherit contract; }; } ''touch "$out"''
    else
      throw "${name}: evaluated consumer contract failed";
  caddy = consume { instances.caddy = instance "network-caddy" "ingress" { }; };
in
{
  consumer-caddy = gate "network-consumer-caddy" (
    caddy.valid
    && caddy.evaluated
    && caddy.machine.services.caddy.enable
    && caddy.machine.services.caddy.package == self.packages.x86_64-linux.caddy-custom
  );
}
// import ./caddy.nix {
  inherit
    self
    inputs
    pkgs
    consume
    instance
    gate
    ;
}
// import ./firewall.nix {
  inherit
    self
    inputs
    pkgs
    root
    consume
    instance
    gate
    ;
}
// import ./wan.nix {
  inherit
    self
    inputs
    pkgs
    root
    gate
    ;
}
// import ./acme.nix {
  inherit
    self
    inputs
    pkgs
    root
    gate
    ;
}
