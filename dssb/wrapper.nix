{ pkgs, dssbSandboxBase }:

pkgs.writeShellScriptBin "dssb" ''
  set -euo pipefail

  PERSIST_DIR=""
  WORKSPACE_NAME="dssb"
  HAS_WORKSPACE_ACTION=0
  SHELL_MODE=0
  OCSB_ARGS=()
  DSH_ARGS=()

  usage() {
    cat <<USAGE_EOF
Usage: dssb [OCSB OPTIONS] [--] [DSH ARGS...]

OCSB options:
  --persist-dir DIR
  -w, --workspace NAME
  --strategy STRATEGY
  --backend bubblewrap|podman|systemd-nspawn
  --continue | --overwrite
  --attach | --attach=PID
  --env NAME[=VALUE]
  --ro HOST:SANDBOX | --rw HOST:SANDBOX
  -s, --shell
  -h, --help

The first unknown argument, or every argument after --, is passed to dsh.
Default persistence: $HOME/.cache/ocsb/dssb
USAGE_EOF
  }

  ensure_private_dir() {
    local path="$1"

    if [[ -e "$path" || -L "$path" ]]; then
      if [[ ! -d "$path" || -L "$path" ]]; then
        echo "dssb: unsafe persistent path is not a real directory: $path" >&2
        return 1
      fi
      if [[ "$(${pkgs.coreutils}/bin/stat -c %u -- "$path")" != "$(${pkgs.coreutils}/bin/id -u)" ||
            "$(${pkgs.coreutils}/bin/stat -c %a -- "$path")" != 700 ]]; then
        echo "dssb: unsafe persistent directory must be current-UID mode 0700: $path" >&2
        return 1
      fi
      return 0
    fi

    ${pkgs.coreutils}/bin/install -d -m 0700 -- "$path"
  }

  validate_workspace_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
      echo "dssb: workspace name cannot be empty" >&2
      return 1
    fi
    if [[ "$name" == -* ]]; then
      echo "dssb: workspace name cannot start with '-'" >&2
      return 1
    fi
    if [[ "$name" == */* ]]; then
      echo "dssb: workspace name cannot contain '/'" >&2
      return 1
    fi
    if [[ "$name" == "." || "$name" == ".." ]]; then
      echo "dssb: workspace name cannot be '.' or '..'" >&2
      return 1
    fi
    if [[ "''${#name}" -gt 255 ]]; then
      echo "dssb: workspace name too long (max 255 chars)" >&2
      return 1
    fi
    if [[ "$name" == *".."* ]]; then
      echo "dssb: workspace name cannot contain '..'" >&2
      return 1
    fi
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --persist-dir)
        [[ $# -ge 2 ]] || { echo "dssb: --persist-dir requires a value" >&2; exit 2; }
        PERSIST_DIR="$2"
        shift 2
        ;;
      -w|--workspace)
        [[ $# -ge 2 ]] || { echo "dssb: $1 requires a value" >&2; exit 2; }
        WORKSPACE_NAME="$2"
        OCSB_ARGS+=("$1" "$2")
        shift 2
        ;;
      --strategy|--backend|--env|--ro|--rw)
        [[ $# -ge 2 ]] || { echo "dssb: $1 requires a value" >&2; exit 2; }
        OCSB_ARGS+=("$1" "$2")
        shift 2
        ;;
      --continue|--overwrite)
        HAS_WORKSPACE_ACTION=1
        OCSB_ARGS+=("$1")
        shift
        ;;
      --attach|--attach=*)
        OCSB_ARGS+=("$1")
        shift
        ;;
      -s|--shell)
        SHELL_MODE=1
        shift
        ;;
      --)
        shift
        DSH_ARGS=("$@")
        break
        ;;
      *)
        DSH_ARGS=("$@")
        break
        ;;
    esac
  done

  if [[ -z "$PERSIST_DIR" ]]; then
    if [[ -n "''${OCSB_DSSB_PERSIST_DIR:-}" ]]; then
      PERSIST_DIR="$OCSB_DSSB_PERSIST_DIR"
    else
      PERSIST_DIR="$HOME/.cache/ocsb/dssb"
    fi
  fi

  RAW_PERSIST_DIR="$PERSIST_DIR"
  if [[ "$RAW_PERSIST_DIR" != /* ]]; then
    echo "dssb: persist directory must be absolute: $RAW_PERSIST_DIR" >&2
    exit 1
  fi

  if [[ -e "$RAW_PERSIST_DIR" || -L "$RAW_PERSIST_DIR" ]]; then
    ensure_private_dir "$RAW_PERSIST_DIR" || exit 1
  fi

  validate_workspace_name "$WORKSPACE_NAME" || exit 1

  PERSIST_DIR="$(${pkgs.coreutils}/bin/realpath -m -- "$RAW_PERSIST_DIR")"
  ensure_private_dir "$PERSIST_DIR" || exit 1
  ensure_private_dir "$PERSIST_DIR/home" || exit 1
  ensure_private_dir "$PERSIST_DIR/state" || exit 1

  if [[ "$HAS_WORKSPACE_ACTION" -eq 0 && -d "$PERSIST_DIR/state/$WORKSPACE_NAME" && ! -L "$PERSIST_DIR/state/$WORKSPACE_NAME" ]]; then
    OCSB_ARGS+=(--continue)
  fi

  export OCSB_STATE_BASE_DIR="$PERSIST_DIR/state"

  if [[ "$SHELL_MODE" -eq 1 ]]; then
    if [[ "''${#DSH_ARGS[@]}" -ne 0 ]]; then
      echo "dssb: --shell cannot be combined with DSH arguments" >&2
      exit 2
    fi
    export OCSB_EXEC_OVERRIDE=1
    exec ${dssbSandboxBase}/bin/dssb \
      --rw "$PERSIST_DIR/home:/home/sandbox" \
      "''${OCSB_ARGS[@]}" \
      -- ${pkgs.bashInteractive}/bin/bash -i
  fi

  exec ${dssbSandboxBase}/bin/dssb \
    --rw "$PERSIST_DIR/home:/home/sandbox" \
    "''${OCSB_ARGS[@]}" \
    -- "''${DSH_ARGS[@]}"
''
