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

          mkIronclawPackage = { src, version, ... }: pkgs.callPackage ./pkgs/ironclaw.nix {
            ironclaw-src = src;
            inherit version;
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
            WORKSPACE_NAME="$VARIANT"
            PERSIST_DIR=""
            FILTERED_ARGS=()

            while [[ $# -gt 0 ]]; do
              case "$1" in
                -w|--workspace)
                  [[ $# -ge 2 ]] || { echo "ocsb-$VARIANT: $1 requires a value" >&2; exit 1; }
                  WORKSPACE_NAME="$2"
                  FILTERED_ARGS+=("$1" "$2")
                  shift 2
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
                PERSIST_DIR="$HOME/.cache/ocsb/$VARIANT/$WORKSPACE_NAME"
              fi
            fi

            PERSIST_DIR="$(${pkgs.coreutils}/bin/realpath -m "$PERSIST_DIR")"

            ${pkgs.coreutils}/bin/mkdir -p \
              "$PERSIST_DIR/home" \
              "$PERSIST_DIR/data" \
              "$PERSIST_DIR/pgdata" \
              "$PERSIST_DIR/pgrun" \
              "$PERSIST_DIR/nix-user" \
              "$PERSIST_DIR/nix-store"

            exec ${ironclawSandboxBase}/bin/ironclaw \
              --rw "$PERSIST_DIR/home:/home/sandbox" \
              --rw "$PERSIST_DIR/data:/var/lib/ironclaw" \
              --rw "$PERSIST_DIR/pgdata:/var/lib/postgresql/data" \
              --rw "$PERSIST_DIR/pgrun:/run/postgresql" \
              --rw "$PERSIST_DIR/nix-user:/home/sandbox/.nix-portable" \
              "''${FILTERED_ARGS[@]}"
          '';

          # Build per-version package + per-version sandbox wrapper.
          # First entry of ironclawVersions is treated as "latest" and gets
          # the unversioned `ironclaw` / `ironclaw-sandbox` aliases.
          versionEntries = lib.concatMap (v:
            let
              pkg = mkIronclawPackage v;
              base = mkIronclawSandboxBase pkg;
            in
            [
              { name = "ironclaw_${v.slug}"; value = pkg; }
              { name = "ironclaw-sandbox_${v.slug}"; value = mkSandboxBin { slug = "_${v.slug}"; ironclawSandboxBase = base; }; }
            ]
          ) ironclawVersions;

          versionAttrs = lib.listToAttrs versionEntries;

          latest = builtins.head ironclawVersions;
          latestPkg = mkIronclawPackage latest;
          latestBase = mkIronclawSandboxBase latestPkg;
        in
        {
          default = mkSandbox (import ./templates/opencode.nix { inherit pkgs; });

          # Aliases pointing at the latest tracked release.
          ironclaw = latestPkg;
          ironclaw-sandbox = mkSandboxBin { slug = ""; ironclawSandboxBase = latestBase; };
        } // versionAttrs
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
