# ocsb

Nix sandbox for [OpenCode](https://github.com/opencode-ai/opencode) with isolated filesystem, network isolation, and workspace branching.

Uses [bubblewrap](https://github.com/containers/bubblewrap) to run AI coding agents in a restricted Linux namespace — limited `/nix/store` visibility, configurable network isolation, non-root identity, and copy-on-write workspace isolation.

## Features

- **Closure-only store** — only the transitive closure of declared packages is visible in `/nix/store` (typically ~100 paths, not thousands)
- **Workspace strategies** — `overlayfs` (copy-on-write, default), `btrfs` (snapshot), `git-worktree` (detached worktree), `direct` (bind mount)
- **Network isolation** — three modes: host network (default), filtered (slirp4netns + iptables), or no network
- **Dual-layer sandbox** — experimental: outer sandbox with host network for the app, inner sandbox with no network for tool commands
- **Runtime mounts** — `--ro`/`--rw` CLI flags for ad-hoc bind mounts with path validation
- **Security hardening** — capability drop, iptables fail-closed verification, workspace name validation, symlink escape protection, git metadata boundary checks
- **Non-root identity** — sandbox runs with host uid/gid via `--uid`/`--gid`
- **Declarative config** — Nix module system for packages, mounts, env vars, workspace settings

## Requirements

- NixOS or Nix with flakes enabled
- Linux (x86_64 or aarch64)

## Quick Start

```bash
nix build github:hugefiver/ocsb

# Interactive bash inside sandbox
./result/bin/ocsb

# Named workspace with overlayfs isolation
./result/bin/ocsb --workspace my-feature

# Continue existing workspace
./result/bin/ocsb --workspace my-feature --continue

# Overwrite workspace
./result/bin/ocsb --workspace my-feature --overwrite

# Different strategy
./result/bin/ocsb --workspace my-feature --strategy git-worktree

# Ad-hoc mounts
./result/bin/ocsb --ro ~/data:/workspace/data --rw /tmp/out:/workspace/out

# Per-directory overlay mount (CoW isolation for a specific directory)
./result/bin/ocsb --overlay-mount /data/models:/workspace/models

# Per-directory btrfs snapshot mount (requires btrfs source)
./result/bin/ocsb --snap-mount /data/datasets:/workspace/datasets

# Run a command directly
./result/bin/ocsb -- echo "hello from sandbox"
```

## Custom Configuration

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
          strategy = "overlayfs";
          baseDir = ".ocsb";
          name = "_";
        };

        # Filtered network: public internet OK, private ranges blocked
        network.enable = true;

        # Or: dual-layer (experimental)
        # experimental.dualLayer = true;

        env = {
          EDITOR = "cat";
          LANG = "C.UTF-8";
        };
      });
    };
}
```

## Module Options

### Core

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `app.name` | string | `"ocsb"` | Sandbox executable name |
| `app.package` | package \| null | `null` | Package to sandbox (`null` = interactive bash) |
| `app.binPath` | string | `""` | Binary path within package |
| `packages` | list of packages | `[]` | Packages available inside sandbox |
| `env` | attrset | `{}` | Environment variables inside sandbox |

### Mounts

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `mounts.ro` | list of strings | `[]` | Read-only bind mounts (`~` maps to `/home/sandbox`) |
| `mounts.rw` | list of strings | `[]` | Read-write bind mounts |

### Workspace

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `workspace.strategy` | enum | `"auto"` | `auto` (detect btrfs, fallback overlayfs), `overlayfs`, `btrfs`, `git-worktree`, or `direct` |
| `workspace.baseDir` | string | `".ocsb"` | Base directory for workspaces (relative to project) |
| `workspace.name` | string | `"_"` | Default workspace name |

### Network

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `network.enable` | null \| bool | `null` | `null` = host network, `true` = filtered (slirp4netns), `false` = no network |
| `network.blockedRanges` | list of strings | RFC1918 + link-local | CIDR ranges blocked by iptables in filtered mode |

### Experimental

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `experimental.dualLayer` | bool | `false` | Dual-layer sandbox: outer has host network, tool commands run in inner sandbox with no network |

## Network Isolation

### Modes

- **Host** (`network.enable = null`, default) — shares the host network stack, no isolation
- **Filtered** (`network.enable = true`) — slirp4netns provides NAT'd outbound internet; iptables blocks private/link-local ranges; capabilities dropped after firewall setup
- **None** (`network.enable = false`) — `--unshare-net` only, no connectivity

### Filtered Mode Security

When `network.enable = true`:

1. slirp4netns creates a TAP device with NAT and `--disable-host-loopback`
2. iptables adds DROP rules for each `blockedRanges` entry (best-effort installation)
3. All DROP rules are post-verified with `iptables -C` — if any fail and iptables is available, the sandbox aborts (fail-closed)
4. If iptables is unavailable (e.g. WSL2 kernel restriction), isolation is still enforced by the network namespace + slirp4netns
5. All capabilities are dropped via `setpriv --bounding-set=-all` before executing the payload

### Dual-Layer Mode (Experimental)

When `experimental.dualLayer = true`:

- **Layer 1 (outer)**: filesystem isolation with host network — the main app (e.g. opencode) can reach LLM APIs
- **Layer 2 (inner)**: `$SHELL` is replaced with a wrapper that runs every command in a nested bubblewrap with `--unshare-all` (no network, isolated namespaces)
- Tool commands spawned by the app have no internet access and a minimal filesystem view
- Only `$SHELL --version` and `$SHELL --help` pass through without inner isolation (for shell detection)

## Workspace Strategies

- **auto** (default) — detects filesystem at runtime: uses btrfs snapshot if project is on a btrfs subvolume, otherwise falls back to overlayfs.
- **overlayfs** — overlay filesystem with project as lower, changes at `~/.cache/ocsb/<hash>/<name>/upper`.
- **btrfs** — btrfs subvolume snapshot. Requires btrfs filesystem.
- **git-worktree** — detached git worktree. Requires git repository. Git operations work inside sandbox.
- **direct** — bind-mounts project directory directly (no isolation).

### Per-Directory Mounts

In addition to the workspace strategy, you can mount specific host directories with CoW isolation:

- `--overlay-mount HOST:SANDBOX` — mounts a host directory into the sandbox using overlayfs (changes stored in `~/.cache/ocsb/`)
- `--snap-mount HOST:SANDBOX` — mounts a host directory using a btrfs snapshot (requires source to be a btrfs subvolume)

## Ironclaw template

This repository now includes an `ironclaw` template for running [NEAR AI Ironclaw](https://github.com/nearai/ironclaw) (Rust + PostgreSQL + pgvector) inside an isolated ocsb bubblewrap sandbox.

- Latest package: `.#ironclaw` / `.#ironclaw-sandbox` (`result/bin/ocsb-ironclaw`)
- Versioned packages (last 3 releases tracked):
  - `.#ironclaw_v0_26_0` / `.#ironclaw-sandbox_v0_26_0` (latest, alias of `.#ironclaw{,-sandbox}`)
  - `.#ironclaw_v0_25_0` / `.#ironclaw-sandbox_v0_25_0`
  - `.#ironclaw_v0_24_0` / `.#ironclaw-sandbox_v0_24_0`

