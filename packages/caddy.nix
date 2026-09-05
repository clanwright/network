{ apps-nixpkgs, system }:
let
  appsPkgs = import apps-nixpkgs { inherit system; };
in
{
  caddy-custom = appsPkgs.caddy.withPlugins {
    plugins = [
      "github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@v0.0.0-20250118002110-d62c80d3dd2c"
      "github.com/mholt/caddy-l4@v0.1.2"
      "github.com/mholt/caddy-ratelimit@v0.1.0"
    ];
    hash = "sha256-5Kjqmp00b9ru+0dX0kTMRMURv8YaM0MQujIKvKrFkZE=";
  };
}
