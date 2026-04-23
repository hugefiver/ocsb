# Network isolation configuration
#
# Three modes:
#   network.enable = null  → share host network (no isolation, default)
#   network.enable = true  → filtered internet (slirp4netns + iptables, block private ranges)
#   network.enable = false → no network at all (--unshare-net only)
{ lib, ... }:
{
  options.network = {
    enable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Network isolation mode:
        - null (default): share host network stack (no isolation)
        - true: filtered internet via slirp4netns — public internet accessible,
          private/link-local ranges blocked by iptables (best-effort: requires
          kernel netfilter support in user namespaces). When iptables is
          unavailable, isolation is still provided by network namespace +
          slirp4netns --disable-host-loopback. When iptables IS available but
          rules fail to apply, the sandbox aborts (fail-closed).
        - false: no network connectivity at all
      '';
    };

    blockedRanges = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "169.254.0.0/16"
      ];
      description = ''
        CIDR ranges to block with iptables when network.enable = true.
        Default: RFC1918 private ranges + link-local.
        The slirp4netns virtual subnet (10.0.2.0/24) is automatically
        exempted so that the NAT gateway and DNS continue to work.
        When iptables is available, ALL ranges are verified after
        installation — if any rule fails, the sandbox aborts.
      '';
    };

    tunDevice = lib.mkOption {
      type = lib.types.str;
      default = "Mihomo";
      description = "Name of host TUN device used by Clash/Mihomo. Currently informational; reserved for future sandbox-side TUN integration.";
    };
  };
}
