# ocsb

Nix sandbox for [OpenCode](https://github.com/opencode-ai/opencode) with isolated filesystem and workspace branching.

Uses [bubblewrap](https://github.com/containers/bubblewrap) to run AI coding agents in a restricted Linux namespace — limited `/nix/store` visibility, no network (by default), non-root identity, and copy-on-write workspace isolation.

## Features

- **Closure-only store** — only the transitive closure of declared packages is visible in `/nix/store` (typically ~100 paths, not thousands)
- **Workspace strategies** — `overlayfs` (copy-on-write, default), `btrfs` (snapshot), `git-worktree` (detached worktree)
- **Path mapping** — `~/.config/foo` on host mounts to `/home/sandbox/.config/foo` inside sandbox
- **Security hardening** — workspace name validation, symlink escape protection, per-workspace flock, shell-escaped config values, absolute Nix store paths for all host commands
- **Non-root identity** — sandbox runs with host uid/gid via `--uid`/`--gid`
- **Declarative config** — Nix module system for packages, mounts, env vars, workspace settings

## Requirements

- NixOS or Nix with flakes enabled
- Linux (x86_64 or aarch64)

## Quick Start

```bash
# Build the default sandbox
nix build github:hugefiver/ocsb

# Run (drops into bash inside sandbox)
./result/bin/ocsb

# Run with a named workspace
./result/bin/ocsb --workspace my-feature

# Continue an existing workspace
./result/bin/ocsb --workspace my-feature --continue

# Overwrite an existing workspace
./result/bin/ocsb --workspace my-feature --overwrite

# Use a different workspace strategy
./result/bin/ocsb --workspace my-feature --strategy git-worktree
```

## Custom Configuration

Create a flake that uses `ocsb` as input:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ocsb.url = "github:hugefiver/ocsb";
  };

  outputs = { nixpkgs, ocsb, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      mkSandbox = ocsb.lib.mkSandbox { system = "x86_64-linux"; };
    in {
      packages.x86_64-linux.default = mkSandbox ({ pkgs, ... }: {
        app.name = "my-sandbox";
        app.package = pkgs.opencode;
        app.binPath = "bin/opencode";

        packages = with pkgs; [ git ripgrep fd jq curl ];

        mounts.ro = [ "~/.config/opencode" ];
        mounts.rw = [];

        workspace = {
          strategy = "overlayfs";  # or "btrfs", "git-worktree", "direct"
          baseDir = ".ocsb";
          name = "_";
        };

        env = {
          EDITOR = "cat";
          LANG = "C.UTF-8";
        };
      });
    };
}
```

## Module Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `app.name` | string | `"ocsb"` | Sandbox executable name |
| `app.package` | package \| null | `null` | Package to sandbox (`null` = interactive bash) |
| `app.binPath` | string | `""` | Binary path within package (required when package is set) |
| `packages` | list of packages | `[]` | Packages available inside sandbox |
| `mounts.ro` | list of strings | `[]` | Read-only bind mounts (`~` expands correctly) |
| `mounts.rw` | list of strings | `[]` | Read-write bind mounts |
| `workspace.strategy` | enum | `"overlayfs"` | `overlayfs`, `btrfs`, `git-worktree`, or `direct` |
| `workspace.baseDir` | string | `".ocsb"` | Base directory for workspaces (relative to project) |
| `workspace.name` | string | `"_"` | Default workspace name |
| `env` | attrset | `{}` | Environment variables inside sandbox |

## Workspace Strategies

- **overlayfs** — Creates an overlay filesystem with project as lower, changes go to `~/.cache/ocsb/<hash>/<name>/upper`. Default and recommended.
- **btrfs** — Creates a btrfs subvolume snapshot. Requires project directory to be on a btrfs subvolume.
- **git-worktree** — Creates a detached `git worktree`. Requires project to be a git repository. Git operations work inside sandbox.
- **direct** — Bind-mounts project directory directly (no isolation).

## Tests

```bash
# Build, then run all tests
nix build .#packages.x86_64-linux.default
bash tests/run_all.sh ./result/bin/ocsb
```

## License

[MIT](LICENSE)
