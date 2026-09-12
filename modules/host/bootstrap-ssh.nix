{ settings }:
{
  lib,
  pkgs,
  ...
}:
let
  cfg = settings.bootstrapSsh;
  commonEnvironment = ''
    export MARKER_PATH=${lib.escapeShellArg cfg.markerPath}
    export PUBLIC_IPV4=${lib.escapeShellArg cfg.publicIPv4}
    export MAX_WINDOW_SECONDS=${lib.escapeShellArg (toString cfg.durationSeconds)}
    export NFT=${lib.escapeShellArg "${pkgs.nftables}/bin/nft"}
  '';
  refresh = pkgs.writeShellApplication {
    name = "network-bootstrap-ssh-refresh";
    runtimeInputs = [ pkgs.coreutils ];
    text =
      commonEnvironment
      + builtins.readFile ./bootstrap-ssh-marker.sh
      + builtins.readFile ./bootstrap-ssh-refresh.sh;
  };
  renew = pkgs.writeShellApplication {
    name = "network-bootstrap-ssh-renew";
    runtimeInputs = [ pkgs.coreutils ];
    text =
      commonEnvironment
      + ''
        export REFRESH=${lib.escapeShellArg (lib.getExe refresh)}
      ''
      + builtins.readFile ./bootstrap-ssh-marker.sh
      + builtins.readFile ./bootstrap-ssh-renew.sh;
  };
in
{
  environment.systemPackages = [
    refresh
    renew
  ];

  # A reload recreates the owned set.  Repopulate it from the absolute marker
  # deadline, preserving elapsed time across reloads and boots.
  systemd.services.nftables.serviceConfig = {
    ExecStartPost = [ (lib.getExe refresh) ];
    ExecReload = lib.mkAfter [ (lib.getExe refresh) ];
  };
  systemd.services.network-bootstrap-ssh-refresh = {
    description = "Converge the bounded bootstrap SSH nftables timeout";
    after = [ "nftables.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe refresh;
    };
  };

  services.openssh.settings = {
    PasswordAuthentication = lib.mkForce false;
    KbdInteractiveAuthentication = lib.mkForce false;
    AuthenticationMethods = lib.mkDefault "publickey";
  };

  assertions = [
    {
      assertion = cfg.durationSeconds > 0 && cfg.durationSeconds <= 3600;
      message = "network firewall bootstrap SSH duration must be between 1 and 3600 seconds.";
    }
    {
      assertion = lib.hasPrefix "/" cfg.markerPath;
      message = "network firewall bootstrap SSH markerPath must be absolute.";
    }
  ];
}
