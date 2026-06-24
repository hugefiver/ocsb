{ pkgs, mkHermesAgentSandboxBase }:

pkgs.writeShellScriptBin "ocsb-hermes" ''
  set -euo pipefail

  API_KEYS_ENV_FILE_SANDBOX="/tmp/ocsb-hermes-agent-api-keys.env"
  PERSIST_DIR=""
  API_KEYS_ENV_FILE_HOST=""
  API_KEYS_ENV_NAMES=()
  FILTERED_ARGS=()
  HAS_CONTINUE_OR_OVERWRITE=0
  SHELL_MODE=0
  NO_GATEWAY=0
  GATEWAY_MODE=0
  REPLACE_MODE=0

  usage() {
    cat <<USAGE_EOF
  Usage: ocsb-hermes [OPTIONS] [-- COMMAND...]

  Run Hermes Agent inside an isolated ocsb sandbox with persistent home/state.
  By default starts the messaging gateway as a background service alongside the
  interactive Hermes CLI.

  Options:
    --persist-dir DIR              Override persistent state directory.
                                  Default: \$HOME/.cache/ocsb/hermes-agent.
    --api-keys-env-file FILE       Use caller-provided API key env file.
                                  Mounted read-only at $API_KEYS_ENV_FILE_SANDBOX.
    -w, --workspace NAME           Workspace name (passed through to ocsb).
    --continue                     Reuse existing workspace state.
    --overwrite                    Reset workspace state before launch.
    --attach                       Attach to currently-running sandbox instance.
                                  Use --attach=PID to target a specific bwrap.
    -s, --shell                    Drop into bash inside sandbox instead of
                                  starting hermes.
    -g, --gateway                  Run gateway as the sole foreground process
                                  (no interactive CLI). Useful for systemd services.
    --replace                      Kill the currently-running ocsb-hermes sandbox,
                                  then restart as --gateway. Requires --gateway.
    --no-gateway                   Skip the background gateway service.
                                  Only the interactive Hermes CLI is started.
    --env NAME[=VALUE]             Forward non-secret env to inner ocsb.
                                  Secret/provider env names are captured into
                                  \$PERSIST_DIR/state/hermes-agent-api-keys.env
                                  (0600) and sourced from mounted private file.
    -h, --help                     Show this help and exit.
    --                             Pass remaining args to hermes / shell.

  Environment:
    OCSB_HERMES_AGENT_PERSIST_DIR  Same as --persist-dir.
  USAGE_EOF
  }

  trim_ascii_whitespace() {
    local _v="$1"
    _v="''${_v#"''${_v%%[![:space:]]*}"}"
    _v="''${_v%"''${_v##*[![:space:]]}"}"
    printf '%s' "$_v"
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

  is_reserved_hermes_env_name() {
    case "$1" in
      OCSB_HERMES_AGENT_PERSIST_DIR|OCSB_HERMES_AGENT_API_KEYS_ENV_FILE|OCSB_HERMES_NO_GATEWAY|HERMES_HOME|TERMINAL_CWD)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  append_api_key_env_name() {
    local _name="$1"
    local _existing
    [[ -n "$_name" ]] || return 0
    for _existing in "''${API_KEYS_ENV_NAMES[@]}"; do
      if [[ "$_existing" == "$_name" ]]; then
        return 0
      fi
    done
    API_KEYS_ENV_NAMES+=("$_name")
  }

  is_default_hermes_api_key_env_name() {
    case "$1" in
      OPENROUTER_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|HF_TOKEN|HUGGINGFACE_API_KEY|HUGGINGFACEHUB_API_TOKEN|GOOGLE_API_KEY|GEMINI_API_KEY|GOOGLE_GENERATIVE_AI_API_KEY|GROQ_API_KEY|MISTRAL_API_KEY|COHERE_API_KEY|TOGETHER_API_KEY|DEEPSEEK_API_KEY|XAI_API_KEY|PERPLEXITY_API_KEY|FIREWORKS_API_KEY|AZURE_OPENAI_API_KEY|VOYAGE_API_KEY|BWS_ACCESS_TOKEN|ANTHROPIC_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|NOVITA_API_KEY|GLM_API_KEY|ZAI_API_KEY|Z_AI_API_KEY|KIMI_API_KEY|KIMI_CN_API_KEY|KIMI_CODING_API_KEY|STEPFUN_API_KEY|ARCEEAI_API_KEY|GMI_API_KEY|MINIMAX_API_KEY|MINIMAX_CN_API_KEY|DASHSCOPE_API_KEY|ALIBABA_CODING_PLAN_API_KEY|NVIDIA_API_KEY|OPENCODE_ZEN_API_KEY|OPENCODE_GO_API_KEY|KILOCODE_API_KEY|XIAOMI_API_KEY|TOKENHUB_API_KEY|OLLAMA_API_KEY|AZURE_FOUNDRY_API_KEY|LM_API_KEY|COPILOT_GITHUB_TOKEN|GH_TOKEN|GITHUB_TOKEN|NOUS_API_KEY|QWEN_API_KEY)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  is_hermes_secret_like_env_name() {
    case "$1" in
      OPENROUTER_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|HF_TOKEN|HUGGINGFACE_API_KEY|GITHUB_TOKEN|GITLAB_TOKEN|SLACK_BOT_TOKEN|SLACK_TOKEN|DISCORD_TOKEN|TELEGRAM_BOT_TOKEN|TWILIO_AUTH_TOKEN|*_API_KEY|*_AUTH_TOKEN|*_ACCESS_TOKEN|*_TOKEN)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  sanitize_forward_env_names() {
    local _raw="''${OCSB_FORWARD_ENV:-}"
    [[ -n "$_raw" ]] || return 0

    local _entry _name
    local _new_entries=()
    IFS=',' read -r -a _entries <<< "$_raw"
    for _entry in "''${_entries[@]}"; do
      _name="$(trim_ascii_whitespace "$_entry")"
      [[ -n "$_name" ]] || continue
      if [[ ! "$_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        continue
      fi
      if is_reserved_hermes_env_name "$_name" || is_hermes_secret_like_env_name "$_name"; then
        continue
      fi
      _new_entries+=("$_name")
    done

    if [[ ''${#_new_entries[@]} -eq 0 ]]; then
      unset OCSB_FORWARD_ENV
    else
      OCSB_FORWARD_ENV="$(IFS=,; printf '%s' "''${_new_entries[*]}")"
    fi
  }

  collect_default_api_key_env_names() {
    local _api_env_name
    while IFS= read -r _api_env_name; do
      if is_default_hermes_api_key_env_name "$_api_env_name" && [[ -n "''${!_api_env_name+x}" ]]; then
        append_api_key_env_name "$_api_env_name"
      fi
    done < <(${pkgs.coreutils}/bin/env | ${pkgs.coreutils}/bin/cut -d= -f1 | ${pkgs.coreutils}/bin/sort -u)
  }

  write_api_keys_env_file() {
    local _api_env_file="$1"
    local _api_env_dir _api_env_base _api_env_tmp
    local _api_env_name

    _api_env_dir="$(${pkgs.coreutils}/bin/dirname "$_api_env_file")"
    _api_env_base="$(${pkgs.coreutils}/bin/basename "$_api_env_file")"
    _api_env_tmp="$(${pkgs.coreutils}/bin/mktemp "$_api_env_dir/.$_api_env_base.XXXXXX")"
    trap '[[ -n "''${_api_env_tmp:-}" ]] && ${pkgs.coreutils}/bin/rm -f "$_api_env_tmp"' RETURN

    (
      umask 077
      for _api_env_name in "''${API_KEYS_ENV_NAMES[@]}"; do
        if [[ -n "''${!_api_env_name+x}" ]]; then
          printf 'export %s=%q\n' "$_api_env_name" "''${!_api_env_name}"
        fi
      done
    ) > "$_api_env_tmp"

    chmod 0600 "$_api_env_tmp" 2>/dev/null || true
    ${pkgs.coreutils}/bin/mv -f "$_api_env_tmp" "$_api_env_file"
    _api_env_tmp=""
    trap - RETURN
  }

  unset_secret_env_names() {
    local _name
    while IFS= read -r _name; do
      if is_hermes_secret_like_env_name "$_name"; then
        unset "$_name" 2>/dev/null || true
        remove_forward_env_name "$_name"
      fi
    done < <(${pkgs.coreutils}/bin/env | ${pkgs.coreutils}/bin/cut -d= -f1 | ${pkgs.coreutils}/bin/sort -u)
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -w|--workspace)
        [[ $# -ge 2 ]] || { echo "ocsb-hermes: $1 requires a value" >&2; exit 1; }
        FILTERED_ARGS+=("$1" "$2")
        shift 2
        ;;
      -s|--shell)
        SHELL_MODE=1
        shift
        ;;
      -g|--gateway)
        GATEWAY_MODE=1
        shift
        ;;
      --replace)
        REPLACE_MODE=1
        shift
        ;;
      --no-gateway)
        NO_GATEWAY=1
        shift
        ;;
      --continue|--overwrite)
        HAS_CONTINUE_OR_OVERWRITE=1
        FILTERED_ARGS+=("$1")
        shift
        ;;
      --persist-dir)
        [[ $# -ge 2 ]] || { echo "ocsb-hermes: $1 requires a value" >&2; exit 1; }
        PERSIST_DIR="$2"
        shift 2
        ;;
      --api-keys-env-file)
        [[ $# -ge 2 ]] || { echo "ocsb-hermes: $1 requires a value" >&2; exit 1; }
        API_KEYS_ENV_FILE_HOST="$2"
        shift 2
        ;;
      --env)
        [[ $# -ge 2 ]] || { echo "ocsb-hermes: $1 requires NAME or NAME=VALUE" >&2; exit 1; }
        _ENV_SPEC="$2"
        if [[ "$_ENV_SPEC" == *=* ]]; then
          _ENV_NAME="''${_ENV_SPEC%%=*}"
          _ENV_VALUE="''${_ENV_SPEC#*=}"
        else
          _ENV_NAME="$_ENV_SPEC"
          if [[ ! "$_ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "ocsb-hermes: invalid --env name: $_ENV_NAME" >&2
            exit 1
          fi
          if [[ -z "''${!_ENV_NAME+x}" ]]; then
            echo "ocsb-hermes: --env $_ENV_NAME requested but host environment variable is unset" >&2
            exit 1
          fi
          _ENV_VALUE="''${!_ENV_NAME}"
        fi
        if [[ ! "$_ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          echo "ocsb-hermes: invalid --env name: $_ENV_NAME" >&2
          exit 1
        fi
        if is_reserved_hermes_env_name "$_ENV_NAME"; then
          echo "ocsb-hermes: --env $_ENV_NAME is reserved for the Hermes Agent wrapper" >&2
          exit 1
        fi

        export "$_ENV_NAME=$_ENV_VALUE"
        if ! is_hermes_secret_like_env_name "$_ENV_NAME"; then
          FILTERED_ARGS+=("$1" "$2")
        else
          append_api_key_env_name "$_ENV_NAME"
          remove_forward_env_name "$_ENV_NAME"
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
    if [[ -n "''${OCSB_HERMES_AGENT_PERSIST_DIR:-}" ]]; then
      PERSIST_DIR="$OCSB_HERMES_AGENT_PERSIST_DIR"
    else
      PERSIST_DIR="$HOME/.cache/ocsb/hermes-agent"
    fi
  fi

  # --- gateway / replace logic ---
  if [[ "$GATEWAY_MODE" -eq 1 ]]; then
    NO_GATEWAY=1  # template side: don't start background gateway
    if [[ "$SHELL_MODE" -eq 0 ]]; then
      # Foreground gateway as sole process (systemd-friendly).
      export OCSB_EXEC_OVERRIDE=1
      FILTERED_ARGS+=(-- hermes gateway run --replace)
    fi
  fi

  if [[ "$REPLACE_MODE" -eq 1 ]]; then
    if [[ "$GATEWAY_MODE" -ne 1 ]]; then
      echo "ocsb-hermes: --replace requires --gateway" >&2
      exit 1
    fi
    # Kill the running sandbox via pidfile, then restart with --continue.
    _PIDFILE="''${XDG_RUNTIME_DIR:-/tmp}/ocsb/hermes-agent.pid"
    if [[ -f "$_PIDFILE" ]]; then
      _OLD_PID="$(${pkgs.coreutils}/bin/cat "$_PIDFILE")"
      _OLD_PID="''${_OLD_PID%% *}"
      if [[ -n "$_OLD_PID" ]] && kill -0 "$_OLD_PID" 2>/dev/null; then
        echo "ocsb-hermes: --replace: killing sandbox pid=$_OLD_PID" >&2
        kill "$_OLD_PID"
        for ((_i=0; _i<50; _i++)); do
          kill -0 "$_OLD_PID" 2>/dev/null || break
          ${pkgs.coreutils}/bin/sleep 0.1
        done
      fi
    fi
    FILTERED_ARGS=(--continue "''${FILTERED_ARGS[@]}")
    HAS_CONTINUE_OR_OVERWRITE=1
  fi

  # Default to --continue: Hermes runtime state is in $PERSIST_DIR,
  # workspace marker is only for strategy bookkeeping.
  if [[ "$HAS_CONTINUE_OR_OVERWRITE" -eq 0 ]]; then
    FILTERED_ARGS=(--continue "''${FILTERED_ARGS[@]}")
  fi

  PERSIST_DIR="$(${pkgs.coreutils}/bin/realpath -m "$PERSIST_DIR")"

  ${pkgs.coreutils}/bin/mkdir -p \
    "$PERSIST_DIR/home" \
    "$PERSIST_DIR/state"

  if [[ -n "$API_KEYS_ENV_FILE_HOST" ]]; then
    if [[ ! -r "$API_KEYS_ENV_FILE_HOST" ]]; then
      echo "ocsb-hermes: --api-keys-env-file must be readable: $API_KEYS_ENV_FILE_HOST" >&2
      exit 1
    fi
    API_KEYS_ENV_FILE_HOST="$(${pkgs.coreutils}/bin/realpath -m "$API_KEYS_ENV_FILE_HOST")"
    if [[ ! -r "$API_KEYS_ENV_FILE_HOST" ]]; then
      echo "ocsb-hermes: --api-keys-env-file must resolve to a readable file: $API_KEYS_ENV_FILE_HOST" >&2
      exit 1
    fi
  else
    API_KEYS_ENV_FILE_HOST="$PERSIST_DIR/state/hermes-agent-api-keys.env"
    collect_default_api_key_env_names
    write_api_keys_env_file "$API_KEYS_ENV_FILE_HOST"
  fi

  sanitize_forward_env_names
  unset_secret_env_names

  export OCSB_HERMES_AGENT_API_KEYS_ENV_FILE="$API_KEYS_ENV_FILE_SANDBOX"
  append_forward_env_name OCSB_HERMES_AGENT_API_KEYS_ENV_FILE
  export OCSB_FORWARD_ENV

  cd "$PERSIST_DIR/home"

  if [[ "$SHELL_MODE" -eq 1 ]]; then
    export OCSB_EXEC_OVERRIDE=1
    FILTERED_ARGS+=(-- ${pkgs.bashInteractive}/bin/bash -i)
  fi

  # Keep workspace/chroot state under stable persist dir instead of
  # ~/.cache/ocsb/<project-hash>/hermes-agent.
  export OCSB_STATE_BASE_DIR="$PERSIST_DIR/state"
  export OCSB_HERMES_NO_GATEWAY="$NO_GATEWAY"
  append_forward_env_name OCSB_HERMES_NO_GATEWAY

  exec ${mkHermesAgentSandboxBase}/bin/hermes-agent \
    --ro "$API_KEYS_ENV_FILE_HOST:$API_KEYS_ENV_FILE_SANDBOX" \
    "''${FILTERED_ARGS[@]}"
''
