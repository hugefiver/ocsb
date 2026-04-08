# Workspace branching strategy configuration
{ lib, ... }:
{
  options.workspace = {
    strategy = lib.mkOption {
      type = lib.types.enum [ "overlayfs" "btrfs" "git-worktree" "direct" ];
      default = "overlayfs";
      description = ''
        Workspace branching strategy:
        - overlayfs: CoW via bwrap --overlay (works on ext2/3/4, default)
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
  };
}
