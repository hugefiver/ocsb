# Workspace branching strategy configuration
{ lib, ... }:
{
  options.workspace = {
    strategy = lib.mkOption {
      type = lib.types.enum [ "auto" "overlayfs" "btrfs" "git-worktree" "direct" ];
      default = "auto";
      description = ''
        Workspace branching strategy:
        - auto: detect filesystem — use btrfs snapshot if available, otherwise overlayfs (default)
        - overlayfs: CoW via bwrap --overlay (works on any filesystem)
        - btrfs: btrfs subvolume snapshots (requires btrfs filesystem)
        - git-worktree: git worktree based branching (requires git repo)
        - direct: plain read-write bind mount (no isolation)
      '';
    };

    baseDir = lib.mkOption {
      type = lib.types.addCheck lib.types.str (v:
        v != ""
        && !(lib.hasPrefix "/" v)
        && !(lib.hasInfix ".." v)
      );
      default = ".ocsb";
      description = ''
        Base directory for workspace storage, relative to project root.
        Each workspace is stored as a subdirectory.
        Must be a relative path and cannot contain '..' components.
      '';
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "_";
      description = ''
        Default workspace name. "_" is the unnamed default.
        Users can override at runtime with --workspace flag.
      '';
    };

    sandboxDir = lib.mkOption {
      type = lib.types.addCheck lib.types.str (v:
        lib.hasPrefix "/" v
        && v != "/"
        && !(lib.hasSuffix "/" v)
        && !(lib.hasInfix ".." v)
      );
      default = "/workspace";
      description = ''
        Absolute path where the selected workspace is mounted inside the sandbox.
        Relative CLI mount destinations resolve under this directory.
      '';
    };
  };
}
