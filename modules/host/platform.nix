{ pkgs, ... }: {
  assertions = [
    {
      assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
      message = "clanwright/network host services support x86_64-linux only.";
    }
  ];
}
