{
  description = "ocsb - Nix sandbox for OpenCode with isolated filesystem and workspace branching";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Track ironclaw releases. The "latest" alias (`ironclaw-src`) points at the
    # newest tag we ship; older releases are pinned independently and remain
    # buildable as `ironclaw_v0_27_0`, etc. To bump:
    #   1. Move `ironclaw-src` to the new release tag.
    #   2. Add the previous tag here (e.g. ironclaw-src-v0_27_0) and register it
    #      in `ironclawVersions` below.
    #   3. Drop the oldest entry if the kept-window grows beyond 2 releases.
    ironclaw-src = {
      url = "github:nearai/ironclaw/ironclaw-v0.28.1";
      flake = false;
    };
    ironclaw-src-v0_27_0 = {
      url = "github:nearai/ironclaw/93c7d6a484237999a7a202efd6d54f70d785c0b7";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, ironclaw-src, ironclaw-src-v0_27_0, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      lib = nixpkgs.lib;

      mkPkgs = system: nixpkgs.legacyPackages.${system};

      # Latest first. The first entry's package becomes the unversioned
      # `ironclaw` / `ironclaw-sandbox` aliases.
      ironclawVersions = [
        { slug = "v0_28_1"; version = "0.28.1"; src = ironclaw-src; }
        { slug = "v0_27_0"; version = "0.27.0"; src = ironclaw-src-v0_27_0; }
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

          # `slug` controls wrapper/package names. `persistSlug` controls the
          # default state directory and intentionally omits arch suffixes so
          # optimized wrappers reuse the same Ironclaw data for a version.
          mkSandboxBin = { slug, persistSlug ? slug, ironclawSandboxBase }: pkgs.writeShellScriptBin "ocsb-ironclaw${slug}" ''
            set -euo pipefail

            VARIANT="ironclaw${slug}"
            PERSIST_VARIANT="ironclaw${persistSlug}"
            DB_ENV_FILE_SANDBOX="/tmp/ocsb-ironclaw-db.env"

            PERSIST_DIR=""
            FILTERED_ARGS=()
            HAS_CONTINUE_OR_OVERWRITE=0
            SHELL_MODE=0

            DB_MODE="''${OCSB_IRONCLAW_DB_MODE:-embedded}"
            DB_SIDECAR_RUNTIME="''${OCSB_IRONCLAW_DB_SIDECAR_RUNTIME:-podman}"
            DB_SIDECAR_CONTAINER="''${OCSB_IRONCLAW_DB_SIDECAR_CONTAINER:-}"
            DB_SIDECAR_IMAGE="''${OCSB_IRONCLAW_DB_SIDECAR_IMAGE:-docker.io/pgvector/pgvector:pg18}"
            DB_SIDECAR_PORT="''${OCSB_IRONCLAW_DB_SIDECAR_PORT:-55432}"
            DB_SIDECAR_DB="ironclaw"
            DB_SIDECAR_USER="ironclaw"
            DB_ENV_HOST_FILE=""

            usage() {
              cat <<USAGE_EOF
            Usage: ocsb-$VARIANT [OPTIONS] [-- COMMAND...]

            Run NEAR AI Ironclaw inside an isolated ocsb sandbox with persistent
            app state and selectable database mode.

            Options:
              --persist-dir DIR              Override persistent state directory.
                                            Default: \$HOME/.cache/ocsb/\$PERSIST_VARIANT.
                                            Arch-optimized wrappers share the
                                            corresponding non-arch data dir.
              --db-mode MODE                Database mode: embedded|external|sidecar.
                                            Default: embedded.
              --db-sidecar-runtime RUNTIME  Sidecar OCI runtime: podman|docker.
                                            Default: podman.
              --db-sidecar-container NAME   Sidecar container name.
                                            Default: ocsb-ironclaw-db.
              --db-sidecar-image IMAGE      Sidecar image.
                                            Default: docker.io/pgvector/pgvector:pg18.
              --db-sidecar-port PORT        Host loopback port mapped to sidecar 5432.
                                            Default: 55432.
              -w, --workspace NAME          Workspace name (passed through to ocsb).
              -s, --shell                   Drop into bash inside the sandbox instead
                                            of starting ironclaw.
              --attach                      Attach to the currently-running sandbox
                                            instance (shares its env and mounts).
                                            Use --attach=PID to target a specific bwrap.
              --env NAME[=VALUE]            Forward non-DB env to inner ocsb.
                                            In external/sidecar mode, Ironclaw DB
                                            env names are captured to a private file
                                            and not forwarded as inner --env args.
              -h, --help                    Show this help and exit.
              --                            Pass remaining args to ironclaw / shell.

            Environment:
              OCSB_IRONCLAW_PERSIST_DIR              Same as --persist-dir.
              OCSB_IRONCLAW_DB_MODE                 Same as --db-mode.
              OCSB_IRONCLAW_DB_SIDECAR_RUNTIME      Same as --db-sidecar-runtime.
              OCSB_IRONCLAW_DB_SIDECAR_CONTAINER    Same as --db-sidecar-container.
              OCSB_IRONCLAW_DB_SIDECAR_IMAGE        Same as --db-sidecar-image.
              OCSB_IRONCLAW_DB_SIDECAR_PORT         Same as --db-sidecar-port.

            DB modes:
              embedded  Default behavior: init/start local postgres + pgvector in sandbox.
              external  Require caller-provided DATABASE_URL; no local postgres startup.
              sidecar   Host wrapper ensures OCI postgres+pgvector container is up,
                        synthesizes DATABASE_URL, writes DB env into private file,
                        mounts it read-only, then sandbox preExec sources it.

            Persistent layout (under \$PERSIST_DIR):
              home/            \$HOME inside sandbox (config, history)
              data/            ironclaw application data
              pgdata/          embedded postgres cluster data
              pgrun/           embedded postgres unix socket
              pgdata-sidecar/  sidecar postgres data directory
              sidecar-db-password  generated sidecar DB password (0600)

            Sandbox state (under \$PERSIST_DIR/state/ironclaw/):
              chroot/          relocated /nix/store state
              chroot/merged    bind-mounted as /nix inside sandbox
              overlay/         overlayfs upper/work state when used

            External/sidecar DB env delivery:
              \$PERSIST_DIR/state/ironclaw-db.env (0600, host private)
              -> mounted read-only at $DB_ENV_FILE_SANDBOX inside sandbox.
USAGE_EOF
            }

            append_forward_env_name() {
              local _name="$1"
              [[ -n "$_name" ]] || return 0
              if [[ -z "''${OCSB_FORWARD_ENV:-}" ]]; then
                OCSB_FORWARD_ENV="$_name"
              elif [[ ",''${OCSB_FORWARD_ENV}," != *",$_name,"* ]]; then
                OCSB_FORWARD_ENV="''${OCSB_FORWARD_ENV},$_name"
              fi
            }

            remove_forward_env_name() {
              local _name="$1"
              local _raw="''${OCSB_FORWARD_ENV:-}"
              [[ -n "$_raw" ]] || return 0

              local _entry _trimmed
              local _new_entries=()
              IFS=',' read -r -a _entries <<< "$_raw"
              for _entry in "''${_entries[@]}"; do
                _trimmed="''${_entry#"''${_entry%%[![:space:]]*}"}"
                _trimmed="''${_trimmed%"''${_trimmed##*[![:space:]]}"}"
                [[ -n "$_trimmed" ]] || continue
                if [[ "$_trimmed" != "$_name" ]]; then
                  _new_entries+=("$_trimmed")
                fi
              done

              if [[ ''${#_new_entries[@]} -eq 0 ]]; then
                unset OCSB_FORWARD_ENV
              else
                OCSB_FORWARD_ENV="$(IFS=,; printf '%s' "''${_new_entries[*]}")"
              fi
            }

            is_db_env_name() {
              case "$1" in
                DATABASE_URL|DATABASE_BACKEND|DATABASE_SSLMODE|DATABASE_POOL_SIZE|PGHOST|PGPORT|PGUSER|PGPASSWORD|PGDATABASE)
                  return 0
                  ;;
                *)
                  return 1
                  ;;
              esac
            }

            is_reserved_ironclaw_env_name() {
              case "$1" in
                OCSB_IRONCLAW_DB_MODE|OCSB_IRONCLAW_DB_ENV_FILE)
                  return 0
                  ;;
                *)
                  return 1
                  ;;
              esac
            }

            write_db_env_file() {
              local _db_env_file="$1"
              local _db_env_dir _db_env_base _db_env_tmp
              local _db_env_name

              _db_env_dir="$(${pkgs.coreutils}/bin/dirname "$_db_env_file")"
              _db_env_base="$(${pkgs.coreutils}/bin/basename "$_db_env_file")"
              _db_env_tmp="$(${pkgs.coreutils}/bin/mktemp "$_db_env_dir/.$_db_env_base.XXXXXX")"
              trap '[[ -n "''${_db_env_tmp:-}" ]] && ${pkgs.coreutils}/bin/rm -f "$_db_env_tmp"' RETURN

              (
                umask 077
                {
                  for _db_env_name in DATABASE_URL DATABASE_BACKEND DATABASE_SSLMODE DATABASE_POOL_SIZE PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE; do
                    if [[ -n "''${!_db_env_name+x}" ]]; then
                      printf 'export %s=%q\n' "$_db_env_name" "''${!_db_env_name}"
                    fi
                  done
                } > "$_db_env_tmp"
              )
              chmod 0600 "$_db_env_tmp" 2>/dev/null || true
              ${pkgs.coreutils}/bin/mv -f "$_db_env_tmp" "$_db_env_file"
              _db_env_tmp=""
              trap - RETURN
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
                --db-mode)
                  [[ $# -ge 2 ]] || { echo "ocsb-$VARIANT: $1 requires a value" >&2; exit 1; }
                  DB_MODE="$2"
                  shift 2
                  ;;
                --db-sidecar-runtime)
                  [[ $# -ge 2 ]] || { echo "ocsb-$VARIANT: $1 requires a value" >&2; exit 1; }
                  DB_SIDECAR_RUNTIME="$2"
                  shift 2
                  ;;
                --db-sidecar-container)
                  [[ $# -ge 2 ]] || { echo "ocsb-$VARIANT: $1 requires a value" >&2; exit 1; }
                  DB_SIDECAR_CONTAINER="$2"
                  shift 2
                  ;;
                --db-sidecar-image)
                  [[ $# -ge 2 ]] || { echo "ocsb-$VARIANT: $1 requires a value" >&2; exit 1; }
                  DB_SIDECAR_IMAGE="$2"
                  shift 2
                  ;;
                --db-sidecar-port)
                  [[ $# -ge 2 ]] || { echo "ocsb-$VARIANT: $1 requires a value" >&2; exit 1; }
                  DB_SIDECAR_PORT="$2"
                  shift 2
                  ;;
                --env)
                  [[ $# -ge 2 ]] || { echo "ocsb-$VARIANT: $1 requires NAME or NAME=VALUE" >&2; exit 1; }
                  _ENV_SPEC="$2"
                  if [[ "$_ENV_SPEC" == *=* ]]; then
                    _ENV_NAME="''${_ENV_SPEC%%=*}"
                    _ENV_VALUE="''${_ENV_SPEC#*=}"
                  else
                    _ENV_NAME="$_ENV_SPEC"
                    if [[ ! "$_ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                      echo "ocsb-$VARIANT: invalid --env name: $_ENV_NAME" >&2
                      exit 1
                    fi
                    if [[ -z "''${!_ENV_NAME+x}" ]]; then
                      echo "ocsb-$VARIANT: --env $_ENV_NAME requested but host environment variable is unset" >&2
                      exit 1
                    fi
                    _ENV_VALUE="''${!_ENV_NAME}"
                  fi
                  if [[ ! "$_ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                    echo "ocsb-$VARIANT: invalid --env name: $_ENV_NAME" >&2
                    exit 1
                  fi
                  if is_reserved_ironclaw_env_name "$_ENV_NAME"; then
                    echo "ocsb-$VARIANT: --env $_ENV_NAME is reserved for the Ironclaw wrapper" >&2
                    exit 1
                  fi
                  export "$_ENV_NAME=$_ENV_VALUE"
                  if ! is_db_env_name "$_ENV_NAME"; then
                    FILTERED_ARGS+=("$1" "$2")
                  fi
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
                PERSIST_DIR="$HOME/.cache/ocsb/$PERSIST_VARIANT"
              fi
            fi

            case "$DB_MODE" in
              embedded|external|sidecar) ;;
              *)
                echo "ocsb-$VARIANT: invalid --db-mode '$DB_MODE' (expected embedded|external|sidecar)" >&2
                exit 1
                ;;
            esac

            if [[ -z "$DB_SIDECAR_CONTAINER" ]]; then
              DB_SIDECAR_CONTAINER="ocsb-ironclaw-db"
            fi

            if [[ "$DB_MODE" == "sidecar" ]]; then
              case "$DB_SIDECAR_RUNTIME" in
                podman|docker) ;;
                *)
                  echo "ocsb-$VARIANT: invalid --db-sidecar-runtime '$DB_SIDECAR_RUNTIME' (expected podman|docker)" >&2
                  exit 1
                  ;;
              esac

              if [[ -z "$DB_SIDECAR_CONTAINER" ]]; then
                echo "ocsb-$VARIANT: --db-sidecar-container must not be empty" >&2
                exit 1
              fi
              if [[ -z "$DB_SIDECAR_IMAGE" ]]; then
                echo "ocsb-$VARIANT: --db-sidecar-image must not be empty" >&2
                exit 1
              fi
              if [[ ! "$DB_SIDECAR_PORT" =~ ^[0-9]+$ ]] || (( DB_SIDECAR_PORT < 1 || DB_SIDECAR_PORT > 65535 )); then
                echo "ocsb-$VARIANT: invalid --db-sidecar-port '$DB_SIDECAR_PORT' (expected 1-65535)" >&2
                exit 1
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
              "$PERSIST_DIR/state"

            if [[ "$DB_MODE" == "embedded" ]]; then
              ${pkgs.coreutils}/bin/mkdir -p "$PERSIST_DIR/pgdata" "$PERSIST_DIR/pgrun"
            elif [[ "$DB_MODE" == "sidecar" ]]; then
              ${pkgs.coreutils}/bin/mkdir -p "$PERSIST_DIR/pgdata-sidecar"
            fi

            export OCSB_IRONCLAW_DB_MODE="$DB_MODE"
            append_forward_env_name OCSB_IRONCLAW_DB_MODE

            if [[ "$DB_MODE" == "external" ]]; then
              if [[ -z "''${DATABASE_URL:-}" ]]; then
                echo "ocsb-$VARIANT: db mode 'external' requires DATABASE_URL in the host environment" >&2
                exit 1
              fi
              export DATABASE_BACKEND="''${DATABASE_BACKEND:-postgres}"
            elif [[ "$DB_MODE" == "sidecar" ]]; then
              if ! command -v "$DB_SIDECAR_RUNTIME" >/dev/null 2>&1; then
                echo "ocsb-$VARIANT: db mode 'sidecar' requires '$DB_SIDECAR_RUNTIME' on host PATH" >&2
                exit 1
              fi

              _SIDECAR_STATUS=""
              if _SIDECAR_STATUS="$($DB_SIDECAR_RUNTIME inspect --format '{{.State.Status}}' "$DB_SIDECAR_CONTAINER" 2>/dev/null)"; then
                :
              else
                _SIDECAR_STATUS=""
              fi

              _SIDECAR_PASSWORD_FILE="$PERSIST_DIR/sidecar-db-password"
              if [[ -s "$_SIDECAR_PASSWORD_FILE" ]]; then
                chmod 0600 "$_SIDECAR_PASSWORD_FILE" 2>/dev/null || true
              elif [[ -n "$_SIDECAR_STATUS" ]]; then
                echo "ocsb-$VARIANT: sidecar container '$DB_SIDECAR_CONTAINER' already exists, but $_SIDECAR_PASSWORD_FILE is missing" >&2
                echo "ocsb-$VARIANT: use the same --persist-dir that created it, or use --db-mode external with an explicit DATABASE_URL" >&2
                exit 1
              else
                (
                  umask 077
                  ${pkgs.openssl}/bin/openssl rand -hex 24 > "$_SIDECAR_PASSWORD_FILE"
                )
                chmod 0600 "$_SIDECAR_PASSWORD_FILE" 2>/dev/null || true
              fi
              DB_SIDECAR_PASSWORD="$(${pkgs.coreutils}/bin/cat "$_SIDECAR_PASSWORD_FILE")"

              if [[ "$_SIDECAR_STATUS" == "running" ]]; then
                echo "ocsb-$VARIANT: reusing running sidecar container '$DB_SIDECAR_CONTAINER'" >&2
              elif [[ -n "$_SIDECAR_STATUS" ]]; then
                echo "ocsb-$VARIANT: starting existing sidecar container '$DB_SIDECAR_CONTAINER'" >&2
                "$DB_SIDECAR_RUNTIME" start "$DB_SIDECAR_CONTAINER" >/dev/null
              else
                echo "ocsb-$VARIANT: creating sidecar container '$DB_SIDECAR_CONTAINER'" >&2

                _SIDECAR_ENV_FILE="$(${pkgs.coreutils}/bin/mktemp "$PERSIST_DIR/state/sidecar-db.XXXXXX")"
                (
                  umask 077
                  cat > "$_SIDECAR_ENV_FILE" <<EOF
POSTGRES_USER=$DB_SIDECAR_USER
POSTGRES_PASSWORD=$DB_SIDECAR_PASSWORD
POSTGRES_DB=$DB_SIDECAR_DB
EOF
                )
                chmod 0600 "$_SIDECAR_ENV_FILE" 2>/dev/null || true

                if ! "$DB_SIDECAR_RUNTIME" run -d \
                  --name "$DB_SIDECAR_CONTAINER" \
                  --env-file "$_SIDECAR_ENV_FILE" \
                  --volume "$PERSIST_DIR/pgdata-sidecar:/var/lib/postgresql" \
                  --publish "127.0.0.1:$DB_SIDECAR_PORT:5432" \
                  "$DB_SIDECAR_IMAGE" >/dev/null; then
                  ${pkgs.coreutils}/bin/rm -f "$_SIDECAR_ENV_FILE"
                  exit 1
                fi
                ${pkgs.coreutils}/bin/rm -f "$_SIDECAR_ENV_FILE"
              fi

              _SIDE_READY=0
              for ((_i=0; _i<60; _i++)); do
                if "$DB_SIDECAR_RUNTIME" exec "$DB_SIDECAR_CONTAINER" pg_isready -U "$DB_SIDECAR_USER" -d "$DB_SIDECAR_DB" >/dev/null 2>&1; then
                  _SIDE_READY=1
                  break
                fi
                ${pkgs.coreutils}/bin/sleep 1
              done
              if [[ "$_SIDE_READY" -ne 1 ]]; then
                echo "ocsb-$VARIANT: sidecar postgres readiness timeout for '$DB_SIDECAR_CONTAINER'" >&2
                exit 1
              fi

              _DB_EXISTS="$($DB_SIDECAR_RUNTIME exec "$DB_SIDECAR_CONTAINER" \
                psql -U "$DB_SIDECAR_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_SIDECAR_DB'" \
                2>/dev/null | ${pkgs.coreutils}/bin/tr -d '[:space:]' || true)"
              if [[ "$_DB_EXISTS" != "1" ]]; then
                "$DB_SIDECAR_RUNTIME" exec "$DB_SIDECAR_CONTAINER" createdb -U "$DB_SIDECAR_USER" "$DB_SIDECAR_DB" >/dev/null
              fi
              "$DB_SIDECAR_RUNTIME" exec "$DB_SIDECAR_CONTAINER" \
                psql -U "$DB_SIDECAR_USER" -d "$DB_SIDECAR_DB" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null

              export PGHOST="127.0.0.1"
              export PGPORT="$DB_SIDECAR_PORT"
              export PGUSER="$DB_SIDECAR_USER"
              export PGDATABASE="$DB_SIDECAR_DB"
              export PGPASSWORD="$DB_SIDECAR_PASSWORD"
              export DATABASE_URL="postgres://$DB_SIDECAR_USER:$DB_SIDECAR_PASSWORD@127.0.0.1:$DB_SIDECAR_PORT/$DB_SIDECAR_DB?sslmode=disable"
              export DATABASE_BACKEND="''${DATABASE_BACKEND:-postgres}"
              export DATABASE_SSLMODE="''${DATABASE_SSLMODE:-disable}"
            fi

            if [[ "$DB_MODE" == "external" || "$DB_MODE" == "sidecar" ]]; then
              DB_ENV_HOST_FILE="$PERSIST_DIR/state/ironclaw-db.env"
              export OCSB_IRONCLAW_DB_ENV_FILE="$DB_ENV_FILE_SANDBOX"
              append_forward_env_name OCSB_IRONCLAW_DB_ENV_FILE

              remove_forward_env_name DATABASE_URL
              remove_forward_env_name DATABASE_BACKEND
              remove_forward_env_name DATABASE_SSLMODE
              remove_forward_env_name DATABASE_POOL_SIZE
              remove_forward_env_name PGHOST
              remove_forward_env_name PGPORT
              remove_forward_env_name PGUSER
              remove_forward_env_name PGPASSWORD
              remove_forward_env_name PGDATABASE

              write_db_env_file "$DB_ENV_HOST_FILE"

              # Avoid inheriting DB secrets in the host-side launcher/bwrap env.
              unset DATABASE_URL DATABASE_BACKEND DATABASE_SSLMODE DATABASE_POOL_SIZE
              unset PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
            fi
            export OCSB_FORWARD_ENV

            cd "$PERSIST_DIR/home"

            if [[ "$SHELL_MODE" -eq 1 ]]; then
              export OCSB_EXEC_OVERRIDE=1
              FILTERED_ARGS+=(-- ${pkgs.bashInteractive}/bin/bash -i)
            fi

            # Ironclaw state is independent of the launch cwd. Keep ocsb's
            # chroot/overlay workspace state under the stable persist dir
            # instead of ~/.cache/ocsb/<project-hash>/ironclaw.
            export OCSB_STATE_BASE_DIR="$PERSIST_DIR/state"

            IRONCLAW_MOUNT_ARGS=(
              --rw "$PERSIST_DIR/data:/var/lib/ironclaw"
            )
            if [[ "$DB_MODE" == "embedded" ]]; then
              IRONCLAW_MOUNT_ARGS+=(
                --rw "$PERSIST_DIR/pgdata:/var/lib/postgresql/data"
                --rw "$PERSIST_DIR/pgrun:/run/postgresql"
              )
            else
              IRONCLAW_MOUNT_ARGS+=(
                --ro "$DB_ENV_HOST_FILE:$DB_ENV_FILE_SANDBOX"
              )
            fi

            exec ${ironclawSandboxBase}/bin/ironclaw \
              "''${IRONCLAW_MOUNT_ARGS[@]}" \
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
                { name = "ironclaw-sandbox_${fullSlug}"; value = mkSandboxBin { slug = "_${fullSlug}"; persistSlug = "_${v.slug}"; ironclawSandboxBase = base; }; }
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
              { name = "ironclaw-sandbox_${a.archSlug}"; value = mkSandboxBin { slug = "_${a.archSlug}"; persistSlug = ""; ironclawSandboxBase = base; }; }
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
