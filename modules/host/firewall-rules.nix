{
  lib,
  pkgs,
  publicIPv4,
  bootstrapWanSshMarkerPath,
  bootstrapSsh,
  rejectHttp,
}:
let
  iptables = "${pkgs.iptables}/bin/iptables";
  ip6tables = "${pkgs.iptables}/bin/ip6tables";
  # This chain is private to this module.  Rules are converged inside it so
  # startup/teardown never has to delete an unmarked rule from INPUT.
  chain = "NIXOS_EDGE_FIREWALL";
  jumpComment = "edge-firewall:jump";
  sshComment = "edge-firewall:bootstrap-ssh";
  httpComment = "edge-firewall:reject-http";
in
{
  extraCommands = lib.mkAfter ''
    ensure_chain() {
      table="$1"
      if "$table" -nL ${lib.escapeShellArg chain} >/dev/null 2>&1; then
        "$table" -F ${lib.escapeShellArg chain}
      else
        "$table" -N ${lib.escapeShellArg chain}
      fi
    }
    remove_jump() {
      table="$1"
      while "$table" -D INPUT -m comment --comment ${lib.escapeShellArg jumpComment} -j ${lib.escapeShellArg chain} 2>/dev/null; do :; done
    }

    # Remove only the jump carrying this module's stable marker.  Existing
    # unmarked rules remain owned by whoever created them.
    remove_jump ${lib.escapeShellArg iptables}
    remove_jump ${lib.escapeShellArg ip6tables}

    # Migrate the exact unmarked IPv4 bootstrap rule created by the previous
    # version of this module. The older generic port-22 rule is deliberately
    # left untouched because it cannot be attributed to this owner safely.
    ${lib.optionalString bootstrapSsh ''
      while ${iptables} -D INPUT -p tcp -d ${lib.escapeShellArg publicIPv4}/32 --dport 22 -j ACCEPT 2>/dev/null; do :; done

    ''}
    ensure_chain ${lib.escapeShellArg iptables}
    ensure_chain ${lib.escapeShellArg ip6tables}

    # Keep this jump before fail2ban jumps in INPUT, while all rules it owns
    # remain isolated in the dedicated chain.
    ${iptables} -I INPUT 1 -m comment --comment ${lib.escapeShellArg jumpComment} -j ${lib.escapeShellArg chain}
    ${ip6tables} -I INPUT 1 -m comment --comment ${lib.escapeShellArg jumpComment} -j ${lib.escapeShellArg chain}

    ${lib.optionalString bootstrapSsh ''
      if [ -e ${lib.escapeShellArg bootstrapWanSshMarkerPath} ]; then
        ${iptables} -A ${lib.escapeShellArg chain} -p tcp -d ${lib.escapeShellArg publicIPv4}/32 --dport 22 -m comment --comment ${lib.escapeShellArg sshComment} -j ACCEPT
      fi
    ''}
    ${lib.optionalString rejectHttp ''
      ${iptables} -A ${lib.escapeShellArg chain} -p tcp --dport 80 ! -i lo -m comment --comment ${lib.escapeShellArg httpComment} -j DROP
      ${ip6tables} -A ${lib.escapeShellArg chain} -p tcp --dport 80 ! -i lo -m comment --comment ${lib.escapeShellArg httpComment} -j DROP
    ''}
  '';

  extraStopCommands = lib.mkAfter ''
    remove_jump() {
      table="$1"
      while "$table" -D INPUT -m comment --comment ${lib.escapeShellArg jumpComment} -j ${lib.escapeShellArg chain} 2>/dev/null; do :; done
    }
    remove_jump ${lib.escapeShellArg iptables}
    remove_jump ${lib.escapeShellArg ip6tables}

    # The chain is dedicated to this module, so flushing/removing it cannot
    # affect an unowned INPUT rule.  Unmarked legacy INPUT rules are left alone.
    for table in ${lib.escapeShellArg iptables} ${lib.escapeShellArg ip6tables}; do
      if "$table" -nL ${lib.escapeShellArg chain} >/dev/null 2>&1; then
        "$table" -F ${lib.escapeShellArg chain} 2>/dev/null || true
        "$table" -X ${lib.escapeShellArg chain} 2>/dev/null || true
      fi
    done
  '';
}
