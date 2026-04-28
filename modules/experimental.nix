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

    nixStoreMode = lib.mkOption {
      type = lib.types.enum [ "chroot" "host-daemon" "closure" ];
      default = "chroot";
      description = ''
        How /nix/store is exposed inside the sandbox.

        "chroot" (default, recommended):
          A relocated, fully writable nix store lives at
          $OVERLAY_STATE_DIR/chroot/nix/{store,var/nix} on the host and is
          bind-mounted onto /nix/store and /nix/var/nix inside. On first
          launch (and whenever the package set changes) the launcher first
          tries to preseed it with hard links plus Nix DB registration, then
          falls back to `nix copy` when hard linking is unavailable.

          Pros:
          - `nix profile add nixpkgs#foo` works inside the sandbox and can
            pull from cache.nixos.org (the in-sandbox prefix is /nix/store,
            matching cache signatures).
          - User-installed packages persist per-workspace and are wiped on
            `--reset`.
          - No copy-up issues; the store is owned by the calling user.

          Cons:
          - First launch may still perform a `nix copy` of the package closure
            into the chroot directory when /nix/store and the workspace are on
            different filesystems or hard links are blocked.

        "host-daemon":
          Bind-mount the host /nix/store read-only and the host
          /nix/var/nix/daemon-socket/socket into the sandbox, then force Nix
          clients to use the daemon via NIX_REMOTE=daemon.

          Pros:
          - No initial copy cost; host store paths are visible immediately.
          - Installing packages can reuse the host daemon and binary cache.

          Cons:
          - Least isolated store mode: the entire host /nix/store is visible.
          - Mutations are delegated to the host nix-daemon, so daemon-side
            allowed-users / trusted-users / substituter policy must be tight.
          - Requires a multi-user Nix installation with the daemon socket.

        "closure":
          Mount only the transitive closure of the configured packages as
          individual --ro-bind entries. No writes possible.

          Pros:
          - Smallest attack surface; only declared deps are visible.
          - Lowest setup cost.

          Cons:
          - Cannot install additional packages from inside the sandbox.

        Note: this option only controls /nix/store. Workspace overlayfs is
        configured separately via workspace.strategy = "overlayfs" and remains
        supported for user-owned project files.
      '';
    };
  };
}
