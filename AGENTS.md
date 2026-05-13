# PROJECT KNOWLEDGE BASE

**Branch:** master
**Scope:** ocsb sandbox framework, Nix flake packaging, wrapper tests

## OVERVIEW

ocsb is a Nix sandbox framework with bubblewrap as the default runtime backend and optional Podman/systemd-nspawn runners. The core is a generated launcher in `lib/mkSandbox.nix`; templates and modules feed it declarative options, while shell tests exercise wrapper behavior on Linux.

## STRUCTURE

```text
./
├── flake.nix              # package/check outputs, Ironclaw wrapper matrix
├── lib/mkSandbox.nix      # generated ocsb launcher and runtime state logic
├── modules/               # Nix module options for app/env/mounts/network/workspace/backend/experimental
├── templates/             # app presets: OpenCode and Ironclaw
├── pkgs/ironclaw.nix      # Ironclaw Rust package derivation and fixed-output deps
├── tests/test_*.sh        # wrapper, strategy, network, and Ironclaw regression tests
└── README.md              # user-facing usage and operations docs
```

Root AGENTS.md is sufficient for now: the repo is small and the complex behavior crosses `flake.nix`, `lib/`, `templates/`, `modules/`, and `tests/`.

## WHERE TO LOOK

| Task | Location | Notes |
|---|---|---|
| Change runtime launcher behavior | `lib/mkSandbox.nix` | Generated shell script; verify with wrapper tests. |
| Add/change options | `modules/*.nix` | Keep README and tests in sync. |
| Change runtime backend support | `modules/backend.nix`, `lib/mkSandbox.nix`, `tests/test_backend.sh` | Preserve bubblewrap default and explicit non-bwrap support boundaries. |
| Change Ironclaw sandbox | `flake.nix`, `templates/ironclaw.nix`, `tests/test_ironclaw.sh` | Wrapper owns persist dir and state redirection. |
| Change `/nix/store` mode | `lib/mkSandbox.nix`, `modules/experimental.nix` | Do not reintroduce overlayfs on `/nix/store`. |
| Change workspace strategies | `lib/mkSandbox.nix`, `tests/test_wrapper.sh`, strategy-specific tests | Keep state layout and cleanup covered. |
| Update user docs | `README.md` | Chinese user-facing docs are current style. |

## DEV STATE LAYOUT CONTRACT

- Default state base: `$HOME/.cache/ocsb/<project-hash>`.
- Override: `OCSB_STATE_BASE_DIR=/absolute/path`; relative paths must fail.
- Final per-workspace state: `$STATE_BASE_DIR/$WORKSPACE_NAME`, exported inside sandbox as `OCSB_STATE_DIR`.
- Chroot store mode uses `$OCSB_STATE_DIR/chroot/merged/nix/{store,var/nix}` and bind-mounts those paths as `/nix/store` and `/nix/var/nix`.
- Workspace overlayfs state lives under `$OCSB_STATE_DIR/overlay/workspace/{upper,work}`.
- `--overlay-mount` state lives under `$OCSB_STATE_DIR/overlay/mounts/ovl-<hash>/{upper,work}`.
- `--snap-mount` state lives under `$OCSB_STATE_DIR/snapshots/snap-<hash>` and requires the source to be a btrfs subvolume root.
- Legacy cleanup must continue removing old root-level `upper/work`, `ovl-*`, `snap-*`, and old `chroot/nix` layouts.

## BACKEND CONTRACT

- Default backend is `bubblewrap`; it remains the only full-parity backend.
- `backend.type` accepts `bubblewrap`, `podman`, `systemd-nspawn`; runtime override is `--backend ...`.
- Backend identity is recorded as `$OCSB_STATE_DIR/.backend`; do not add backend names into the state path layout.
- Podman/systemd-nspawn v1 reuse host-side prep: lock, `.strategy`, `OCSB_STATE_DIR`, chroot `/nix`, btrfs/git-worktree, `--ro`, `--rw`, and `--snap-mount`.
- Podman/systemd-nspawn v1 intentionally reject `workspace.strategy=overlayfs`, `--overlay-mount`, and `experimental.dualLayer`; do not fake parity.
- Podman maps host/blocked/filtered networking to native `host`/`none`/`slirp4netns:allow_host_loopback=false`; this is not the same as bwrap iptables private-range filtering.
- systemd-nspawn v1 runs the payload with `--user=$(id -u)` but may still require privileged host authorization to start nspawn itself.
- systemd-nspawn v1 supports host/no-network only; filtered networking must fail clearly.

