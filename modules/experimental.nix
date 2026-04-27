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
      type = lib.types.enum [ "chroot" "overlay" "closure" ];
      default = "chroot";
      description = ''
        How /nix/store is exposed inside the sandbox.

        "chroot" (default, recommended):
          A relocated, fully writable nix store lives at
          $OVERLAY_STATE_DIR/chroot/nix/{store,var/nix} on the host and is
          bind-mounted onto /nix/store and /nix/var/nix inside. On first
          launch (and whenever the package set changes) the launcher runs
          `nix copy` to populate it from the host store.

          Pros:
          - `nix profile add nixpkgs#foo` works inside the sandbox and can
            pull from cache.nixos.org (the in-sandbox prefix is /nix/store,
            matching cache signatures).
          - User-installed packages persist per-workspace and are wiped on
            `--reset`.
          - No copy-up issues; the store is owned by the calling user.

          Cons:
          - First launch performs a `nix copy` of the package closure into
            the chroot directory (one-time per workspace, can be slow and
            consumes disk).

        "overlay":
          Mount /nix/store as an overlayfs with the host /nix/store as the
          read-only lower layer and a per-workspace upper layer at
          $OVERLAY_STATE_DIR/nix-store-upper.

          Pros:
          - No initial copy cost; host store paths are visible immediately.

          Cons:
          - Copy-up of host root-owned files fails under unprivileged
            user namespaces on most kernels (EPERM on chmod), so anything
            that triggers copy-up of pre-existing /nix/store entries
            (including some `nix build` operations) will fail.
          - The entire host /nix/store is visible (read-only) inside the
            sandbox, not just the package's transitive closure.

        "closure":
          Mount only the transitive closure of the configured packages as
          individual --ro-bind entries. No writes possible.

          Pros:
          - Smallest attack surface; only declared deps are visible.
          - Lowest setup cost.

          Cons:
          - Cannot install additional packages from inside the sandbox.
      '';
    };
  };
}