Each version has its own pinned `flake` input (`ironclaw-src`, `ironclaw-src-v0_25_0`, `ironclaw-src-v0_24_0`) and independent persistence root.

#### Bumping to a new release

1. Find the new tag on https://github.com/nearai/ironclaw/releases
2. Demote the current `ironclaw-src` (latest) to a versioned input (e.g. `ironclaw-src-v0_26_0`).
3. Drop the oldest versioned input (e.g. `ironclaw-src-v0_24_0`) so only the last 3 are tracked.
4. Point `ironclaw-src` at the new tag: `github:nearai/ironclaw/ironclaw-vX.Y.Z`.
5. Update `ironclawVersions` in `flake.nix` (latest first).
6. `nix flake update ironclaw-src` (and the new versioned input).
7. `nix flake check --no-build` — if a new release introduces git deps not in `pkgs/ironclaw.nix` `allOutputHashes`, add the new entries (run a build to discover the missing hashes; nix prints them).

### Persistence

Per-version state under:

- latest: `~/.cache/ocsb/ironclaw/<workspace>/`
- versioned: `~/.cache/ocsb/ironclaw_v0_XX_X/<workspace>/`

Override with either:

- `OCSB_IRONCLAW_PERSIST_DIR=/absolute/path`
- `--persist-dir /absolute/path`

The host-side wrapper bind-mounts persistence subdirectories into the sandbox (home, postgres data/run dirs, ironclaw data dir, nix store dirs) before launch.

### Nix modes

Select mode with `OCSB_IRONCLAW_NIX_MODE`:

- `single-user` (default) — keeps Nix state under `$HOME/.local/nix/{store,var}`. Pure user-mode, no daemon.
- `isolated-store` — overlays a persistent upper layer over the closure-only `/nix/store`. Closest to "real Nix" while staying isolated from host.
- `portable` — stub; requires adding `DavHau/nix-portable` as a flake input (not packaged in nixpkgs).

A user-level `nix.conf` is generated at `$HOME/.config/nix/nix.conf` with:
`experimental-features = nix-command flakes`, `build-users-group = ` (empty),
`sandbox = false`, `cache.nixos.org` substituter, `accept-flake-config = true`.

### TUN integration

Filtered networking works with host-side TUN setups (e.g. Clash Verge Rev / Mihomo TUN mode). `network.tunDevice` (default: `"Mihomo"`) is currently informational and reserved for future sandbox-side TUN integration.

### Postgres + pgvector

The template uses `postgresql_18` with `pgvector` and starts PostgreSQL inside the sandbox on a Unix socket only (`/run/postgresql`). TCP listening is disabled.

### Security model

The runtime pipeline executes as the non-root host user. In filtered mode, sandbox setup briefly uses internal uid=0 to install firewall rules, then drops all capabilities and returns to host uid/gid before running the payload.

## Tests

```bash
# Build default package
nix build .#packages.x86_64-linux.default

# CLI, workspace, mounts
bash tests/test_wrapper.sh ./result/bin/ocsb

# app.package binary path
bash tests/test_binpath.sh .

# git-worktree strategy
bash tests/test_git_worktree.sh ./result/bin/ocsb

# Sandbox-internal tests (runs inside sandbox)
./result/bin/ocsb --strategy direct --overwrite -- bash /workspace/tests/test_sandbox.sh

# Network tests (requires network.enable = true build)
nix-build tests/net-test.nix -o result-net
./result-net/bin/ocsb-net-test --strategy direct --overwrite -- bash /workspace/tests/test_network.sh

# Dual-layer tests (requires experimental.dualLayer = true build)
nix-build tests/dual-layer-test.nix -o result-dual
./result-dual/bin/ocsb-dual-test --strategy direct --overwrite -- bash /workspace/tests/test_dual_layer.sh
```

## License

[MIT](LICENSE)