## IRONCLAW CONTRACT

- Latest persist dir defaults to `~/.cache/ocsb/ironclaw/`; versioned wrappers use `~/.cache/ocsb/ironclaw_<version>/`; arch-optimized wrappers do NOT add arch suffixes to the persist dir.
- The wrapper exports `OCSB_STATE_BASE_DIR="$PERSIST_DIR/state"`, so ocsb state is stable at `$PERSIST_DIR/state/ironclaw/` regardless of launch cwd.
- App persistence is wrapper-mounted: `home/` as `/home/sandbox` and Ironclaw workspace/cwd, `data/`, and DB-mode-specific state (`pgdata`/`pgrun` for embedded, `pgdata-sidecar` plus `state/ironclaw-db.env` for sidecar/external DB env delivery). Do not create a separate Ironclaw `workspace/` persist dir.
- Sidecar DB container defaults to the fixed name `ocsb-ironclaw-db` across Ironclaw wrapper variants; `pgdata-sidecar` must be mounted at container `/var/lib/postgresql` for PostgreSQL 18+ images.
- Ironclaw workspace strategy is `direct` with sandboxDir `/home/sandbox`; cwd is not the caller's launch directory.
- Sandbox PATH includes Nix profile bins (`/home/sandbox/.nix-profile/bin` and `/nix/var/nix/profiles/default/bin`) so `nix profile install` outputs are immediately usable.
- Ironclaw network is host (`network.enable = null`) because PostgreSQL must not run as uid 0, while filtered slirp currently needs uid 0 inside the user namespace.
- Ironclaw preExec initializes PostgreSQL 18 + pgvector in embedded mode; external/sidecar modes source a private mounted DB env file, then set `IRONCLAW_DATA_DIR` and persist `SECRETS_MASTER_KEY` in app data.

## CONVENTIONS

- Commit messages are English semantic style: `fix(sandbox): ...`, `docs(sandbox): ...`, `test(sandbox): ...`.
- Git commands in this environment require `GIT_MASTER=1`.
- Shell examples in repo docs are Linux/bash-facing; local automation in this workspace runs under PowerShell.
- Prefer state outside the project tree; `.ocsb/<workspace>` is a marker/strategy workspace area, not the full implementation state.
- `chmod_tree_dirs_writable` intentionally chmods directories only. Do not recursively chmod read-only Nix store files.

## ANTI-PATTERNS

- Do not put `/nix/store` on overlayfs: root-owned lower + unprivileged userns copy-up causes ownership/permission failures.
- Do not claim Podman/systemd-nspawn overlay or filtered-network parity unless covered by tests.
- Do not make Ironclaw state depend on cwd or project hash.
- Do not remove legacy layout cleanup without replacing tests.
- Do not split implementation changes from their shell regression tests when committing.
- Do not install local tooling just to run checks; use existing Nix/dev tools or remote Linux verification.
- Do not build the Ironclaw Rust package (`pkgs/ironclaw.nix`) during local development; it is time-consuming and not needed to validate wrapper/template/test changes. Use `nix flake check --no-build` and `nix build .#packages.x86_64-linux.default` (which builds only the ocsb wrapper, not Ironclaw) for script-level verification. Only build `.#ironclaw-sandbox` or `.#ironclaw-sandbox_x86_64_v3` when explicitly requested or on CI.

## VERIFICATION GATES

```bash
nix flake check --no-build
nix build .#packages.x86_64-linux.default
bash tests/test_wrapper.sh ./result/bin/ocsb
bash tests/test_backend.sh .
bash tests/test_binpath.sh .
bash tests/test_git_worktree.sh ./result/bin/ocsb
bash tests/test_btrfs.sh ./result/bin/ocsb     # may SKIP without btrfs perms

nix build .#checks.x86_64-linux.net-test
nix build .#checks.x86_64-linux.dual-layer-test

nix build .#ironclaw-sandbox
bash tests/test_ironclaw.sh ./result/bin/ocsb-ironclaw
```

For Ironclaw arch-specific validation, build the matching output, e.g. `.#ironclaw-sandbox_x86_64_v3`, then run `tests/test_ironclaw.sh` against its wrapper.
