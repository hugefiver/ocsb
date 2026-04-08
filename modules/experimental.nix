# Experimental features — not enabled by default
#
# These features are functional but may have rough edges or change behavior
# in future releases.
{ lib, ... }:
{
  options.experimental = {
    dualLayer = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Dual-layer sandbox mode (experimental).

        Layer 1 (outer): filesystem isolation with host network — for the
        main application (e.g. opencode) that needs API access.

        Layer 2 (inner): full isolation (--unshare-all, including network)
        for tool-spawned commands. Achieved by setting $SHELL to a wrapper
        that runs each command inside a nested bubblewrap.

        When enabled:
        - The outer sandbox always uses host networking (--share-net),
          regardless of the network.enable setting.
        - $SHELL is set to the sandbox-shell wrapper.
        - Tool commands have no network access and limited filesystem view.
        - The network.enable / blockedRanges options are ignored.

        Requires the sandboxed application to use $SHELL for spawning
        commands (e.g. opencode reads $SHELL for its bash tool).
      '';
    };
  };
}
