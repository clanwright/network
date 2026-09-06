{ pkgs }:
{
  caddy-custom = pkgs.caddy.withPlugins {
    plugins = [
      "github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@v0.0.0-20250118002110-d62c80d3dd2c"
      "github.com/mholt/caddy-ratelimit@v0.1.0"
    ];
    hash = "sha256-6IVvsr48egBDnX3hnSm0lxPbEmHK7GAr4V3ek+o0GGk=";
  };
}
