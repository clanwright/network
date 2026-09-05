# tcp-tuning

Thin independently selectable Clan service, role `host`. Runtime is limited to
x86_64-linux.

No settings. Loads tcp_bbr and sets tcp_congestion_control=bbr,
tcp_slow_start_after_idle=0 and default_qdisc=fq through native NixOS options.
Does not change IPv6 or WAN/firewall configuration. Remove duplicate host
sysctls when migrating; select separately from the other host capabilities.
