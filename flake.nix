{
  description = "ocsb - Nix sandbox for OpenCode with isolated filesystem and workspace branching";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Track ironclaw releases. The "latest" alias (`ironclaw-src`) points at the
    # newest tag we ship; older releases are pinned independently and remain
    # buildable as `ironclaw_v0_25_0`, `ironclaw_v0_24_0`, etc. To bump:
    #   1. Move `ironclaw-src` to the new release tag.
    #   2. Add the previous tag here (e.g. ironclaw-src-v0_26_0) and register it
    #      in `ironclawVersions` below.
    #   3. Drop the oldest entry if the kept-window grows beyond 3 releases.
    ironclaw-src = {
      url = "github:nearai/ironclaw/ironclaw-v0.26.0";
      flake = false;
    };
    ironclaw-src-v0_25_0 = {
      url = "github:nearai/ironclaw/23fe1826842be5ac50bbac729f29d9d0d3ec8847";
      flake = false;
    };
    ironclaw-src-v0_24_0 = {
      url = "github:nearai/ironclaw/9bb699e95b08d11af0459fab1b70d51ccd55cf20";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, ironclaw-src, ironclaw-src-v0_25_0, ironclaw-src-v0_24_0, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      lib = nixpkgs.lib;

      mkPkgs = system: nixpkgs.legacyPackages.${system};

      # Latest first. The first entry's package becomes the unversioned
      # `ironclaw` / `ironclaw-sandbox` aliases.
      ironclawVersions = [
        { slug = "v0_26_0"; version = "0.26.0"; src = ironclaw-src; }
        { slug = "v0_25_0"; version = "0.25.0"; src = ironclaw-src-v0_25_0; }
        { slug = "v0_24_0"; version = "0.24.0"; src = ironclaw-src-v0_24_0; }
      ];

      # Micro-architecture variants. The first entry is the unsuffixed default
      # (psABI x86-64-v1, baseline). Additional entries produce parallel
      # packages with `_<archSlug>` appended to every name.
      ironclawArchs = [
        { archSlug = ""; microArch = "x86-64"; }
        { archSlug = "x86_64_v3"; microArch = "x86-64-v3"; }
      ];
    in
    {
      lib.mkSandbox = { system ? "x86_64-linux" }:
        let
          pkgs = mkPkgs system;
        in
        import ./lib/mkSandbox.nix { inherit pkgs; lib = nixpkgs.lib; };

      packages = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          mkSandbox = import ./lib/mkSandbox.nix { inherit pkgs; lib = nixpkgs.lib; };

          mkIronclawPackage = { src, version, microArch, ... }: pkgs.callPackage ./pkgs/ironclaw.nix {
            ironclaw-src = src;
            inherit version microArch;
          };

          mkIronclawSandboxBase = ironclawPackage: mkSandbox (import ./templates/ironclaw.nix {
            inherit pkgs ironclawPackage;
          });

          # `slug` is empty for the latest alias (-> `ocsb-ironclaw`,
          # persist dir `~/.cache/ocsb/ironclaw/`). For non-latest builds
          # `slug` becomes "_v0_25_0" so wrappers and persist dirs are
          # distinct per version.
          mkSandboxBin = { slug, ironclawSandboxBase }: pkgs.writeShellScriptBin "ocsb-ironclaw${slug}" ''
            set -euo pipefail

            VARIANT="ironclaw${slug}"
            PERSIST_DIR=""
            FILTERED_ARGS=()
            HAS_CONTINUE_OR_OVERWRITE=0
            SHELL_MODE=0

            usage() {
              cat <<EOF
            Usage: ocsb-$VARIANT [OPTIONS] [-- COMMAND...]

            Run NEAR AI Ironclaw inside an isolated ocsb sandbox with persistent
            postgres + pgvector and a sandboxed Nix environment.

            Options:
              --persist-dir DIR     Override persistent state directory.
                                    Default: \$HOME/.cache/ocsb/ironclaw
                                    (shared across all ironclaw variants).
              -w, --workspace NAME  Workspace name (passed through to ocsb).
              -s, --shell           Drop into bash inside the sandbox instead
                                    of starting ironclaw (postgres still set up).
              --attach              Attach to the currently-running sandbox
                                    instance (shares its postgres, env, mounts).
                                    Use --attach=PID to target a specific bwrap.
              -h, --help            Show this help and exit.
              --                    Pass remaining args to ironclaw / shell.

            Environment:
              OCSB_IRONCLAW_PERSIST_DIR  Same as --persist-dir.

            Persistent layout (under \$PERSIST_DIR):
              home/        \$HOME inside sandbox (config, history)
              data/        ironclaw application data
              pgdata/      PostgreSQL 18 cluster
              pgrun/       postgres unix socket

            Workspace cache (under \$HOME/.cache/ocsb/<hash>/ironclaw/):
              chroot/      relocated /nix/store (chroot mode, default)

            First run will: initdb, start postgres on unix socket, create
            'ironclaw' DB + load pgvector, then exec ironclaw. Run
            \`ironclaw onboard\` inside the sandbox to configure account.
            EOF
            }

            while [[ $# -gt 0 ]]; do
              case "$1" in
                -h|--help)
                  usage
                  exit 0
                  ;;
                -w|--workspace)
                  [[ $# -ge 2 ]] || { echo "ocsb-$VARIANT: $1 requires a value" >&2; exit 1; }
                  FILTERED_ARGS+=("$1" "$2")
                  shift 2
                  ;;
                -s|--shell)
                  SHELL_MODE=1
                  shift
                  ;;
                --continue|--overwrite)
                  HAS_CONTINUE_OR_OVERWRITE=1
                  FILTERED_ARGS+=("$1")
                  shift
                  ;;
                --persist-dir)
                  [[ $# -ge 2 ]] || { echo "ocsb-$VARIANT: $1 requires a value" >&2; exit 1; }
                  PERSIST_DIR="$2"
                  shift 2
                  ;;
                --)
                  FILTERED_ARGS+=("$1")
                  shift
                  while [[ $# -gt 0 ]]; do
                    FILTERED_ARGS+=("$1")
                    shift
                  done
                  break
                  ;;
                *)
                  FILTERED_ARGS+=("$1")
                  shift
                  ;;
              esac
            done

            if [[ -z "$PERSIST_DIR" ]]; then
              if [[ -n "''${OCSB_IRONCLAW_PERSIST_DIR:-}" ]]; then
                PERSIST_DIR="$OCSB_IRONCLAW_PERSIST_DIR"
              else
                PERSIST_DIR="$HOME/.cache/ocsb/ironclaw"
              fi
            fi

            # Default to --continue: ironclaw's real state is in $PERSIST_DIR,
            # the cwd workspace marker is just a tracking dir.
            if [[ "$HAS_CONTINUE_OR_OVERWRITE" -eq 0 ]]; then
              FILTERED_ARGS=(--continue "''${FILTERED_ARGS[@]}")
            fi

            PERSIST_DIR="$(${pkgs.coreutils}/bin/realpath -m "$PERSIST_DIR")"

            ${pkgs.coreutils}/bin/mkdir -p \
              "$PERSIST_DIR/home" \
              "$PERSIST_DIR/data" \
              "$PERSIST_DIR/pgdata" \
              "$PERSIST_DIR/pgrun"

            if [[ "$SHELL_MODE" -eq 1 ]]; then
              export OCSB_EXEC_OVERRIDE=1
              FILTERED_ARGS+=(-- ${pkgs.bashInteractive}/bin/bash -i)
            fi

            exec ${ironclawSandboxBase}/bin/ironclaw \
              --rw "$PERSIST_DIR/home:/home/sandbox" \
              --rw "$PERSIST_DIR/data:/var/lib/ironclaw" \
              --rw "$PERSIST_DIR/pgdata:/var/lib/postgresql/data" \
              --rw "$PERSIST_DIR/pgrun:/run/postgresql" \
              "''${FILTERED_ARGS[@]}"
          '';

          # Build per-version × per-arch package + sandbox wrapper.
          # First entry of ironclawVersions × first entry of ironclawArchs is
          # the "latest baseline" → `ironclaw` / `ironclaw-sandbox` aliases.
          # Per-arch suffix appended after version slug; empty archSlug means
          # the unsuffixed (baseline x86-64-v1) variant.
          versionEntries = lib.concatMap (v:
            lib.concatMap (a:
              let
                pkg = mkIronclawPackage (v // { inherit (a) microArch; });
                base = mkIronclawSandboxBase pkg;
                archSuffix = if a.archSlug == "" then "" else "_${a.archSlug}";
                fullSlug = "${v.slug}${archSuffix}";
              in
              [
                { name = "ironclaw_${fullSlug}"; value = pkg; }
                { name = "ironclaw-sandbox_${fullSlug}"; value = mkSandboxBin { slug = "_${fullSlug}"; ironclawSandboxBase = base; }; }
              ]
            ) ironclawArchs
          ) ironclawVersions;

          versionAttrs = lib.listToAttrs versionEntries;

          latestVersion = builtins.head ironclawVersions;
          baselineArch = builtins.head ironclawArchs;
          latestPkg = mkIronclawPackage (latestVersion // { inherit (baselineArch) microArch; });
          latestBase = mkIronclawSandboxBase latestPkg;

          # Per-arch latest aliases (e.g. `ironclaw_x86_64_v3` = latest version
          # at arch v3). The baseline arch is the unsuffixed `ironclaw`.
          latestArchEntries = lib.concatMap (a:
            if a.archSlug == "" then [] else
            let
              pkg = mkIronclawPackage (latestVersion // { inherit (a) microArch; });
              base = mkIronclawSandboxBase pkg;
            in
            [
              { name = "ironclaw_${a.archSlug}"; value = pkg; }
              { name = "ironclaw-sandbox_${a.archSlug}"; value = mkSandboxBin { slug = "_${a.archSlug}"; ironclawSandboxBase = base; }; }
            ]
          ) ironclawArchs;
          latestArchAttrs = lib.listToAttrs latestArchEntries;
        in
        {
          default = mkSandbox (import ./templates/opencode.nix { inherit pkgs; });

          # Aliases pointing at the latest tracked release (baseline arch).
          ironclaw = latestPkg;
          ironclaw-sandbox = mkSandboxBin { slug = ""; ironclawSandboxBase = latestBase; };
        } // versionAttrs // latestArchAttrs
      );

      # CI checks — build sandbox variants to verify they evaluate and build.
      # Versioned ironclaw builds are NOT in checks (heavy Rust compile);
      # they remain buildable on demand via `nix build .#ironclaw_v0_XX_X`.
      checks = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          mkSandbox = import ./lib/mkSandbox.nix { inherit pkgs; lib = nixpkgs.lib; };
        in
        {
          default = self.packages.${system}.default;

          net-test = mkSandbox ({ pkgs, ... }: {
            app.name = "ocsb-net-test";
            packages = with pkgs; [ coreutils curl jq iptables iproute2 ];
            workspace = { strategy = "direct"; baseDir = ".ocsb"; name = "_"; };
            network.enable = true;
            env = {};
            mounts.ro = [];
            mounts.rw = [];
          });

          dual-layer-test = mkSandbox ({ pkgs, ... }: {
            app.name = "ocsb-dual-test";
            packages = with pkgs; [ coreutils curl jq iproute2 gnugrep ];
            workspace = { strategy = "direct"; baseDir = ".ocsb"; name = "_"; };
            experimental.dualLayer = true;
            env = {};
            mounts.ro = [];
            mounts.rw = [];
          });

          host-daemon-test = mkSandbox ({ pkgs, ... }: {
            app.name = "ocsb-host-daemon-test";
            packages = with pkgs; [ coreutils nix ];
            workspace = { strategy = "direct"; baseDir = ".ocsb"; name = "_"; };
            experimental.nixStoreMode = "host-daemon";
            env = {};
            mounts.ro = [];
            mounts.rw = [];
          });
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              self.packages.${system}.default
            ];
          };
        }
      );
    };
}
