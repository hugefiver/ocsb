{ pkgs, slug, persistSlug ? slug, ironclawSandboxBase, sidecarGate, sidecarTestHookMode ? "none" }:

pkgs.writeShellScriptBin "ocsb-ironclaw${slug}" ''
  set -euo pipefail

  VARIANT="ironclaw${slug}"
  PERSIST_VARIANT="ironclaw${persistSlug}"
  DB_ENV_FILE_SANDBOX="/tmp/ocsb-ironclaw-db.env"

  PERSIST_DIR=""
  FILTERED_ARGS=()
  HANDOFF_FD_ARGS=()
  HANDOFF_HOME_FD=""
  HANDOFF_DATA_FD=""
  HANDOFF_STATE_FD=""
  HANDOFF_DB_ENV_FD=""
  HAS_CONTINUE_OR_OVERWRITE=0
  SHELL_MODE=0

  DB_MODE="''${OCSB_IRONCLAW_DB_MODE:-embedded}"
  DB_SIDECAR_RUNTIME="''${OCSB_IRONCLAW_DB_SIDECAR_RUNTIME:-podman}"
  DB_SIDECAR_CONTAINER="''${OCSB_IRONCLAW_DB_SIDECAR_CONTAINER:-}"
  DB_SIDECAR_IMAGE="''${OCSB_IRONCLAW_DB_SIDECAR_IMAGE:-docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0}"
  DB_SIDECAR_PORT="''${OCSB_IRONCLAW_DB_SIDECAR_PORT:-55432}"
  DB_SIDECAR_DB="ironclaw"
  DB_SIDECAR_USER="ironclaw"
  DB_ENV_HOST_FILE=""
  SIDECAR_GATE_BIN="${sidecarGate}/bin/ocsb-sidecar-gate"
  SIDECAR_TEST_HOOK_MODE=${pkgs.lib.escapeShellArg sidecarTestHookMode}
  SIDECAR_REMOTE_OPTION_SEEN=0
  TEST_AFTER_CREATE_CIDFILE_READY_FD=""
  TEST_AFTER_CREATE_CIDFILE_RELEASE_FD=""
  TEST_AFTER_PREPARE_READY_FD=""
  TEST_AFTER_PREPARE_RELEASE_FD=""
  TEST_AFTER_COMMIT_DECISION_READY_FD=""
  TEST_AFTER_COMMIT_DECISION_RELEASE_FD=""
  TEST_AFTER_COMMIT_ACK_READY_FD=""
  TEST_AFTER_COMMIT_ACK_RELEASE_FD=""
  TEST_AFTER_OCI_POSTCHECK_READY_FD=""
  TEST_AFTER_OCI_POSTCHECK_RELEASE_FD=""

  case "$SIDECAR_TEST_HOOK_MODE" in
    none|fixture) ;;
    *)
      echo "ocsb-$VARIANT: invalid generated sidecar test-hook mode" >&2
      exit 1
      ;;
  esac

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
                                  Default: docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0.
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
      --test-after-create-cidfile-ready-fd|--test-after-create-cidfile-release-fd|\
      --test-after-prepare-before-decision-ready-fd|--test-after-prepare-before-decision-release-fd|\
      --test-after-commit-decision-before-ack-ready-fd|--test-after-commit-decision-before-ack-release-fd|\
      --test-after-commit-ack-before-return-ready-fd|--test-after-commit-ack-before-return-release-fd|\
      --test-after-oci-before-postcheck-ready-fd|--test-after-oci-before-postcheck-release-fd)
        [[ "$SIDECAR_TEST_HOOK_MODE" == "fixture" ]] || {
          echo "ocsb-$VARIANT: sidecar test options are disabled in production" >&2
          exit 1
        }
        [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || {
          echo "ocsb-$VARIANT: $1 requires an FD number" >&2
          exit 1
        }
        case "$1" in
          --test-after-create-cidfile-ready-fd)
            [[ -z "$TEST_AFTER_CREATE_CIDFILE_READY_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_CREATE_CIDFILE_READY_FD="$2"
            ;;
          --test-after-create-cidfile-release-fd)
            [[ -z "$TEST_AFTER_CREATE_CIDFILE_RELEASE_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_CREATE_CIDFILE_RELEASE_FD="$2"
            ;;
          --test-after-prepare-before-decision-ready-fd)
            [[ -z "$TEST_AFTER_PREPARE_READY_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_PREPARE_READY_FD="$2"
            ;;
          --test-after-prepare-before-decision-release-fd)
            [[ -z "$TEST_AFTER_PREPARE_RELEASE_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_PREPARE_RELEASE_FD="$2"
            ;;
          --test-after-commit-decision-before-ack-ready-fd)
            [[ -z "$TEST_AFTER_COMMIT_DECISION_READY_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_COMMIT_DECISION_READY_FD="$2"
            ;;
          --test-after-commit-decision-before-ack-release-fd)
            [[ -z "$TEST_AFTER_COMMIT_DECISION_RELEASE_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_COMMIT_DECISION_RELEASE_FD="$2"
            ;;
          --test-after-commit-ack-before-return-ready-fd)
            [[ -z "$TEST_AFTER_COMMIT_ACK_READY_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_COMMIT_ACK_READY_FD="$2"
            ;;
          --test-after-commit-ack-before-return-release-fd)
            [[ -z "$TEST_AFTER_COMMIT_ACK_RELEASE_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_COMMIT_ACK_RELEASE_FD="$2"
            ;;
          --test-after-oci-before-postcheck-ready-fd)
            [[ -z "$TEST_AFTER_OCI_POSTCHECK_READY_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_OCI_POSTCHECK_READY_FD="$2"
            ;;
          --test-after-oci-before-postcheck-release-fd)
            [[ -z "$TEST_AFTER_OCI_POSTCHECK_RELEASE_FD" ]] || { echo "ocsb-$VARIANT: duplicate $1" >&2; exit 1; }
            TEST_AFTER_OCI_POSTCHECK_RELEASE_FD="$2"
            ;;
        esac
        shift 2
        ;;
      --remote|--remote=*|--connection|--connection=*|--context|--context=*|--host|--host=*|--url|--url=*)
        SIDECAR_REMOTE_OPTION_SEEN=1
        FILTERED_ARGS+=("$1")
        shift
        ;;
      --test-*)
        echo "ocsb-$VARIANT: unknown sidecar test option: $1" >&2
        exit 1
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
    if [[ "$SIDECAR_REMOTE_OPTION_SEEN" -ne 0 || -n "''${CONTAINER_HOST+x}" || -n "''${CONTAINER_CONNECTION+x}" ||
          -n "''${DOCKER_HOST+x}" || -n "''${DOCKER_CONTEXT+x}" ]]; then
      echo "ocsb-$VARIANT: sidecar OCI runtime must use the local daemon; remote options are not allowed" >&2
      exit 1
    fi
    for _sidecar_test_pair in \
      "$TEST_AFTER_CREATE_CIDFILE_READY_FD:$TEST_AFTER_CREATE_CIDFILE_RELEASE_FD" \
      "$TEST_AFTER_PREPARE_READY_FD:$TEST_AFTER_PREPARE_RELEASE_FD" \
      "$TEST_AFTER_COMMIT_DECISION_READY_FD:$TEST_AFTER_COMMIT_DECISION_RELEASE_FD" \
      "$TEST_AFTER_COMMIT_ACK_READY_FD:$TEST_AFTER_COMMIT_ACK_RELEASE_FD" \
      "$TEST_AFTER_OCI_POSTCHECK_READY_FD:$TEST_AFTER_OCI_POSTCHECK_RELEASE_FD"; do
      IFS=: read -r _sidecar_test_ready _sidecar_test_release <<< "$_sidecar_test_pair"
      if [[ -n "$_sidecar_test_ready" || -n "$_sidecar_test_release" ]]; then
        [[ -n "$_sidecar_test_ready" && -n "$_sidecar_test_release" ]] || {
          echo "ocsb-$VARIANT: sidecar test FD options require an exact ready/release pair" >&2
          exit 1
        }
      fi
    done
  fi

  # Default to --continue: ironclaw's real state is in $PERSIST_DIR,
  # the cwd workspace marker is just a tracking dir.
  if [[ "$HAS_CONTINUE_OR_OVERWRITE" -eq 0 ]]; then
    FILTERED_ARGS=(--continue "''${FILTERED_ARGS[@]}")
  fi

  [[ ! -L "$PERSIST_DIR" ]] || {
    echo "ocsb-$VARIANT: persist directory must not be a symlink" >&2
    exit 1
  }
  PERSIST_DIR="$(${pkgs.coreutils}/bin/realpath -m "$PERSIST_DIR")"

  ${pkgs.coreutils}/bin/mkdir -p \
    "$PERSIST_DIR/home" \
    "$PERSIST_DIR/data" \
    "$PERSIST_DIR/state"

  if [[ "$DB_MODE" == "embedded" ]]; then
    ${pkgs.coreutils}/bin/mkdir -p "$PERSIST_DIR/pgdata" "$PERSIST_DIR/pgrun"
  elif [[ "$DB_MODE" == "sidecar" ]]; then
    # OCI lifecycle state is deliberately kept in shell variables backed by
    # held descriptors.  Public paths are identity assertions only.
    _SIDECAR_PARENT_FD=""
    _SIDECAR_PERSIST_FD=""
    _SIDECAR_STATE_FD=""
    _SIDECAR_DATA_FD=""
    _SIDECAR_PARENT_FD_PATH=""
    _SIDECAR_PERSIST_FD_PATH=""
    _SIDECAR_STATE_FD_PATH=""
    _SIDECAR_DATA_FD_PATH=""
    _SIDECAR_PARENT_ID=""
    _SIDECAR_PERSIST_PATH_ID=""
    _SIDECAR_STATE_ID=""
    _SIDECAR_DATA_ID=""
    _SIDECAR_CONTAINER_ID=""
    _SIDECAR_GENERATION=""
    _SIDECAR_ORIGIN=""
    _SIDECAR_STARTED_BY_TRANSACTION=0
    _SIDECAR_START_ATTEMPTED=0
    _SIDECAR_CREATED_BY_CALL=0
    _SIDECAR_PASSWORD_CREATED_BY_TRANSACTION=0
    _SIDECAR_COMMIT_ATTEMPTED=0
    _SIDECAR_GATE_RELEASED=0
    _SIDECAR_CIDFILE_REL=""
    _SIDECAR_TXN_REL=""
    _SIDECAR_GATE_CONFIG_FD=""
    _SIDECAR_GATE_CONFIG_PATH=""
    _SIDECAR_ENV_FILE=""
    _SIDECAR_PASSWORD_TMP=""
    _SIDECAR_PASSWORD_FD=""
    _SIDECAR_PASSWORD_PID=""
    _SIDECAR_RUNTIME_PID=""
    _SIDECAR_CAPTURE_PID=""
    _SIDECAR_CAPTURE_READ_FD=""
    _SIDECAR_RUNTIME_OUTPUT_FILE=""
    _SIDECAR_GATE_ARCHIVE_FILE=""
    _SIDECAR_PREPARED=0
    _SIDECAR_GATE_DECISION=""
    _SIDECAR_GATE_RUN_NONCE=""
    _SIDECAR_VERIFIED_RUN_NONCE=""
    _SIDECAR_RUNTIME_OUTPUT=""
    _SIDECAR_CLEANUP_DONE=0
    _SIDECAR_DB_ENV_TEMP_PATH=""
    _SIDECAR_DB_ENV_TEMP_ID=""
    _SIDECAR_DB_ENV_PUBLISHED_ID=""
    _SIDECAR_DB_ENV_CREATION_FD=""
    _SIDECAR_DB_ENV_READ_FD=""
    _SIDECAR_IN_ROLLBACK=0

    ${pkgs.coreutils}/bin/mkdir -p "$PERSIST_DIR/pgdata-sidecar"
    [[ ! -L "$PERSIST_DIR" && ! -L "$PERSIST_DIR/state" && ! -L "$PERSIST_DIR/pgdata-sidecar" ]] || {
      echo "ocsb-$VARIANT: unsafe sidecar persist/state/data directory" >&2
      exit 1
    }
    chmod 0700 "$PERSIST_DIR" "$PERSIST_DIR/state" "$PERSIST_DIR/pgdata-sidecar" || exit 1
    for _sidecar_private_dir in "$PERSIST_DIR" "$PERSIST_DIR/state" "$PERSIST_DIR/pgdata-sidecar"; do
      read -r _sidecar_dir_uid _sidecar_dir_mode < <(${pkgs.coreutils}/bin/stat -Lc '%u %a' -- "$_sidecar_private_dir") || exit 1
      [[ "$_sidecar_dir_uid" == "$(id -u)" && "$_sidecar_dir_mode" == 700 ]] || {
        echo "ocsb-$VARIANT: unsafe sidecar persist/state/data directory" >&2
        exit 1
      }
    done

    _sidecar_path_id() {
      ${pkgs.coreutils}/bin/stat -Lc '%d:%i:%u:%a' -- "$1"
    }
    _sidecar_handoff_id() {
      ${pkgs.coreutils}/bin/stat -Lc '%d:%i:%F:%a:%u:%h' -- "$1"
    }
    _sidecar_close_handoff_fds() {
      [[ -z "$HANDOFF_HOME_FD" ]] || exec {HANDOFF_HOME_FD}<&-
      HANDOFF_HOME_FD=""
      [[ -z "$HANDOFF_DATA_FD" ]] || exec {HANDOFF_DATA_FD}<&-
      HANDOFF_DATA_FD=""
      [[ -z "$HANDOFF_STATE_FD" ]] || exec {HANDOFF_STATE_FD}<&-
      HANDOFF_STATE_FD=""
      [[ -z "$HANDOFF_DB_ENV_FD" ]] || exec {HANDOFF_DB_ENV_FD}<&-
      HANDOFF_DB_ENV_FD=""
      HANDOFF_FD_ARGS=()
    }
    _sidecar_promote_handoff_fd() {
      local _fd_var="$1" _source_fd="''${!1}" _target_fd=30

      [[ "$_source_fd" =~ ^[0-9]+$ ]] || return 1
      while [[ -e "/proc/$$/fd/$_target_fd" ]]; do
        _target_fd=$((_target_fd + 1))
      done
      eval "exec $_target_fd<&$_source_fd" || return 1
      exec {_source_fd}<&-
      printf -v "$_fd_var" '%s' "$_target_fd"
    }
    _sidecar_open_handoff_directory() {
      local _fd_var="$1" _path="$2" _label="$3"
      local _before_id _fd_id _after_id _dev _ino _type _mode _owner _links _opened_fd

      [[ ! -L "$_path" && -d "$_path" ]] || {
        echo "ocsb-$VARIANT: unsafe sidecar handoff $_label directory" >&2
        return 1
      }
      _before_id="$(_sidecar_handoff_id "$_path")" || return 1
      IFS=: read -r _dev _ino _type _mode _owner _links <<< "$_before_id"
      [[ "$_type" == directory ]] || {
        echo "ocsb-$VARIANT: unsafe sidecar handoff $_label directory" >&2
        return 1
      }
      exec {_opened_fd}<"$_path" || {
        echo "ocsb-$VARIANT: cannot open sidecar handoff $_label directory" >&2
        return 1
      }
      _fd_id="$(_sidecar_handoff_id "/proc/$$/fd/$_opened_fd")" || {
        exec {_opened_fd}<&-
        return 1
      }
      _after_id="$(_sidecar_handoff_id "$_path")" || _after_id=""
      if [[ ! -L "$_path" && "$_before_id" == "$_fd_id" && "$_fd_id" == "$_after_id" ]]; then
        printf -v "$_fd_var" '%s' "$_opened_fd"
        _sidecar_promote_handoff_fd "$_fd_var" || {
          exec {_opened_fd}<&-
          return 1
        }
        return 0
      fi
      exec {_opened_fd}<&-
      echo "ocsb-$VARIANT: sidecar handoff $_label directory was replaced" >&2
      return 1
    }
    _sidecar_open_handoff_state() {
      local _public_path="$PERSIST_DIR/state"
      local _held_id _public_id _fd_id _after_id _dev _ino _type _mode _owner _links _opened_fd

      [[ ! -L "$_public_path" && -d "$_public_path" ]] || {
        echo "ocsb-$VARIANT: unsafe sidecar handoff state directory" >&2
        return 1
      }
      _held_id="$(_sidecar_handoff_id "$_SIDECAR_STATE_FD_PATH")" || return 1
      _public_id="$(_sidecar_handoff_id "$_public_path")" || return 1
      IFS=: read -r _dev _ino _type _mode _owner _links <<< "$_held_id"
      [[ "$_type" == directory && "$_held_id" == "$_public_id" ]] || {
        echo "ocsb-$VARIANT: sidecar handoff state directory was replaced" >&2
        return 1
      }
      exec {_opened_fd}<"$_SIDECAR_STATE_FD_PATH" || {
        echo "ocsb-$VARIANT: cannot open sidecar handoff state directory" >&2
        return 1
      }
      _fd_id="$(_sidecar_handoff_id "/proc/$$/fd/$_opened_fd")" || {
        exec {_opened_fd}<&-
        return 1
      }
      _after_id="$(_sidecar_handoff_id "$_public_path")" || _after_id=""
      if [[ ! -L "$_public_path" && "$_held_id" == "$_fd_id" && "$_fd_id" == "$_after_id" ]]; then
        HANDOFF_STATE_FD="$_opened_fd"
        _sidecar_promote_handoff_fd HANDOFF_STATE_FD || {
          exec {_opened_fd}<&-
          return 1
        }
        return 0
      fi
      exec {_opened_fd}<&-
      echo "ocsb-$VARIANT: sidecar handoff state directory was replaced" >&2
      return 1
    }
    _sidecar_is_private_regular_handoff_id() {
      local _id="$1" _dev _ino _type _mode _owner _links

      IFS=: read -r _dev _ino _type _mode _owner _links <<< "$_id"
      [[ -n "$_dev" && -n "$_ino" &&
         ( "$_type" == "regular file" || "$_type" == "regular empty file" ) &&
         "$_mode" == 600 && "$_owner" == "$(id -u)" && "$_links" == 1 ]]
    }
    _sidecar_close_db_env_creation_fd() {
      [[ -z "$_SIDECAR_DB_ENV_CREATION_FD" ]] || exec {_SIDECAR_DB_ENV_CREATION_FD}>&-
      _SIDECAR_DB_ENV_CREATION_FD=""
    }
    _sidecar_close_db_env_read_fd() {
      [[ -z "$_SIDECAR_DB_ENV_READ_FD" ]] || exec {_SIDECAR_DB_ENV_READ_FD}<&-
      _SIDECAR_DB_ENV_READ_FD=""
    }
    _sidecar_cleanup_db_env_temp() {
      local _retained_id="" _path_id=""

      [[ -n "$_SIDECAR_DB_ENV_TEMP_PATH" && -n "$_SIDECAR_DB_ENV_TEMP_ID" ]] || return 0
      if [[ -n "$_SIDECAR_DB_ENV_READ_FD" ]]; then
        _retained_id="$(_sidecar_handoff_id "/proc/$$/fd/$_SIDECAR_DB_ENV_READ_FD")" || _retained_id=""
      elif [[ -n "$_SIDECAR_DB_ENV_CREATION_FD" ]]; then
        _retained_id="$(_sidecar_handoff_id "/proc/$$/fd/$_SIDECAR_DB_ENV_CREATION_FD")" || _retained_id=""
      elif [[ -n "$HANDOFF_DB_ENV_FD" ]]; then
        _retained_id="$(_sidecar_handoff_id "/proc/$$/fd/$HANDOFF_DB_ENV_FD")" || _retained_id=""
      fi
      _path_id="$(_sidecar_handoff_id "$_SIDECAR_DB_ENV_TEMP_PATH")" || _path_id=""
      if [[ -n "$_retained_id" && "$_retained_id" == "$_SIDECAR_DB_ENV_TEMP_ID" &&
            ! -L "$_SIDECAR_DB_ENV_TEMP_PATH" && "$_path_id" == "$_retained_id" ]]; then
        ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_DB_ENV_TEMP_PATH" || return 1
      fi
      _SIDECAR_DB_ENV_TEMP_PATH=""
      _SIDECAR_DB_ENV_TEMP_ID=""
    }
    _sidecar_fail_db_env_publication() {
      _sidecar_cleanup_db_env_temp || true
      _sidecar_close_db_env_read_fd
      _sidecar_close_db_env_creation_fd
      _sidecar_close_handoff_fds
      echo "ocsb-$VARIANT: cannot publish sidecar database env file" >&2
    }
    _sidecar_validate_handoff_db_env() {
      local _fd_id

      [[ "$HANDOFF_DB_ENV_FD" =~ ^[0-9]+$ ]] || {
        echo "ocsb-$VARIANT: unsafe sidecar handoff database env file" >&2
        return 1
      }
      _fd_id="$(_sidecar_handoff_id "/proc/$$/fd/$HANDOFF_DB_ENV_FD")" || {
        echo "ocsb-$VARIANT: unsafe sidecar handoff database env file" >&2
        return 1
      }
      _sidecar_is_private_regular_handoff_id "$_fd_id" && [[ "$_fd_id" == "$_SIDECAR_DB_ENV_PUBLISHED_ID" ]] || {
        echo "ocsb-$VARIANT: unsafe sidecar handoff database env file" >&2
        return 1
      }
    }
    _sidecar_append_handoff_arg() {
      local _role="$1" _display_path="$2" _fd="$3" _kind="$4"
      local _fd_id _dev _ino _type _mode _owner _links _expected_type _spec

      case "$_kind" in
        directory) _expected_type=directory ;;
        regular) _expected_type="regular file" ;;
        *) return 1 ;;
      esac
      _fd_id="$(_sidecar_handoff_id "/proc/$$/fd/$_fd")" || return 1
      IFS=: read -r _dev _ino _type _mode _owner _links <<< "$_fd_id"
      [[ "$_type" == "$_expected_type" ]] || return 1
      printf -v _spec 'v1\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$_role" "$_display_path" "$_fd" "$_dev" "$_ino" "$_kind"
      HANDOFF_FD_ARGS+=(--ocsb-internal-fd-root "$_spec")
    }
    _sidecar_open_handoff_fds() {
      _sidecar_open_handoff_directory HANDOFF_HOME_FD "$PERSIST_DIR/home" home || {
        _sidecar_fail_db_env_publication
        return 1
      }
      _sidecar_open_handoff_directory HANDOFF_DATA_FD "$PERSIST_DIR/data" data || {
        _sidecar_fail_db_env_publication
        return 1
      }
      _sidecar_open_handoff_state || {
        _sidecar_fail_db_env_publication
        return 1
      }
      _sidecar_validate_handoff_db_env || {
        _sidecar_fail_db_env_publication
        return 1
      }
      _sidecar_append_handoff_arg project "$PERSIST_DIR/home" "$HANDOFF_HOME_FD" directory &&
        _sidecar_append_handoff_arg state-base "$PERSIST_DIR/state" "$HANDOFF_STATE_FD" directory &&
        _sidecar_append_handoff_arg mount "$PERSIST_DIR/data" "$HANDOFF_DATA_FD" directory &&
        _sidecar_append_handoff_arg mount "$PERSIST_DIR/state/ironclaw-db.env" "$HANDOFF_DB_ENV_FD" regular || {
          _sidecar_fail_db_env_publication
          return 1
        }
    }
    _sidecar_write_db_env_file() {
      local _attempt _db_env_tmp _db_env_name _db_env_old_umask _restore_noclobber
      local _creation_id _read_id _temp_id _held_id _public_id _held_state_id _public_state_id
      local _state_dev _state_ino _state_type _state_mode _state_owner _state_links

      [[ -z "$HANDOFF_DB_ENV_FD" && -z "$_SIDECAR_DB_ENV_CREATION_FD" && -z "$_SIDECAR_DB_ENV_READ_FD" ]] || {
        _sidecar_fail_db_env_publication
        return 1
      }
      cd -- "$_SIDECAR_STATE_FD_PATH" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      [[ ! -L ironclaw-db.env ]] || {
        _sidecar_fail_db_env_publication
        return 1
      }

      _db_env_old_umask="$(umask)"
      umask 077
      for ((_attempt=0; _attempt<16; _attempt++)); do
        _db_env_tmp=".ironclaw-db.env.$(_sidecar_random_hex)" || break
        [[ "$_db_env_tmp" =~ ^\.ironclaw-db\.env\.[0-9a-f]{64}$ ]] || continue
        _restore_noclobber=0
        if [[ ! -o noclobber ]]; then
          set -o noclobber
          _restore_noclobber=1
        fi
        # Bash noclobber applies O_CREAT|O_EXCL to this creation redirection.
        # With a fresh, random name in the held state directory, that is the
        # atomic no-follow equivalent needed here: an existing file or symlink
        # fails creation instead of being followed or overwritten.
        if exec {_SIDECAR_DB_ENV_CREATION_FD}> "$_db_env_tmp"; then
          [[ "$_restore_noclobber" -eq 0 ]] || set +o noclobber
          break
        fi
        [[ "$_restore_noclobber" -eq 0 ]] || set +o noclobber
        _SIDECAR_DB_ENV_CREATION_FD=""
      done
      umask "$_db_env_old_umask"
      [[ -n "$_SIDECAR_DB_ENV_CREATION_FD" ]] || {
        _sidecar_fail_db_env_publication
        return 1
      }

      _SIDECAR_DB_ENV_TEMP_PATH="$_SIDECAR_STATE_FD_PATH/$_db_env_tmp"
      _creation_id="$(_sidecar_handoff_id "/proc/$$/fd/$_SIDECAR_DB_ENV_CREATION_FD")" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      _temp_id="$(_sidecar_handoff_id "$_SIDECAR_DB_ENV_TEMP_PATH")" || _temp_id=""
      _SIDECAR_DB_ENV_TEMP_ID="$_creation_id"
      [[ ! -L "$_SIDECAR_DB_ENV_TEMP_PATH" && "$_temp_id" == "$_creation_id" ]] &&
        _sidecar_is_private_regular_handoff_id "$_creation_id" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      {
        for _db_env_name in DATABASE_URL DATABASE_BACKEND DATABASE_SSLMODE DATABASE_POOL_SIZE PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE; do
          if [[ -n "''${!_db_env_name+x}" ]]; then
            printf 'export %s=%q\n' "$_db_env_name" "''${!_db_env_name}"
          fi
        done
      } >&"$_SIDECAR_DB_ENV_CREATION_FD" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      chmod 0600 -- "/proc/$$/fd/$_SIDECAR_DB_ENV_CREATION_FD" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      exec {_SIDECAR_DB_ENV_READ_FD}<"/proc/$$/fd/$_SIDECAR_DB_ENV_CREATION_FD" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      _creation_id="$(_sidecar_handoff_id "/proc/$$/fd/$_SIDECAR_DB_ENV_CREATION_FD")" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      _read_id="$(_sidecar_handoff_id "/proc/$$/fd/$_SIDECAR_DB_ENV_READ_FD")" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      _temp_id="$(_sidecar_handoff_id "$_SIDECAR_DB_ENV_TEMP_PATH")" || _temp_id=""
      _SIDECAR_DB_ENV_TEMP_ID="$_read_id"
      [[ ! -L "$_SIDECAR_DB_ENV_TEMP_PATH" && "$_temp_id" == "$_creation_id" &&
         "$_creation_id" == "$_read_id" ]] &&
        _sidecar_is_private_regular_handoff_id "$_read_id" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      ${pkgs.coreutils}/bin/sync -f -- "/proc/$$/fd/$_SIDECAR_DB_ENV_CREATION_FD" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      ${pkgs.coreutils}/bin/mv -T -- "$_db_env_tmp" ironclaw-db.env || {
        _sidecar_fail_db_env_publication
        return 1
      }
      ${pkgs.coreutils}/bin/sync -d -- . || {
        _sidecar_fail_db_env_publication
        return 1
      }

      _held_state_id="$(_sidecar_handoff_id "$_SIDECAR_STATE_FD_PATH")" || _held_state_id=""
      _public_state_id="$(_sidecar_handoff_id "$PERSIST_DIR/state")" || _public_state_id=""
      _held_id="$(_sidecar_handoff_id "$_SIDECAR_STATE_FD_PATH/ironclaw-db.env")" || _held_id=""
      _public_id="$(_sidecar_handoff_id "$PERSIST_DIR/state/ironclaw-db.env")" || _public_id=""
      _read_id="$(_sidecar_handoff_id "/proc/$$/fd/$_SIDECAR_DB_ENV_READ_FD")" || _read_id=""
      IFS=: read -r _state_dev _state_ino _state_type _state_mode _state_owner _state_links <<< "$_held_state_id"
      [[ ! -L "$_SIDECAR_STATE_FD_PATH/ironclaw-db.env" &&
         ! -L "$PERSIST_DIR/state/ironclaw-db.env" &&
         "$_held_state_id" == "$_public_state_id" && "$_state_type" == directory &&
         "$_state_mode" == 700 && "$_state_owner" == "$(id -u)" &&
         "$_held_id" == "$_read_id" && "$_read_id" == "$_public_id" ]] &&
        _sidecar_is_private_regular_handoff_id "$_read_id" || {
        _sidecar_fail_db_env_publication
        return 1
      }
      _SIDECAR_DB_ENV_PUBLISHED_ID="$_read_id"
      _SIDECAR_DB_ENV_TEMP_PATH=""
      _SIDECAR_DB_ENV_TEMP_ID=""
      _sidecar_close_db_env_creation_fd
      HANDOFF_DB_ENV_FD="$_SIDECAR_DB_ENV_READ_FD"
      _SIDECAR_DB_ENV_READ_FD=""
      _sidecar_promote_handoff_fd HANDOFF_DB_ENV_FD || {
        _sidecar_fail_db_env_publication
        return 1
      }
    }
    _sidecar_random_hex() {
      ${pkgs.coreutils}/bin/od -An -N32 -tx1 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' \n'
    }
    _sidecar_close_child_fds() {
      local _keep_state="''${1:-0}" _keep_config="''${2:-0}"
      local _keep_run_hook="''${3:-0}" _keep_ack_hook="''${4:-0}"

      [[ -z "$_SIDECAR_PARENT_FD" ]] || exec {_SIDECAR_PARENT_FD}<&-
      [[ -z "$_SIDECAR_PERSIST_FD" ]] || exec {_SIDECAR_PERSIST_FD}<&-
      [[ -z "$_SIDECAR_DATA_FD" ]] || exec {_SIDECAR_DATA_FD}<&-
      [[ -z "$_SIDECAR_PASSWORD_FD" ]] || exec {_SIDECAR_PASSWORD_FD}<&-
      [[ "$_keep_state" == 1 || -z "$_SIDECAR_STATE_FD" ]] || exec {_SIDECAR_STATE_FD}<&-
      [[ "$_keep_config" == 1 || -z "$_SIDECAR_GATE_CONFIG_FD" ]] || exec {_SIDECAR_GATE_CONFIG_FD}<&-
      [[ "$_keep_run_hook" == 1 || -z "$TEST_AFTER_COMMIT_DECISION_READY_FD" ]] || exec {TEST_AFTER_COMMIT_DECISION_READY_FD}>&-
      [[ "$_keep_run_hook" == 1 || -z "$TEST_AFTER_COMMIT_DECISION_RELEASE_FD" ]] || exec {TEST_AFTER_COMMIT_DECISION_RELEASE_FD}<&-
      [[ "$_keep_ack_hook" == 1 || -z "$TEST_AFTER_COMMIT_ACK_READY_FD" ]] || exec {TEST_AFTER_COMMIT_ACK_READY_FD}>&-
      [[ "$_keep_ack_hook" == 1 || -z "$TEST_AFTER_COMMIT_ACK_RELEASE_FD" ]] || exec {TEST_AFTER_COMMIT_ACK_RELEASE_FD}<&-
      [[ -z "$TEST_AFTER_OCI_POSTCHECK_READY_FD" ]] || exec {TEST_AFTER_OCI_POSTCHECK_READY_FD}>&-
      [[ -z "$TEST_AFTER_OCI_POSTCHECK_RELEASE_FD" ]] || exec {TEST_AFTER_OCI_POSTCHECK_RELEASE_FD}<&-
      [[ -z "$TEST_AFTER_CREATE_CIDFILE_READY_FD" ]] || exec {TEST_AFTER_CREATE_CIDFILE_READY_FD}>&-
      [[ -z "$TEST_AFTER_CREATE_CIDFILE_RELEASE_FD" ]] || exec {TEST_AFTER_CREATE_CIDFILE_RELEASE_FD}<&-
      [[ -z "$TEST_AFTER_PREPARE_READY_FD" ]] || exec {TEST_AFTER_PREPARE_READY_FD}>&-
      [[ -z "$TEST_AFTER_PREPARE_RELEASE_FD" ]] || exec {TEST_AFTER_PREPARE_RELEASE_FD}<&-
    }
    _sidecar_close_transaction_fds() {
      [[ -z "$_SIDECAR_GATE_ARCHIVE_FILE" ]] || ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_GATE_ARCHIVE_FILE"
      _SIDECAR_GATE_ARCHIVE_FILE=""
      [[ -z "$_SIDECAR_RUNTIME_OUTPUT_FILE" ]] || ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_RUNTIME_OUTPUT_FILE"
      _SIDECAR_RUNTIME_OUTPUT_FILE=""
      [[ -z "$_SIDECAR_GATE_CONFIG_FD" ]] || exec {_SIDECAR_GATE_CONFIG_FD}<&-
      _SIDECAR_GATE_CONFIG_FD=""
      [[ -z "$_SIDECAR_PASSWORD_FD" ]] || exec {_SIDECAR_PASSWORD_FD}<&-
      _SIDECAR_PASSWORD_FD=""
      [[ -z "$_SIDECAR_DATA_FD" ]] || exec {_SIDECAR_DATA_FD}<&-
      _SIDECAR_DATA_FD=""
      [[ -z "$_SIDECAR_STATE_FD" ]] || exec {_SIDECAR_STATE_FD}<&-
      _SIDECAR_STATE_FD=""
      [[ -z "$_SIDECAR_PERSIST_FD" ]] || exec {_SIDECAR_PERSIST_FD}<&-
      _SIDECAR_PERSIST_FD=""
      [[ -z "$_SIDECAR_PARENT_FD" ]] || exec {_SIDECAR_PARENT_FD}<&-
      _SIDECAR_PARENT_FD=""
      [[ -z "$TEST_AFTER_CREATE_CIDFILE_READY_FD" ]] || exec {TEST_AFTER_CREATE_CIDFILE_READY_FD}>&-
      TEST_AFTER_CREATE_CIDFILE_READY_FD=""
      [[ -z "$TEST_AFTER_CREATE_CIDFILE_RELEASE_FD" ]] || exec {TEST_AFTER_CREATE_CIDFILE_RELEASE_FD}<&-
      TEST_AFTER_CREATE_CIDFILE_RELEASE_FD=""
      [[ -z "$TEST_AFTER_PREPARE_READY_FD" ]] || exec {TEST_AFTER_PREPARE_READY_FD}>&-
      TEST_AFTER_PREPARE_READY_FD=""
      [[ -z "$TEST_AFTER_PREPARE_RELEASE_FD" ]] || exec {TEST_AFTER_PREPARE_RELEASE_FD}<&-
      TEST_AFTER_PREPARE_RELEASE_FD=""
      [[ -z "$TEST_AFTER_COMMIT_DECISION_READY_FD" ]] || exec {TEST_AFTER_COMMIT_DECISION_READY_FD}>&-
      TEST_AFTER_COMMIT_DECISION_READY_FD=""
      [[ -z "$TEST_AFTER_COMMIT_DECISION_RELEASE_FD" ]] || exec {TEST_AFTER_COMMIT_DECISION_RELEASE_FD}<&-
      TEST_AFTER_COMMIT_DECISION_RELEASE_FD=""
      [[ -z "$TEST_AFTER_COMMIT_ACK_READY_FD" ]] || exec {TEST_AFTER_COMMIT_ACK_READY_FD}>&-
      TEST_AFTER_COMMIT_ACK_READY_FD=""
      [[ -z "$TEST_AFTER_COMMIT_ACK_RELEASE_FD" ]] || exec {TEST_AFTER_COMMIT_ACK_RELEASE_FD}<&-
      TEST_AFTER_COMMIT_ACK_RELEASE_FD=""
      [[ -z "$TEST_AFTER_OCI_POSTCHECK_READY_FD" ]] || exec {TEST_AFTER_OCI_POSTCHECK_READY_FD}>&-
      TEST_AFTER_OCI_POSTCHECK_READY_FD=""
      [[ -z "$TEST_AFTER_OCI_POSTCHECK_RELEASE_FD" ]] || exec {TEST_AFTER_OCI_POSTCHECK_RELEASE_FD}<&-
      TEST_AFTER_OCI_POSTCHECK_RELEASE_FD=""
    }
    _sidecar_revalidate_transaction() {
      local _parent_id _persist_id _state_id _data_id

      if [[ "$_SIDECAR_IN_ROLLBACK" -eq 1 ]]; then
        _parent_id="$(_sidecar_path_id "$_SIDECAR_PARENT_FD_PATH")" || return 1
        _persist_id="$(_sidecar_path_id "$_SIDECAR_PERSIST_FD_PATH")" || return 1
        _state_id="$(_sidecar_path_id "$_SIDECAR_STATE_FD_PATH")" || return 1
        _data_id="$(_sidecar_path_id "$_SIDECAR_DATA_FD_PATH")" || return 1
        [[ "$_parent_id" == "$_SIDECAR_PARENT_ID" &&
           "$_persist_id" == "$_SIDECAR_PERSIST_PATH_ID" &&
           "$_state_id" == "$_SIDECAR_STATE_ID" &&
           "$_data_id" == "$_SIDECAR_DATA_ID" ]] || {
          echo "ocsb-$VARIANT: sidecar transaction descriptors changed" >&2
          return 1
        }
        return 0
      fi

      [[ ! -L "$_SIDECAR_PARENT_PATH" && ! -L "$_SIDECAR_PERSIST_PATH" &&
         ! -L "$_SIDECAR_STATE_PATH" && ! -L "$_SIDECAR_DATA_PATH" ]] || {
        echo "ocsb-$VARIANT: sidecar transaction path was replaced" >&2
        return 1
      }
      _parent_id="$(_sidecar_path_id "$_SIDECAR_PARENT_PATH")" || return 1
      _persist_id="$(_sidecar_path_id "$_SIDECAR_PERSIST_PATH")" || return 1
      _state_id="$(_sidecar_path_id "$_SIDECAR_STATE_PATH")" || return 1
      _data_id="$(_sidecar_path_id "$_SIDECAR_DATA_PATH")" || return 1
      [[ "$_parent_id" == "$_SIDECAR_PARENT_ID" &&
         "$_persist_id" == "$_SIDECAR_PERSIST_PATH_ID" &&
         "$_state_id" == "$_SIDECAR_STATE_ID" &&
         "$_data_id" == "$_SIDECAR_DATA_ID" &&
         "$_persist_id" == *":$(id -u):700" &&
         "$_state_id" == *":$(id -u):700" &&
         "$_data_id" == *":$(id -u):700" ]] || {
        echo "ocsb-$VARIANT: sidecar transaction path was replaced" >&2
        return 1
      }
    }
    _sidecar_oci_launch() {
      if [[ "$DB_SIDECAR_RUNTIME" == "podman" ]]; then
        exec "$DB_SIDECAR_RUNTIME" --remote=false "$@"
      else
        exec "$DB_SIDECAR_RUNTIME" "$@"
      fi
    }
    _sidecar_terminate_runtime() {
      local _signal="''${1:-TERM}" _pid="$_SIDECAR_RUNTIME_PID"
      local _deadline _stat_pid _stat_comm _stat_state _stat_rest

      [[ -n "$_pid" ]] || return 0
      kill -s "$_signal" "$_pid" 2>/dev/null || true
      _deadline=$((SECONDS + 2))
      while kill -0 "$_pid" 2>/dev/null; do
        _stat_state=""
        if [[ -r "/proc/$_pid/stat" ]]; then
          read -r _stat_pid _stat_comm _stat_state _stat_rest < "/proc/$_pid/stat" || true
          [[ "$_stat_state" == Z ]] && break
        fi
        if (( SECONDS >= _deadline )); then
          kill -KILL "$_pid" 2>/dev/null || true
          break
        fi
        ${pkgs.coreutils}/bin/sleep 0.05
      done
      wait "$_pid" 2>/dev/null || true
      _SIDECAR_RUNTIME_PID=""
    }
    _sidecar_terminate_password() {
      local _signal="''${1:-TERM}" _pid="$_SIDECAR_PASSWORD_PID"
      local _deadline _stat_pid _stat_comm _stat_state _stat_rest

      [[ -n "$_pid" ]] || return 0
      kill -s "$_signal" "$_pid" 2>/dev/null || true
      _deadline=$((SECONDS + 2))
      while kill -0 "$_pid" 2>/dev/null; do
        _stat_state=""
        if [[ -r "/proc/$_pid/stat" ]]; then
          read -r _stat_pid _stat_comm _stat_state _stat_rest < "/proc/$_pid/stat" || true
          [[ "$_stat_state" == Z ]] && break
        fi
        if (( SECONDS >= _deadline )); then
          kill -KILL "$_pid" 2>/dev/null || true
          break
        fi
        ${pkgs.coreutils}/bin/sleep 0.05
      done
      wait "$_pid" 2>/dev/null || true
      _SIDECAR_PASSWORD_PID=""
    }
    _sidecar_terminate_capture() {
      local _pid="$_SIDECAR_CAPTURE_PID"

      [[ -n "$_pid" ]] || return 0
      kill -TERM "$_pid" 2>/dev/null || true
      wait "$_pid" 2>/dev/null || true
      _SIDECAR_CAPTURE_PID=""
      [[ -z "$_SIDECAR_CAPTURE_READ_FD" ]] || exec {_SIDECAR_CAPTURE_READ_FD}<&-
      _SIDECAR_CAPTURE_READ_FD=""
    }
    _sidecar_read_runtime_output() {
      local _line _first_line=1

      _SIDECAR_RUNTIME_OUTPUT=""
      while IFS= read -r _line || [[ -n "$_line" ]]; do
        if [[ "$_first_line" -eq 0 ]]; then
          _SIDECAR_RUNTIME_OUTPUT+=$'\n'
        fi
        _SIDECAR_RUNTIME_OUTPUT+="$_line"
        _first_line=0
      done < "$_SIDECAR_RUNTIME_OUTPUT_FILE"
    }
    _sidecar_copy_gate_archive() {
      [[ -z "$_SIDECAR_GATE_ARCHIVE_FILE" ]] || ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_GATE_ARCHIVE_FILE"
      _SIDECAR_GATE_ARCHIVE_FILE="$(umask 077; ${pkgs.coreutils}/bin/mktemp "$_SIDECAR_STATE_FD_PATH/.sidecar-gate-archive.XXXXXX")" || return 1
      chmod 0600 "$_SIDECAR_GATE_ARCHIVE_FILE" || return 1
      _sidecar_oci_to_file "$_SIDECAR_GATE_ARCHIVE_FILE" cp "$_SIDECAR_CONTAINER_ID:/ocsb-sidecar-gate" -
    }
    _sidecar_oci() {
      local _status

      _sidecar_revalidate_transaction || return 1
      (
        _sidecar_close_child_fds 0 0 0 0
        _sidecar_oci_launch "$@"
      ) &
      _SIDECAR_RUNTIME_PID="$!"
      if wait "$_SIDECAR_RUNTIME_PID"; then
        _status=0
      else
        _status=$?
      fi
      _SIDECAR_RUNTIME_PID=""
      if [[ "$_status" -eq 0 && "$_SIDECAR_IN_ROLLBACK" -ne 1 ]]; then
        _sidecar_wait_fixture_barrier "$TEST_AFTER_OCI_POSTCHECK_READY_FD" "$TEST_AFTER_OCI_POSTCHECK_RELEASE_FD" after-oci-before-postcheck || return 1
      fi
      _sidecar_revalidate_transaction || return 1
      return "$_status"
    }
    _sidecar_oci_with_state_fd() {
      local _status

      _sidecar_revalidate_transaction || return 1
      (
        _sidecar_close_child_fds 1 0 1 0
        _sidecar_oci_launch "$@"
      ) &
      _SIDECAR_RUNTIME_PID="$!"
      if wait "$_SIDECAR_RUNTIME_PID"; then
        _status=0
      else
        _status=$?
      fi
      _SIDECAR_RUNTIME_PID=""
      if [[ "$_status" -eq 0 && "$_SIDECAR_IN_ROLLBACK" -ne 1 ]]; then
        _sidecar_wait_fixture_barrier "$TEST_AFTER_OCI_POSTCHECK_READY_FD" "$TEST_AFTER_OCI_POSTCHECK_RELEASE_FD" after-oci-before-postcheck || return 1
      fi
      _sidecar_revalidate_transaction || return 1
      return "$_status"
    }
    _sidecar_oci_start_gate() {
      local _status

      _sidecar_revalidate_transaction || return 1
      (
        _sidecar_close_child_fds 0 0 1 0
        _sidecar_oci_launch "$@"
      ) &
      _SIDECAR_RUNTIME_PID="$!"
      if wait "$_SIDECAR_RUNTIME_PID"; then
        _status=0
      else
        _status=$?
      fi
      _SIDECAR_RUNTIME_PID=""
      if [[ "$_status" -eq 0 && "$_SIDECAR_IN_ROLLBACK" -ne 1 ]]; then
        _sidecar_wait_fixture_barrier "$TEST_AFTER_OCI_POSTCHECK_READY_FD" "$TEST_AFTER_OCI_POSTCHECK_RELEASE_FD" after-oci-before-postcheck || return 1
      fi
      _sidecar_revalidate_transaction || return 1
      return "$_status"
    }
    _sidecar_oci_ack_gate() {
      local _status

      _sidecar_revalidate_transaction || return 1
      (
        _sidecar_close_child_fds 0 0 0 1
        _sidecar_oci_launch "$@"
      ) &
      _SIDECAR_RUNTIME_PID="$!"
      if wait "$_SIDECAR_RUNTIME_PID"; then
        _status=0
      else
        _status=$?
      fi
      _SIDECAR_RUNTIME_PID=""
      _sidecar_revalidate_transaction || return 1
      return "$_status"
    }
    _sidecar_oci_capture() {
      local _status

      [[ -n "$_SIDECAR_RUNTIME_OUTPUT_FILE" ]] || return 1
      : > "$_SIDECAR_RUNTIME_OUTPUT_FILE" || return 1
      _sidecar_revalidate_transaction || return 1
      coproc _sidecar_capture_child {
        _sidecar_close_child_fds 0 0 0 0
        _sidecar_oci_launch "$@"
      }
      _SIDECAR_RUNTIME_PID="$!"
      exec {_SIDECAR_CAPTURE_READ_FD}<&"''${_sidecar_capture_child[0]}" || {
        _sidecar_terminate_runtime TERM
        return 1
      }
      (
        _sidecar_close_child_fds 0 0 0 0
        exec ${pkgs.coreutils}/bin/cat <&"$_SIDECAR_CAPTURE_READ_FD"
      ) > "$_SIDECAR_RUNTIME_OUTPUT_FILE" &
      _SIDECAR_CAPTURE_PID="$!"
      if wait "$_SIDECAR_RUNTIME_PID"; then
        _status=0
      else
        _status=$?
      fi
      _SIDECAR_RUNTIME_PID=""
      exec {_SIDECAR_CAPTURE_READ_FD}<&-
      _SIDECAR_CAPTURE_READ_FD=""
      if ! wait "$_SIDECAR_CAPTURE_PID"; then
        _status=1
      fi
      _SIDECAR_CAPTURE_PID=""
      _sidecar_revalidate_transaction || return 1
      _sidecar_read_runtime_output
      return "$_status"
    }
    _sidecar_oci_to_file() {
      local _output_file="$1" _status
      shift

      : > "$_output_file" || return 1
      _sidecar_revalidate_transaction || return 1
      (
        _sidecar_close_child_fds 0 0 0 0
        _sidecar_oci_launch "$@"
      ) > "$_output_file" &
      _SIDECAR_RUNTIME_PID="$!"
      if wait "$_SIDECAR_RUNTIME_PID"; then
        _status=0
      else
        _status=$?
      fi
      _SIDECAR_RUNTIME_PID=""
      _sidecar_revalidate_transaction || return 1
      return "$_status"
    }
    _sidecar_oci_copy_gate_archive() {
      local _status _gate_status

      [[ -z "$_SIDECAR_GATE_ARCHIVE_FILE" ]] || ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_GATE_ARCHIVE_FILE"
      _SIDECAR_GATE_ARCHIVE_FILE="$(umask 077; ${pkgs.coreutils}/bin/mktemp "$_SIDECAR_STATE_FD_PATH/$_SIDECAR_TXN_REL/archive.XXXXXX")" || return 1
      ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_GATE_ARCHIVE_FILE" || return 1
      ${pkgs.coreutils}/bin/mkfifo -m 0600 "$_SIDECAR_GATE_ARCHIVE_FILE" || return 1
      _sidecar_revalidate_transaction || return 1
      (
        _sidecar_close_child_fds 0 0 0 0
        _sidecar_oci_launch cp - "$_SIDECAR_CONTAINER_ID:/"
      ) < "$_SIDECAR_GATE_ARCHIVE_FILE" &
      _SIDECAR_RUNTIME_PID="$!"
      if (
        _sidecar_close_child_fds 0 1 0 0
        exec "$SIDECAR_GATE_BIN" archive --config-fd "$_SIDECAR_GATE_CONFIG_FD"
      ) > "$_SIDECAR_GATE_ARCHIVE_FILE"; then
        _gate_status=0
      else
        _gate_status=$?
      fi
      if wait "$_SIDECAR_RUNTIME_PID"; then
        _status=0
      else
        _status=$?
      fi
      _SIDECAR_RUNTIME_PID=""
      ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_GATE_ARCHIVE_FILE"
      _SIDECAR_GATE_ARCHIVE_FILE=""
      _sidecar_revalidate_transaction || return 1
      [[ "$_gate_status" -eq 0 && "$_status" -eq 0 ]]
    }
    _sidecar_wait_fixture_barrier() {
      local _ready_fd="$1" _release_fd="$2" _description="$3" _byte
      [[ -z "$_ready_fd" ]] && return 0
      printf 'R' >&"$_ready_fd" || {
        echo "ocsb-$VARIANT: cannot signal $_description test barrier" >&2
        return 1
      }
      IFS= read -r -n 1 _byte <&"$_release_fd" || {
        echo "ocsb-$VARIANT: $_description test barrier was not released" >&2
        return 1
      }
    }
    _sidecar_parse_decision() {
      if [[ "$_SIDECAR_RUNTIME_OUTPUT" =~ ^DECISION\ (absent|commit|abort)\ $_SIDECAR_GENERATION\ ([0-9a-f]{64})$ ]]; then
        if [[ -n "$_SIDECAR_GATE_RUN_NONCE" && "$_SIDECAR_GATE_RUN_NONCE" != "''${BASH_REMATCH[2]}" ]]; then
          echo "ocsb-$VARIANT: sidecar gate run changed during decision" >&2
          return 1
        fi
        _SIDECAR_GATE_DECISION="''${BASH_REMATCH[1]}"
        _SIDECAR_GATE_RUN_NONCE="''${BASH_REMATCH[2]}"
        return 0
      fi
      echo "ocsb-$VARIANT: invalid sidecar gate decision response" >&2
      return 1
    }
    _sidecar_parse_prepared() {
      if [[ "$_SIDECAR_RUNTIME_OUTPUT" =~ ^PREPARED\ $_SIDECAR_GENERATION\ ([0-9a-f]{64})$ ]]; then
        if [[ -n "$_SIDECAR_GATE_RUN_NONCE" && "$_SIDECAR_GATE_RUN_NONCE" != "''${BASH_REMATCH[1]}" ]]; then
          echo "ocsb-$VARIANT: sidecar gate run changed before prepare" >&2
          return 1
        fi
        _SIDECAR_GATE_RUN_NONCE="''${BASH_REMATCH[1]}"
        _SIDECAR_PREPARED=1
        return 0
      fi
      echo "ocsb-$VARIANT: invalid sidecar gate prepare response" >&2
      return 1
    }
    _sidecar_parse_verified() {
      if [[ "$_SIDECAR_RUNTIME_OUTPUT" =~ ^MOUNT-VERIFIED\ $_SIDECAR_GENERATION\ ([0-9a-f]{64})$ ]]; then
        if [[ -n "$_SIDECAR_GATE_RUN_NONCE" && "$_SIDECAR_GATE_RUN_NONCE" != "''${BASH_REMATCH[1]}" ]]; then
          echo "ocsb-$VARIANT: sidecar gate run changed during mount verification" >&2
          return 1
        fi
        _SIDECAR_VERIFIED_RUN_NONCE="''${BASH_REMATCH[1]}"
        _SIDECAR_GATE_RUN_NONCE="$_SIDECAR_VERIFIED_RUN_NONCE"
        return 0
      fi
      echo "ocsb-$VARIANT: invalid sidecar gate verify response" >&2
      return 1
    }
    _sidecar_validate_immutable_id() {
      local _id="$1"
      [[ "$_id" =~ ^[0-9a-f]{64}$ ]] || return 1
      _sidecar_oci_capture inspect --format '{{.Id}}' "$_id" || return 1
      [[ "$_SIDECAR_RUNTIME_OUTPUT" == "$_id" ]] || return 1
      _sidecar_oci_capture inspect --format '{{index .Config.Labels "io.ocsb.generation"}}' "$_id" || return 1
      [[ "$_SIDECAR_RUNTIME_OUTPUT" == "$_SIDECAR_GENERATION" ]] || return 1
    }
    _sidecar_recover_created_id() {
      local _path _path_id _fd_id _owner _mode _links _size _candidate
      [[ -n "$_SIDECAR_CIDFILE_REL" && -n "$_SIDECAR_STATE_FD_PATH" ]] || return 1
      _path="$_SIDECAR_STATE_FD_PATH/$_SIDECAR_CIDFILE_REL"
      [[ ! -L "$_path" && -f "$_path" ]] || return 1
      _path_id="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i:%u:%a:%h:%s' -- "$_path")" || return 1
      IFS=: read -r _ _ _owner _mode _links _size <<< "$_path_id"
      [[ "$_owner" == "$(id -u)" && "$_mode" == 600 && "$_links" == 1 && "$_size" == 65 ]] || return 1
      exec {_sidecar_cid_fd}<"$_path" || return 1
      _fd_id="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i:%u:%a:%h:%s' -- "/proc/$$/fd/$_sidecar_cid_fd")" || {
        exec {_sidecar_cid_fd}<&-
        return 1
      }
      IFS= read -r _candidate <&"$_sidecar_cid_fd" || {
        exec {_sidecar_cid_fd}<&-
        return 1
      }
      exec {_sidecar_cid_fd}<&-
      [[ ! -L "$_path" && "$_path_id" == "$_fd_id" && "$_candidate" =~ ^[0-9a-f]{64}$ ]] || return 1
      _sidecar_validate_immutable_id "$_candidate" || return 1
      _SIDECAR_CREATED_BY_CALL=1
      _SIDECAR_CONTAINER_ID="$_candidate"
      return 0
    }
    _sidecar_remove_transaction_receipts() {
      local _failed=0
      if [[ -n "$_SIDECAR_CIDFILE_REL" ]]; then
        if ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_STATE_FD_PATH/$_SIDECAR_CIDFILE_REL"; then
          _SIDECAR_CIDFILE_REL=""
        else
          _failed=1
        fi
      fi
      if [[ -n "$_SIDECAR_GATE_CONFIG_PATH" ]]; then
        if ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_GATE_CONFIG_PATH"; then
          _SIDECAR_GATE_CONFIG_PATH=""
        else
          _failed=1
        fi
      fi
      if [[ -n "$_SIDECAR_GATE_ARCHIVE_FILE" ]]; then
        if ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_GATE_ARCHIVE_FILE"; then
          _SIDECAR_GATE_ARCHIVE_FILE=""
        else
          _failed=1
        fi
      fi
      if [[ -n "$_SIDECAR_TXN_REL" && "$_failed" -eq 0 ]]; then
        if ${pkgs.coreutils}/bin/rmdir -- "$_SIDECAR_STATE_FD_PATH/$_SIDECAR_TXN_REL"; then
          _SIDECAR_TXN_REL=""
        else
          _failed=1
        fi
      fi
      return "$_failed"
    }
    _sidecar_gate_query_running() {
      _sidecar_oci_capture exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate \
        decision --query --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION" || return 1
      _sidecar_parse_decision
    }
    _sidecar_gate_query_archive() {
      _sidecar_copy_gate_archive || return 1
      : > "$_SIDECAR_RUNTIME_OUTPUT_FILE" || return 1
      (
        _sidecar_close_child_fds 0 0 0 0
        exec "$SIDECAR_GATE_BIN" decision --query --generation "$_SIDECAR_GENERATION" --state-archive-fd 0
      ) < "$_SIDECAR_GATE_ARCHIVE_FILE" > "$_SIDECAR_RUNTIME_OUTPUT_FILE" || return 1
      _sidecar_read_runtime_output
      _sidecar_parse_decision
    }
    _sidecar_gate_wait_ack_archive() {
      local _decision="$1"
      _sidecar_copy_gate_archive || return 1
      (
        _sidecar_close_child_fds 0 0 0 0
        exec "$SIDECAR_GATE_BIN" ack --query --decision "$_decision" --generation "$_SIDECAR_GENERATION" --state-archive-fd 0
      ) < "$_SIDECAR_GATE_ARCHIVE_FILE"
    }
    _sidecar_gate_wait_ack() {
      local _decision="$1" _status
      _sidecar_oci_capture inspect --format '{{.State.Status}}' "$_SIDECAR_CONTAINER_ID" || return 1
      _status="$_SIDECAR_RUNTIME_OUTPUT"
      if [[ "$_status" == "running" ]]; then
        if [[ "$_decision" == "commit" ]]; then
          _sidecar_oci_ack_gate exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate \
            ack --wait --decision commit --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION" \
            "''${TEST_AFTER_COMMIT_ACK_READY_FD:+--test-after-commit-ack-before-return-ready-fd}" \
            "''${TEST_AFTER_COMMIT_ACK_READY_FD:+$TEST_AFTER_COMMIT_ACK_READY_FD}" \
            "''${TEST_AFTER_COMMIT_ACK_RELEASE_FD:+--test-after-commit-ack-before-return-release-fd}" \
            "''${TEST_AFTER_COMMIT_ACK_RELEASE_FD:+$TEST_AFTER_COMMIT_ACK_RELEASE_FD}" && return 0
        else
          _sidecar_oci exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate \
            ack --wait --decision abort --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION" && return 0
        fi
      fi
      _sidecar_gate_wait_ack_archive "$_decision"
    }
    _sidecar_gate_verify_and_prepare() {
      _sidecar_oci_capture exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate \
        verify --config /ocsb-sidecar-gate/config --mount /var/lib/postgresql --generation "$_SIDECAR_GENERATION" || return 1
      _sidecar_parse_verified || return 1
      _sidecar_gate_prepare_only
    }
    _sidecar_gate_prepare_only() {
      _sidecar_oci_capture exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate \
        release --prepare --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION" || return 1
      _sidecar_parse_prepared
    }
    _sidecar_gate_establish_prepare_for_cleanup() {
      if _sidecar_gate_query_running; then
        if [[ "$_SIDECAR_GATE_DECISION" == absent && "$_SIDECAR_PREPARED" -eq 0 ]]; then
          _sidecar_gate_prepare_only || return 1
          _sidecar_gate_query_running || return 1
        fi
        return 0
      fi
      _sidecar_gate_prepare_only || return 1
      _sidecar_gate_query_running
    }
    _sidecar_assert_absent() {
      local _expected_id="$1" _listed_id
      _sidecar_oci_capture ps --all --no-trunc --format '{{.ID}}' || return 1
      while IFS= read -r _listed_id; do
        [[ "$_listed_id" != "$_expected_id" ]] || return 1
      done <<< "$_SIDECAR_RUNTIME_OUTPUT"
      return 0
    }
    _sidecar_assert_stopped() {
      _sidecar_oci_capture inspect --format '{{.State.Status}}' "$1" || return 1
      [[ "$_SIDECAR_RUNTIME_OUTPUT" == created || "$_SIDECAR_RUNTIME_OUTPUT" == exited ]]
    }
    _sidecar_rollback_origin() {
      local _status
      case "$_SIDECAR_ORIGIN" in
        absent)
          _sidecar_oci rm -f "$_SIDECAR_CONTAINER_ID" || return 1
          _sidecar_assert_absent "$_SIDECAR_CONTAINER_ID" || return 1
          if [[ "$_SIDECAR_PASSWORD_CREATED_BY_TRANSACTION" -eq 1 ]]; then
            ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_PERSIST_FD_PATH/sidecar-db-password"
          fi
          _sidecar_remove_transaction_receipts
          ;;
        stopped)
          _sidecar_oci_capture inspect --format '{{.State.Status}}' "$_SIDECAR_CONTAINER_ID" || return 1
          _status="$_SIDECAR_RUNTIME_OUTPUT"
          if [[ "$_status" == "running" ]]; then
            _sidecar_oci stop "$_SIDECAR_CONTAINER_ID" || return 1
          fi
          _sidecar_assert_stopped "$_SIDECAR_CONTAINER_ID" || return 1
          ;;
        running)
          :
          ;;
        *) return 1 ;;
      esac
    }
    _sidecar_cleanup_lifecycle() {
      local _status
      _SIDECAR_IN_ROLLBACK=1
      if [[ "$_SIDECAR_GATE_RELEASED" -eq 1 ]]; then
        _sidecar_remove_transaction_receipts || true
        return 0
      fi
      if [[ -z "$_SIDECAR_CONTAINER_ID" ]]; then
        _sidecar_recover_created_id || return 0
      else
        _sidecar_validate_immutable_id "$_SIDECAR_CONTAINER_ID" || return 0
      fi
      _sidecar_oci_capture inspect --format '{{.State.Status}}' "$_SIDECAR_CONTAINER_ID" || return 0
      _status="$_SIDECAR_RUNTIME_OUTPUT"
      if [[ "$_SIDECAR_STARTED_BY_TRANSACTION" -eq 0 ]]; then
        if [[ "$_SIDECAR_CREATED_BY_CALL" -eq 1 &&
              ( "$_status" == "created" || "$_status" == "exited" ) ]]; then
          _sidecar_oci rm -f "$_SIDECAR_CONTAINER_ID" || return 0
          _sidecar_assert_absent "$_SIDECAR_CONTAINER_ID" || return 0
          if [[ "$_SIDECAR_PASSWORD_CREATED_BY_TRANSACTION" -eq 1 ]]; then
            ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_PERSIST_FD_PATH/sidecar-db-password"
          fi
          _sidecar_remove_transaction_receipts
          return 0
        fi
        if [[ "$_SIDECAR_ORIGIN" == stopped && "$_SIDECAR_START_ATTEMPTED" -eq 0 ]]; then
          return 0
        fi
      fi
      if [[ "$_status" == "running" ]]; then
        _sidecar_gate_establish_prepare_for_cleanup || return 0
      else
        _sidecar_gate_query_archive || return 0
      fi
      case "$_SIDECAR_GATE_DECISION" in
        commit)
          _sidecar_remove_transaction_receipts
          return 0
          ;;
        abort)
          _sidecar_gate_wait_ack abort || return 0
          _sidecar_rollback_origin || return 0
          return 0
          ;;
        absent)
          [[ "$_status" == "running" ]] || return 0
          _sidecar_oci_capture exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate \
            decision --abort --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION" || return 0
          _sidecar_parse_decision || return 0
          if [[ "$_SIDECAR_GATE_DECISION" == "commit" ]]; then
            return 0
          fi
          [[ "$_SIDECAR_GATE_DECISION" == "abort" ]] || return 0
          _sidecar_gate_wait_ack abort || return 0
          _sidecar_rollback_origin || return 0
          return 0
          ;;
        *) return 0 ;;
      esac
    }
    _sidecar_cleanup() {
      [[ "$_SIDECAR_CLEANUP_DONE" -eq 0 ]] || return 0
      _SIDECAR_CLEANUP_DONE=1
      trap - EXIT
      trap : INT TERM HUP
      set +e
      _sidecar_cleanup_db_env_temp || true
      _sidecar_close_db_env_read_fd
      _sidecar_close_db_env_creation_fd
      _sidecar_close_handoff_fds
      _sidecar_terminate_runtime TERM
      _sidecar_terminate_capture
      _sidecar_terminate_password TERM
      _sidecar_cleanup_lifecycle
      [[ -z "$_SIDECAR_PASSWORD_TMP" ]] || ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_PASSWORD_TMP"
      [[ -z "$_SIDECAR_ENV_FILE" ]] || ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_ENV_FILE"
      _sidecar_close_transaction_fds
      set -e
    }
    _sidecar_on_signal() {
      local _status="$1"
      _sidecar_cleanup
      exit "$_status"
    }
    trap _sidecar_cleanup EXIT
    trap '_sidecar_on_signal 130' INT
    trap '_sidecar_on_signal 143' TERM
    trap '_sidecar_on_signal 129' HUP

    [[ -x "$SIDECAR_GATE_BIN" ]] || {
      echo "ocsb-$VARIANT: sidecar gate executable is unavailable" >&2
      exit 1
    }
    command -v "$DB_SIDECAR_RUNTIME" >/dev/null 2>&1 || {
      echo "ocsb-$VARIANT: db mode 'sidecar' requires '$DB_SIDECAR_RUNTIME' on host PATH" >&2
      exit 1
    }
    _SIDECAR_PARENT_PATH="$(${pkgs.coreutils}/bin/dirname "$PERSIST_DIR")"
    _SIDECAR_PERSIST_PATH="$PERSIST_DIR"
    _SIDECAR_STATE_PATH="$PERSIST_DIR/state"
    _SIDECAR_DATA_PATH="$PERSIST_DIR/pgdata-sidecar"
    [[ ! -L "$_SIDECAR_STATE_PATH/ironclaw-sidecar.lock" ]] || {
      echo "ocsb-$VARIANT: unsafe sidecar lock path" >&2
      exit 1
    }
    exec {_SIDECAR_PARENT_FD}<"$_SIDECAR_PARENT_PATH"
    _SIDECAR_PARENT_FD_PATH="/proc/$$/fd/$_SIDECAR_PARENT_FD"
    ${pkgs.util-linux}/bin/flock "$_SIDECAR_PARENT_FD"
    exec {_SIDECAR_PERSIST_FD}<"$_SIDECAR_PERSIST_PATH"
    _SIDECAR_PERSIST_FD_PATH="/proc/$$/fd/$_SIDECAR_PERSIST_FD"
    exec {_SIDECAR_STATE_FD}<"$_SIDECAR_STATE_PATH"
    _SIDECAR_STATE_FD_PATH="/proc/$$/fd/$_SIDECAR_STATE_FD"
    exec {_SIDECAR_DATA_FD}<"$_SIDECAR_DATA_PATH"
    _SIDECAR_DATA_FD_PATH="/proc/$$/fd/$_SIDECAR_DATA_FD"
    _SIDECAR_PARENT_ID="$(_sidecar_path_id "$_SIDECAR_PARENT_FD_PATH")" || exit 1
    _SIDECAR_PERSIST_PATH_ID="$(_sidecar_path_id "$_SIDECAR_PERSIST_FD_PATH")" || exit 1
    _SIDECAR_STATE_ID="$(_sidecar_path_id "$_SIDECAR_STATE_FD_PATH")" || exit 1
    _SIDECAR_DATA_ID="$(_sidecar_path_id "$_SIDECAR_DATA_FD_PATH")" || exit 1
    _sidecar_revalidate_transaction || exit 1
    ${pkgs.util-linux}/bin/flock "$_SIDECAR_STATE_FD"
    _SIDECAR_RUNTIME_OUTPUT_FILE="$(umask 077; ${pkgs.coreutils}/bin/mktemp "$_SIDECAR_STATE_FD_PATH/.sidecar-oci-output.XXXXXX")" || exit 1
    chmod 0600 "$_SIDECAR_RUNTIME_OUTPUT_FILE" || exit 1
    _SIDECAR_PERSIST_ID="$(
      printf '%s\0%s\0%s\0%s\0%s' "$PERSIST_DIR" "$_SIDECAR_PARENT_ID" "$_SIDECAR_PERSIST_PATH_ID" \
        "$_SIDECAR_STATE_ID" "$_SIDECAR_DATA_ID" \
        | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f 1
    )"
    _SIDECAR_VOLUME="$PERSIST_DIR/pgdata-sidecar"
    IFS=: read -r _SIDECAR_DATA_DEV _SIDECAR_DATA_INO _ _ _ <<< "$_SIDECAR_DATA_ID"

    _SIDECAR_EXISTS=0
    _sidecar_oci_capture ps --all --format '{{.Names}}' || {
      echo "ocsb-$VARIANT: cannot discover sidecar container" >&2
      exit 1
    }
    while IFS= read -r _sidecar_listed_name; do
      [[ "$_sidecar_listed_name" != "$DB_SIDECAR_CONTAINER" ]] || _SIDECAR_EXISTS=1
    done <<< "$_SIDECAR_RUNTIME_OUTPUT"
    if [[ "$_SIDECAR_EXISTS" -eq 1 ]]; then
      _sidecar_oci_capture inspect --format '{{.Id}}' "$DB_SIDECAR_CONTAINER" || {
        echo "ocsb-$VARIANT: sidecar identity mismatch: container '$DB_SIDECAR_CONTAINER': Id" >&2
        exit 1
      }
      _SIDECAR_CONTAINER_ID="$_SIDECAR_RUNTIME_OUTPUT"
      [[ "$_SIDECAR_CONTAINER_ID" =~ ^[0-9a-f]{64}$ ]] || {
        echo "ocsb-$VARIANT: sidecar identity mismatch: container '$DB_SIDECAR_CONTAINER': Id" >&2
        exit 1
      }
      _sidecar_oci_capture inspect --format '{{index .Config.Labels "io.ocsb.protocol"}}' "$_SIDECAR_CONTAINER_ID" || exit 1
      _SIDECAR_PROTOCOL="$_SIDECAR_RUNTIME_OUTPUT"
      _sidecar_oci_capture inspect --format '{{index .Config.Labels "io.ocsb.generation"}}' "$_SIDECAR_CONTAINER_ID" || exit 1
      _SIDECAR_GENERATION="$_SIDECAR_RUNTIME_OUTPUT"
      _sidecar_oci_capture inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Source}}|{{.Destination}}{{end}}{{end}}' "$_SIDECAR_CONTAINER_ID" || exit 1
      _SIDECAR_MOUNT="$_SIDECAR_RUNTIME_OUTPUT"
      if [[ "$_SIDECAR_PROTOCOL" != "sidecar-gate-v1" || ! "$_SIDECAR_GENERATION" =~ ^[0-9a-f]{64}$ ]]; then
        if [[ "$_SIDECAR_MOUNT" == /proc/* ]]; then
          echo "ocsb-$VARIANT: legacy sidecar source refused without mutation: container '$DB_SIDECAR_CONTAINER'; recreate it with the gated sidecar lifecycle" >&2
        else
          echo "ocsb-$VARIANT: legacy sidecar refused without mutation: container '$DB_SIDECAR_CONTAINER'; recreate it with the gated sidecar lifecycle" >&2
        fi
        exit 1
      fi
      _SIDECAR_IDENTITY_MISMATCHES=()
      if [[ "$DB_SIDECAR_RUNTIME" == podman ]]; then
        _SIDECAR_IMAGE_INSPECT_FORMAT='{{.ImageName}}'
        _SIDECAR_IMAGE_INSPECT_FIELD=ImageName
      else
        _SIDECAR_IMAGE_INSPECT_FORMAT='{{.Config.Image}}'
        _SIDECAR_IMAGE_INSPECT_FIELD=Config.Image
      fi
      _sidecar_oci_capture inspect --format "$_SIDECAR_IMAGE_INSPECT_FORMAT" "$_SIDECAR_CONTAINER_ID" || _SIDECAR_IDENTITY_MISMATCHES+=("$_SIDECAR_IMAGE_INSPECT_FIELD")
      [[ "$_SIDECAR_RUNTIME_OUTPUT" == "$DB_SIDECAR_IMAGE" ]] || _SIDECAR_IDENTITY_MISMATCHES+=("$_SIDECAR_IMAGE_INSPECT_FIELD")
      for _sidecar_label_check in \
        'io.ocsb.owner=ocsb-ironclaw' \
        "io.ocsb.persist-id=$_SIDECAR_PERSIST_ID" \
        "io.ocsb.image=$DB_SIDECAR_IMAGE" \
        "io.ocsb.volume=$_SIDECAR_VOLUME" \
        "io.ocsb.port=$DB_SIDECAR_PORT" \
        "io.ocsb.data-id=$_SIDECAR_DATA_ID" \
        'io.ocsb.protocol=sidecar-gate-v1' \
        "io.ocsb.generation=$_SIDECAR_GENERATION"; do
        _sidecar_label_name="''${_sidecar_label_check%%=*}"
        _sidecar_label_value="''${_sidecar_label_check#*=}"
        _sidecar_oci_capture inspect --format "{{index .Config.Labels \"$_sidecar_label_name\"}}" "$_SIDECAR_CONTAINER_ID" || _SIDECAR_RUNTIME_OUTPUT=""
        [[ "$_SIDECAR_RUNTIME_OUTPUT" == "$_sidecar_label_value" ]] || _SIDECAR_IDENTITY_MISMATCHES+=("$_sidecar_label_name")
      done
      [[ "$_SIDECAR_MOUNT" == "$_SIDECAR_VOLUME|/var/lib/postgresql" ]] || _SIDECAR_IDENTITY_MISMATCHES+=('Mounts[/var/lib/postgresql]')
      _sidecar_oci_capture inspect --format '{{range (index .NetworkSettings.Ports "5432/tcp")}}{{.HostIp}}|{{.HostPort}}{{end}}' "$_SIDECAR_CONTAINER_ID" || _SIDECAR_RUNTIME_OUTPUT=""
      [[ "$_SIDECAR_RUNTIME_OUTPUT" == "127.0.0.1|$DB_SIDECAR_PORT" ]] || _SIDECAR_IDENTITY_MISMATCHES+=('NetworkSettings.Ports[5432/tcp]')
      _sidecar_oci_capture inspect --format '{{json .Config.Entrypoint}}' "$_SIDECAR_CONTAINER_ID" || _SIDECAR_RUNTIME_OUTPUT=""
      [[ "$_SIDECAR_RUNTIME_OUTPUT" == '["/ocsb-sidecar-gate/ocsb-sidecar-gate"]' ]] || _SIDECAR_IDENTITY_MISMATCHES+=('Config.Entrypoint')
      _sidecar_oci_capture inspect --format '{{json .Config.Cmd}}' "$_SIDECAR_CONTAINER_ID" || _SIDECAR_RUNTIME_OUTPUT=""
      [[ "$_SIDECAR_RUNTIME_OUTPUT" == "[\"run\",\"--config\",\"/ocsb-sidecar-gate/config\",\"--generation\",\"$_SIDECAR_GENERATION\"]" ]] || _SIDECAR_IDENTITY_MISMATCHES+=('Config.Cmd')
      if [[ "''${#_SIDECAR_IDENTITY_MISMATCHES[@]}" -ne 0 ]]; then
        echo "ocsb-$VARIANT: sidecar identity mismatch: container '$DB_SIDECAR_CONTAINER': $(IFS=,; printf '%s' "''${_SIDECAR_IDENTITY_MISMATCHES[*]}")" >&2
        exit 1
      fi
      _sidecar_oci_capture inspect --format '{{.State.Status}}' "$_SIDECAR_CONTAINER_ID" || {
        echo "ocsb-$VARIANT: sidecar identity mismatch: container '$DB_SIDECAR_CONTAINER': State.Status" >&2
        exit 1
      }
      case "$_SIDECAR_RUNTIME_OUTPUT" in
        running) _SIDECAR_ORIGIN=running ;;
        created|exited) _SIDECAR_ORIGIN=stopped ;;
        *) echo "ocsb-$VARIANT: sidecar identity mismatch: container '$DB_SIDECAR_CONTAINER': State.Status" >&2; exit 1 ;;
      esac
    else
      _SIDECAR_ORIGIN=absent
      _SIDECAR_GENERATION="$(_sidecar_random_hex)" || exit 1
      [[ "$_SIDECAR_GENERATION" =~ ^[0-9a-f]{64}$ ]] || exit 1
      _sidecar_oci_capture image inspect --format '{{json .Config.Entrypoint}}' "$DB_SIDECAR_IMAGE" || exit 1
      _SIDECAR_IMAGE_ENTRYPOINT="$_SIDECAR_RUNTIME_OUTPUT"
      _sidecar_oci_capture image inspect --format '{{json .Config.Cmd}}' "$DB_SIDECAR_IMAGE" || exit 1
      _SIDECAR_IMAGE_CMD="$_SIDECAR_RUNTIME_OUTPUT"
    fi

    _sidecar_read_password() {
      local _path="$1" _id _fd_id _current_id _owner _mode _links _size
      local -a _password_lines=()
      [[ ! -L "$_path" && -f "$_path" ]] || {
        echo "ocsb-$VARIANT: unsafe sidecar password file" >&2
        return 1
      }
      _id="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i:%u:%a:%h:%s' -- "$_path")" || {
        echo "ocsb-$VARIANT: unsafe sidecar password file" >&2
        return 1
      }
      IFS=: read -r _ _ _owner _mode _links _size <<< "$_id"
      [[ "$_owner" == "$(id -u)" && "$_mode" == 600 && "$_links" == 1 ]] || {
        echo "ocsb-$VARIANT: unsafe sidecar password file" >&2
        return 1
      }
      exec {_SIDECAR_PASSWORD_FD}<"$_path" || {
        echo "ocsb-$VARIANT: unsafe sidecar password file" >&2
        return 1
      }
      _fd_id="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i:%u:%a:%h:%s' -- "/proc/$$/fd/$_SIDECAR_PASSWORD_FD")" || {
        exec {_SIDECAR_PASSWORD_FD}<&-
        _SIDECAR_PASSWORD_FD=""
        echo "ocsb-$VARIANT: unsafe sidecar password file" >&2
        return 1
      }
      mapfile -t _password_lines < "/proc/$$/fd/$_SIDECAR_PASSWORD_FD" || {
        exec {_SIDECAR_PASSWORD_FD}<&-
        _SIDECAR_PASSWORD_FD=""
        echo "ocsb-$VARIANT: unsafe sidecar password file" >&2
        return 1
      }
      exec {_SIDECAR_PASSWORD_FD}<&-
      _SIDECAR_PASSWORD_FD=""
      _current_id="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i:%u:%a:%h:%s' -- "$_path")" || _current_id=""
      [[ ! -L "$_path" && "$_id" == "$_fd_id" && "$_id" == "$_current_id" ]] || {
        echo "ocsb-$VARIANT: unsafe sidecar password file" >&2
        return 1
      }
      [[ "$_size" == 49 && "''${#_password_lines[@]}" -eq 1 && "''${_password_lines[0]}" =~ ^[0-9a-f]{48}$ ]] || {
        echo "ocsb-$VARIANT: malformed sidecar password file" >&2
        return 1
      }
      DB_SIDECAR_PASSWORD="''${_password_lines[0]}"
    }
    _SIDECAR_PASSWORD_FILE="$_SIDECAR_PERSIST_FD_PATH/sidecar-db-password"
    if [[ -e "$_SIDECAR_PASSWORD_FILE" || -L "$_SIDECAR_PASSWORD_FILE" ]]; then
      _sidecar_read_password "$_SIDECAR_PASSWORD_FILE" || exit 1
    elif [[ "$_SIDECAR_ORIGIN" != absent ]]; then
      echo "ocsb-$VARIANT: sidecar container '$DB_SIDECAR_CONTAINER' already exists, but its password file is missing" >&2
      exit 1
    else
      _SIDECAR_PASSWORD_TMP="$(umask 077; ${pkgs.coreutils}/bin/mktemp "$_SIDECAR_PERSIST_FD_PATH/.sidecar-db-password.XXXXXX")" || exit 1
      (
        _sidecar_close_child_fds 0 0 0 0
        exec ${pkgs.openssl}/bin/openssl rand -hex 24
      ) > "$_SIDECAR_PASSWORD_TMP" &
      _SIDECAR_PASSWORD_PID="$!"
      if ! wait "$_SIDECAR_PASSWORD_PID"; then
        _SIDECAR_PASSWORD_PID=""
        ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_PASSWORD_TMP"
        _SIDECAR_PASSWORD_TMP=""
        echo "ocsb-$VARIANT: cannot publish sidecar password file" >&2
        exit 1
      fi
      _SIDECAR_PASSWORD_PID=""
      chmod 0600 "$_SIDECAR_PASSWORD_TMP" || exit 1
      ${pkgs.coreutils}/bin/mv -T -- "$_SIDECAR_PASSWORD_TMP" "$_SIDECAR_PASSWORD_FILE" || exit 1
      _SIDECAR_PASSWORD_TMP=""
      _SIDECAR_PASSWORD_CREATED_BY_TRANSACTION=1
      _sidecar_read_password "$_SIDECAR_PASSWORD_FILE" || exit 1
    fi

    if [[ "$_SIDECAR_ORIGIN" == absent ]]; then
      _SIDECAR_TXN_NONCE="$(_sidecar_random_hex)" || exit 1
      [[ "$_SIDECAR_TXN_NONCE" =~ ^[0-9a-f]{64}$ ]] || exit 1
      _SIDECAR_TXN_REL=".sidecar-txn.$_SIDECAR_GENERATION.$_SIDECAR_TXN_NONCE"
      ( umask 077; ${pkgs.coreutils}/bin/mkdir -- "$_SIDECAR_STATE_FD_PATH/$_SIDECAR_TXN_REL" ) || exit 1
      chmod 0700 "$_SIDECAR_STATE_FD_PATH/$_SIDECAR_TXN_REL" || exit 1
      _SIDECAR_CIDFILE_REL="$_SIDECAR_TXN_REL/cid"
      _SIDECAR_ENV_FILE="$(umask 077; ${pkgs.coreutils}/bin/mktemp "$_SIDECAR_STATE_FD_PATH/$_SIDECAR_TXN_REL/env.XXXXXX")" || exit 1
      printf 'POSTGRES_USER=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=%s\n' "$DB_SIDECAR_USER" "$DB_SIDECAR_PASSWORD" "$DB_SIDECAR_DB" > "$_SIDECAR_ENV_FILE"
      chmod 0600 "$_SIDECAR_ENV_FILE" || exit 1
      _SIDECAR_OLD_UMASK="$(umask)"
      umask 077
      if ! _sidecar_oci_with_state_fd create --name "$DB_SIDECAR_CONTAINER" \
          --cidfile "/proc/self/fd/$_SIDECAR_STATE_FD/$_SIDECAR_CIDFILE_REL" \
          --label 'io.ocsb.owner=ocsb-ironclaw' \
          --label "io.ocsb.persist-id=$_SIDECAR_PERSIST_ID" \
          --label "io.ocsb.image=$DB_SIDECAR_IMAGE" \
          --label "io.ocsb.volume=$_SIDECAR_VOLUME" \
          --label "io.ocsb.port=$DB_SIDECAR_PORT" \
          --label "io.ocsb.data-id=$_SIDECAR_DATA_ID" \
          --label 'io.ocsb.protocol=sidecar-gate-v1' \
          --label "io.ocsb.generation=$_SIDECAR_GENERATION" \
          --env-file "$_SIDECAR_ENV_FILE" \
          --volume "$_SIDECAR_VOLUME:/var/lib/postgresql" \
          --publish "127.0.0.1:$DB_SIDECAR_PORT:5432" \
          --entrypoint /ocsb-sidecar-gate/ocsb-sidecar-gate \
          "$DB_SIDECAR_IMAGE" run --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION" \
          "''${TEST_AFTER_COMMIT_DECISION_READY_FD:+--test-after-commit-decision-before-ack-ready-fd}" \
          "''${TEST_AFTER_COMMIT_DECISION_READY_FD:+$TEST_AFTER_COMMIT_DECISION_READY_FD}" \
          "''${TEST_AFTER_COMMIT_DECISION_RELEASE_FD:+--test-after-commit-decision-before-ack-release-fd}" \
          "''${TEST_AFTER_COMMIT_DECISION_RELEASE_FD:+$TEST_AFTER_COMMIT_DECISION_RELEASE_FD}" >/dev/null; then
        umask "$_SIDECAR_OLD_UMASK"
        exit 1
      fi
      umask "$_SIDECAR_OLD_UMASK"
      ${pkgs.coreutils}/bin/rm -f -- "$_SIDECAR_ENV_FILE"
      _SIDECAR_ENV_FILE=""
      _sidecar_wait_fixture_barrier "$TEST_AFTER_CREATE_CIDFILE_READY_FD" "$TEST_AFTER_CREATE_CIDFILE_RELEASE_FD" after-create-cidfile || exit 1
      _sidecar_recover_created_id || {
        echo "ocsb-$VARIANT: cannot validate sidecar cidfile receipt" >&2
        exit 1
      }
      _SIDECAR_GATE_CONFIG_PATH="$_SIDECAR_STATE_FD_PATH/$_SIDECAR_TXN_REL/config"
      ( umask 077; : > "$_SIDECAR_GATE_CONFIG_PATH" ) || exit 1
      chmod 0600 "$_SIDECAR_GATE_CONFIG_PATH" || exit 1
      exec {_SIDECAR_GATE_CONFIG_FD}<>"$_SIDECAR_GATE_CONFIG_PATH"
      _sidecar_oci_capture inspect --format '{{json .Config.Env}}' "$_SIDECAR_CONTAINER_ID" || exit 1
      (
        _sidecar_close_child_fds 0 1 0 0
        exec "$SIDECAR_GATE_BIN" encode --config-fd "$_SIDECAR_GATE_CONFIG_FD" --generation "$_SIDECAR_GENERATION" \
          --expected-dev "$_SIDECAR_DATA_DEV" --expected-ino "$_SIDECAR_DATA_INO" \
          --entrypoint-json "$_SIDECAR_IMAGE_ENTRYPOINT" --cmd-json "$_SIDECAR_IMAGE_CMD" \
          --environment-json "$_SIDECAR_RUNTIME_OUTPUT"
      ) || exit 1
      _sidecar_oci_copy_gate_archive || exit 1
    fi

    if [[ "$_SIDECAR_ORIGIN" == running ]]; then
      if _sidecar_gate_query_running; then
        case "$_SIDECAR_GATE_DECISION" in
          commit)
            _sidecar_gate_wait_ack commit || exit 1
            _SIDECAR_GATE_RELEASED=1
            ;;
          abort)
            _sidecar_gate_wait_ack abort || exit 1
            echo "ocsb-$VARIANT: running sidecar gate previously aborted" >&2
            exit 1
            ;;
          absent) _sidecar_gate_verify_and_prepare || exit 1 ;;
        esac
      else
        _sidecar_gate_verify_and_prepare || exit 1
      fi
    else
      _SIDECAR_START_ATTEMPTED=1
      _sidecar_oci_start_gate start "$_SIDECAR_CONTAINER_ID" >/dev/null || exit 1
      _SIDECAR_STARTED_BY_TRANSACTION=1
      _sidecar_gate_verify_and_prepare || exit 1
    fi
    if [[ "$_SIDECAR_GATE_RELEASED" -eq 0 ]]; then
      _sidecar_wait_fixture_barrier "$TEST_AFTER_PREPARE_READY_FD" "$TEST_AFTER_PREPARE_RELEASE_FD" after-prepare-before-decision || exit 1
      _SIDECAR_COMMIT_ATTEMPTED=1
      _sidecar_oci_capture exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate \
        decision --commit --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION" || exit 1
      _sidecar_parse_decision || exit 1
      if [[ "$_SIDECAR_GATE_DECISION" != commit ]]; then
        if [[ "$_SIDECAR_GATE_DECISION" == abort ]]; then
          _sidecar_gate_wait_ack abort || exit 1
        fi
        echo "ocsb-$VARIANT: sidecar gate did not grant commit" >&2
        exit 1
      fi
      _sidecar_gate_wait_ack commit || exit 1
      _SIDECAR_GATE_RELEASED=1
    fi
    _sidecar_remove_transaction_receipts
    _SIDECAR_PREPARED=1

    _SIDE_READY=0
    for ((_i=0; _i<60; _i++)); do
      if _sidecar_oci exec "$_SIDECAR_CONTAINER_ID" pg_isready -U "$DB_SIDECAR_USER" -d "$DB_SIDECAR_DB" >/dev/null 2>&1; then
        _SIDE_READY=1
        break
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    [[ "$_SIDE_READY" -eq 1 ]] || {
      echo "ocsb-$VARIANT: sidecar postgres readiness timeout for '$DB_SIDECAR_CONTAINER'" >&2
      exit 1
    }
    _DB_EXISTS=""
    if _sidecar_oci_capture exec "$_SIDECAR_CONTAINER_ID" psql -U "$DB_SIDECAR_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_SIDECAR_DB'" 2>/dev/null; then
      _DB_EXISTS="''${_SIDECAR_RUNTIME_OUTPUT//[[:space:]]/}"
    fi
    [[ "$_DB_EXISTS" == 1 ]] || _sidecar_oci exec "$_SIDECAR_CONTAINER_ID" createdb -U "$DB_SIDECAR_USER" "$DB_SIDECAR_DB" >/dev/null
    _sidecar_oci exec "$_SIDECAR_CONTAINER_ID" psql -U "$DB_SIDECAR_USER" -d "$DB_SIDECAR_DB" -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS vector;' >/dev/null
    export PGHOST="127.0.0.1"
    export PGPORT="$DB_SIDECAR_PORT"
    export PGUSER="$DB_SIDECAR_USER"
    export PGDATABASE="$DB_SIDECAR_DB"
    export PGPASSWORD="$DB_SIDECAR_PASSWORD"
    export DATABASE_URL="postgres://$DB_SIDECAR_USER:$DB_SIDECAR_PASSWORD@127.0.0.1:$DB_SIDECAR_PORT/$DB_SIDECAR_DB?sslmode=disable"
    export DATABASE_BACKEND="''${DATABASE_BACKEND:-postgres}"
    export DATABASE_SSLMODE="''${DATABASE_SSLMODE:-disable}"
  fi

  _validate_private_sidecar_dir() {
    local _path="$1" _label="$2" _owner _mode
    [[ ! -L "$_path" && -d "$_path" ]] || {
      echo "ocsb-$VARIANT: unsafe sidecar $_label" >&2
      return 1
    }
    read -r _owner _mode < <(${pkgs.coreutils}/bin/stat -Lc '%u %a' -- "$_path") || return 1
    [[ "$_owner" == "$(id -u)" && "$_mode" == 700 ]] || {
      echo "ocsb-$VARIANT: unsafe sidecar $_label" >&2
      return 1
    }
  }
  if [[ "$DB_MODE" == "sidecar" ]]; then
    [[ ! -L "$PERSIST_DIR" && ! -L "$PERSIST_DIR/state" && ! -L "$PERSIST_DIR/pgdata-sidecar" ]] || {
      echo "ocsb-$VARIANT: unsafe sidecar persist/state/data directory" >&2
      exit 1
    }
    chmod 0700 "$PERSIST_DIR" "$PERSIST_DIR/state" "$PERSIST_DIR/pgdata-sidecar" || exit 1
    _validate_private_sidecar_dir "$PERSIST_DIR" "persist directory" || exit 1
    _validate_private_sidecar_dir "$PERSIST_DIR/state" "state directory" || exit 1
    _validate_private_sidecar_dir "$PERSIST_DIR/pgdata-sidecar" "data directory" || exit 1
  fi

  export OCSB_IRONCLAW_DB_MODE="$DB_MODE"
  append_forward_env_name OCSB_IRONCLAW_DB_MODE

  if [[ "$DB_MODE" == "external" ]]; then
    if [[ -z "''${DATABASE_URL:-}" ]]; then
      echo "ocsb-$VARIANT: db mode 'external' requires DATABASE_URL in the host environment" >&2
      exit 1
    fi
    export DATABASE_BACKEND="''${DATABASE_BACKEND:-postgres}"
  fi

  if [[ "$DB_MODE" == "external" || "$DB_MODE" == "sidecar" ]]; then
    DB_ENV_HOST_FILE="$PERSIST_DIR/state/ironclaw-db.env"
    if [[ "$DB_MODE" == "sidecar" ]]; then
      DB_ENV_HOST_FILE="$_SIDECAR_STATE_FD_PATH/ironclaw-db.env"
      _SIDECAR_DB_ENV_PUBLIC_FILE="$PERSIST_DIR/state/ironclaw-db.env"
    fi
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

    if [[ "$DB_MODE" == "sidecar" ]]; then
      _sidecar_write_db_env_file || exit 1
      _sidecar_open_handoff_fds || exit 1
      _sidecar_terminate_runtime TERM
      _sidecar_terminate_capture
      _sidecar_terminate_password TERM
      _sidecar_close_transaction_fds
      trap - EXIT INT TERM HUP
      DB_ENV_HOST_FILE="$_SIDECAR_DB_ENV_PUBLIC_FILE"
    else
      write_db_env_file "$DB_ENV_HOST_FILE"
    fi

    # Avoid inheriting DB secrets in the host-side launcher/bwrap env.
    unset DATABASE_URL DATABASE_BACKEND DATABASE_SSLMODE DATABASE_POOL_SIZE
    unset PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
  fi
  export OCSB_FORWARD_ENV

  if [[ "$DB_MODE" == "sidecar" ]]; then
    cd "/proc/self/fd/$HANDOFF_HOME_FD"
  else
    cd "$PERSIST_DIR/home"
  fi

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
    "''${HANDOFF_FD_ARGS[@]}" \
    "''${IRONCLAW_MOUNT_ARGS[@]}" \
    "''${FILTERED_ARGS[@]}"
''
