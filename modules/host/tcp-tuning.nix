_: _: {
  boot.kernelModules = [ "tcp_bbr" ];
  boot.kernel.sysctl = {
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.ipv4.tcp_slow_start_after_idle" = 0;
    "net.core.default_qdisc" = "fq";
  };
}
