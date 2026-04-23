{
  description = "ocsb - Nix sandbox for OpenCode with isolated filesystem and workspace branching";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ironclaw-src = {
      # Pinned to nearai/ironclaw main HEAD as of 2026-04-22.
      url = "github:nearai/ironclaw/9dcd8969a659f91f47f6d13d5bc5c5ff8f19f6d6";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, ironclaw-src }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      mkPkgs = system: nixpkgs.legacyPackages.${system};
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
          ironclawPackage = pkgs.callPackage ./pkgs/ironclaw.nix {
            inherit ironclaw-src;
          };
          ironclawSandboxBase = mkSandbox (import ./templates/ironclaw.nix {
            inherit pkgs ironclaw-src;
          });
        in
        {
          default = mkSandbox (import ./templates/opencode.nix { inherit pkgs; });

          ironclaw = ironclawPackage;

          ironclaw-sandbox = pkgs.writeShellScriptBin "ocsb-ironclaw" ''
            set -euo pipefail

            WORKSPACE_NAME="ironclaw"
            PERSIST_DIR=""
            FILTERED_ARGS=()

            while [[ $# -gt 0 ]]; do
              case "$1" in
                -w|--workspace)
                  [[ $# -ge 2 ]] || { echo "ocsb-ironclaw: $1 requires a value" >&2; exit 1; }
                  WORKSPACE_NAME="$2"
                  FILTERED_ARGS+=("$1" "$2")
                  shift 2
                  ;;
                --persist-dir)
                  [[ $# -ge 2 ]] || { echo "ocsb-ironclaw: $1 requires a value" >&2; exit 1; }
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
                PERSIST_DIR="$HOME/.cache/ocsb/ironclaw/$WORKSPACE_NAME"
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
        }
      );

      # CI checks — build all sandbox variants to verify they evaluate and build
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

          ironclaw-test = pkgs.runCommand "ocsb-ironclaw-test" {
            nativeBuildInputs = with pkgs; [ bash nix ];
          } ''
            ${pkgs.bash}/bin/bash ${./tests/test_ironclaw.sh}
            touch "$out"
          '';
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
