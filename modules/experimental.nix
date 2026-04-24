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

    nixStoreOverlay = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Mount /nix/store as a writable overlayfs (instead of the default
        closure-only read-only mounts).

        Layout:
        - lower: host /nix/store (read-only)
        - upper: $OVERLAY_STATE_DIR/nix-store-upper (per-workspace, persistent)
        - work:  $OVERLAY_STATE_DIR/nix-store-work

        Effects:
        - `nix profile add` works inside the sandbox; cache.nixos.org binaries
          are usable because the store prefix is /nix/store on both sides.
        - Installed paths persist across runs of the same workspace and are
          discarded on `--reset`.

        Tradeoffs:
        - The entire host /nix/store is visible inside the sandbox (read-only
          via the lower layer), not just the package's transitive closure.
        - Slightly more kernel overhead per syscall on /nix/store than direct
          bind mounts.
      '';
    };
  };
}
