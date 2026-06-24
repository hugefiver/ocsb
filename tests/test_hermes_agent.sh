#!/usr/bin/env bash
set -euo pipefail

SOURCE_ONLY=0
if [[ "${1:-}" == "--source-only" ]]; then
  SOURCE_ONLY=1
  shift
fi

WRAPPER="${1:-}"
if [[ "$SOURCE_ONLY" != "1" && -z "$WRAPPER" ]]; then
  echo "Usage: $0 [--source-only] <path-to-ocsb-hermes-binary>" >&2
  exit 2
fi

if [[ "$SOURCE_ONLY" == "1" ]]; then
  TMPDIR=""
  PERSIST_MAIN=""
  PERSIST_EXTERNAL=""
else
  TMPDIR="$(mktemp -d)"
  PERSIST_MAIN="$TMPDIR/persist-main"
  PERSIST_EXTERNAL="$TMPDIR/persist-external"
fi

PASS=0
FAIL=0

cleanup() {
  if [[ -z "${TMPDIR:-}" ]]; then
    return 0
  fi
  find "$TMPDIR" -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1"
  local haystack="$2"
  local needle="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc" >&2
    echo "  missing: $needle" >&2
    FAIL=$((FAIL + 1))
  fi
}

echo "=== hermes-agent sandbox test suite ==="

echo "--- source wiring ---"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE_TEXT="$(cat "$REPO_ROOT/flake.nix")"
HERMES_WRAPPER_TEXT="$(cat "$REPO_ROOT/scripts/hermes-wrapper.nix")"
HERMES_TEMPLATE_TEXT="$(cat "$REPO_ROOT/templates/hermes-agent.nix")"
HERMES_NIX_CONFIG_TEMPLATE_TEXT="$(cat "$REPO_ROOT/templates/hermes-agent-nix-config.nix")"
assert_contains "source: hermes input points at Hermes Agent 0.17.0 tag" "$FLAKE_TEXT" 'github:NousResearch/hermes-agent/v2026.6.19'
assert_contains "source: helper package defines service binary" "$FLAKE_TEXT" 'writeShellScriptBin "service"'
assert_contains "source: service command documents gateway actions" "$FLAKE_TEXT" 'service gateway start|stop|restart|status'
assert_contains "source: restart uses upstream replace" "$FLAKE_TEXT" 'hermes gateway run --replace'
assert_contains "source: helper stores gateway state under HERMES_HOME" "$FLAKE_TEXT" '"$HERMES_HOME/service/gateway"'
assert_contains "source: helper defines runtime pid dir" "$FLAKE_TEXT" 'runtime_dir='
assert_contains "source: helper keeps pid state outside HERMES_HOME" "$FLAKE_TEXT" 'ocsb/hermes-gateway'
assert_contains "source: helper persists stopped marker" "$FLAKE_TEXT" 'stopped_file="$state_dir/stopped"'
assert_contains "source: helper tracks supervisor pid" "$FLAKE_TEXT" 'supervisor_pid_file="$runtime_dir/supervisor.pid"'
assert_contains "source: restart ensures supervisor exists" "$FLAKE_TEXT" 'ensure_supervisor'
assert_contains "source: status reports enabled state" "$FLAKE_TEXT" 'enabled_state='
assert_contains "template: daemon uses service gateway supervise" "$HERMES_TEMPLATE_TEXT" 'service gateway supervise'
assert_contains "template nix-config: daemon uses service gateway supervise" "$HERMES_NIX_CONFIG_TEMPLATE_TEXT" 'service gateway supervise'
assert_contains "template: installs Hermes service helper" "$HERMES_TEMPLATE_TEXT" 'hermesServicePackage'
assert_contains "template nix-config: installs Hermes service helper" "$HERMES_NIX_CONFIG_TEMPLATE_TEXT" 'hermesServicePackage'
for _env_name in ALIBABA_CODING_PLAN_API_KEY GH_TOKEN GITHUB_TOKEN ZAI_API_KEY Z_AI_API_KEY NOUS_API_KEY QWEN_API_KEY; do
  assert_contains "source: wrapper captures default Hermes API key env $_env_name" "$HERMES_WRAPPER_TEXT" "$_env_name"
done

if [[ "$SOURCE_ONLY" == "1" ]]; then
  echo ""
  echo "=== hermes-agent source-only Results: $PASS passed, $FAIL failed ==="
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "SKIP: GitHub Actions runners restrict bwrap netns (RTM_NEWADDR)"
  exit 0
fi

echo "--- wrapper help text ---"
HELP_TEXT="$($WRAPPER --help)"
WRAPPER_SCRIPT="$(readlink -f "$WRAPPER")"
WRAPPER_TEXT="$(cat "$WRAPPER_SCRIPT")"
assert_contains "help: persist default documented" "$HELP_TEXT" 'Default: $HOME/.cache/ocsb/hermes-agent.'
assert_contains "help: api key env file path documented" "$HELP_TEXT" '/tmp/ocsb-hermes-agent-api-keys.env'
assert_contains "wrapper: launches from persisted home" "$WRAPPER_TEXT" 'cd "$PERSIST_DIR/home"'
assert_contains "wrapper: stable state base export" "$WRAPPER_TEXT" 'export OCSB_STATE_BASE_DIR="$PERSIST_DIR/state"'
assert_contains "wrapper: reserved env gate present" "$WRAPPER_TEXT" 'is_reserved_hermes_env_name "$_ENV_NAME"'
assert_contains "wrapper: api key env file uses atomic rename" "$WRAPPER_TEXT" 'mv -f "$_api_env_tmp" "$_api_env_file"'

echo "--- wrapper smoke run ---"
"$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_MAIN" -- --version

echo "--- sandbox probes ---"
EXPECTED_STATE_DIR="$PERSIST_MAIN/state/hermes-agent"
PROBE_SCRIPT="$PERSIST_MAIN/home/hermes-probe.sh"
mkdir -p "$PERSIST_MAIN/home"
cat > "$PROBE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

expected_state_dir="${1:?expected state dir}"
if [[ "$(pwd)" != "/home/sandbox" ]]; then
  echo "expected cwd=/home/sandbox, got $(pwd)" >&2
  exit 1
fi

if [[ "${OCSB_STATE_DIR:-}" != "$expected_state_dir" ]]; then
  echo "expected OCSB_STATE_DIR=$expected_state_dir, got ${OCSB_STATE_DIR:-<unset>}" >&2
  exit 1
fi

if [[ "${OCSB_NETWORK:-}" != "host" ]]; then
  echo "expected OCSB_NETWORK=host, got ${OCSB_NETWORK:-<unset>}" >&2
  exit 1
fi

if [[ "${HERMES_HOME:-}" != "/home/sandbox/.hermes" ]]; then
  echo "expected HERMES_HOME=/home/sandbox/.hermes, got ${HERMES_HOME:-<unset>}" >&2
  exit 1
fi

if [[ "${MESSAGING_CWD:-}" != "/home/sandbox" ]]; then
  echo "expected MESSAGING_CWD=/home/sandbox, got ${MESSAGING_CWD:-<unset>}" >&2
  exit 1
fi

if [[ ! -f "/home/sandbox/.hermes/config.yaml" ]]; then
  echo "missing /home/sandbox/.hermes/config.yaml" >&2
  exit 1
fi

if [[ ! -d "/home/sandbox/.hermes/cron" ]]; then
  echo "missing /home/sandbox/.hermes/cron" >&2
  exit 1
fi

if [[ ! -d "/home/sandbox/.hermes/sessions" ]]; then
  echo "missing /home/sandbox/.hermes/sessions" >&2
  exit 1
fi

if [[ ! -d "/home/sandbox/.hermes/logs" ]]; then
  echo "missing /home/sandbox/.hermes/logs" >&2
  exit 1
fi

if [[ ! -d "/home/sandbox/.hermes/memories" ]]; then
  echo "missing /home/sandbox/.hermes/memories" >&2
  exit 1
fi

if [[ ! -d "/home/sandbox/.hermes/plugins" ]]; then
  echo "missing /home/sandbox/.hermes/plugins" >&2
  exit 1
fi
EOF
chmod +x "$PROBE_SCRIPT"
OCSB_EXEC_OVERRIDE=1 "$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_MAIN" -- bash /home/sandbox/hermes-probe.sh "$EXPECTED_STATE_DIR"

assert "wrapper does not create separate workspace dir" test ! -e "$PERSIST_MAIN/workspace"

echo "--- generated API key env file handling ---"
mkdir -p "$PERSIST_MAIN/state"
printf 'stale-line\n' > "$PERSIST_MAIN/state/hermes-agent-api-keys.env"
chmod 0644 "$PERSIST_MAIN/state/hermes-agent-api-keys.env"

GENERATED_SECRET_A="openrouter-secret-$$"
GENERATED_SECRET_B="openai-secret-$$"
GENERATED_NON_SECRET="forward-me-$$"
GENERATED_UNRELATED_TOKEN="unrelated-token-$$"

GENERATED_OUTPUT="$({
  OPENROUTER_API_KEY="$GENERATED_SECRET_A" \
  OPENAI_API_KEY="$GENERATED_SECRET_B" \
  UNRELATED_TOKEN="$GENERATED_UNRELATED_TOKEN" \
  HERMES_NON_SECRET="$GENERATED_NON_SECRET" \
  OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_MAIN" \
    --env OPENROUTER_API_KEY --env OPENAI_API_KEY --env HERMES_NON_SECRET -- \
    bash -lc 'printf "%s\n%s\n%s\n" "${OPENROUTER_API_KEY:-}" "${OPENAI_API_KEY:-}" "${HERMES_NON_SECRET:-}"'
})"

GEN_SECRET_A_LINE="$(printf '%s\n' "$GENERATED_OUTPUT" | sed -n '1p')"
GEN_SECRET_B_LINE="$(printf '%s\n' "$GENERATED_OUTPUT" | sed -n '2p')"
GEN_NON_SECRET_LINE="$(printf '%s\n' "$GENERATED_OUTPUT" | sed -n '3p')"

GENERATED_FILE="$PERSIST_MAIN/state/hermes-agent-api-keys.env"
assert "generated env file exists" test -s "$GENERATED_FILE"
assert "generated env file mode 0600" test "$(stat -c %a "$GENERATED_FILE")" = "600"
assert "generated env file stale content removed" bash -lc '! grep -Fq -- "stale-line" "$1"' _ "$GENERATED_FILE"
assert "generated env temp files cleaned" bash -lc '! compgen -G "$1/state/.hermes-agent-api-keys.env.*" >/dev/null' _ "$PERSIST_MAIN"
assert "generated env file contains OPENROUTER_API_KEY" grep -Fq -- "export OPENROUTER_API_KEY=" "$GENERATED_FILE"
assert "generated env file contains OPENAI_API_KEY" grep -Fq -- "export OPENAI_API_KEY=" "$GENERATED_FILE"
assert "generated env file excludes unrelated host token" bash -lc '! grep -Fq -- "UNRELATED_TOKEN" "$1"' _ "$GENERATED_FILE"
assert "generated env file sourced OPENROUTER_API_KEY" test "$GEN_SECRET_A_LINE" = "$GENERATED_SECRET_A"
assert "generated env file sourced OPENAI_API_KEY" test "$GEN_SECRET_B_LINE" = "$GENERATED_SECRET_B"
assert "non-secret --env still forwards" test "$GEN_NON_SECRET_LINE" = "$GENERATED_NON_SECRET"

echo "--- OCSB_FORWARD_ENV sanitization regression ---"
SANITIZE_PERSIST="$TMPDIR/persist-sanitize"
mkdir -p "$SANITIZE_PERSIST/home"

# OCSB_FORWARD_ENV is a comma-separated list of env NAMES only.
# The wrapper sanitizes the list before passing it to the inner sandbox:
#   OPENROUTER_API_KEY     -> stripped (provider allowlist), delivered via mounted API-key file
#   UNRELATED_TOKEN        -> stripped from forwarding but not auto-persisted
#   HERMES_HOME            -> stripped (reserved wrapper var)
#   OCSB_HERMES_AGENT_API_KEYS_ENV_FILE -> stripped (reserved wrapper var)
#   123invalid             -> stripped (not a valid env name)
#   HERMES_SAFE_FORWARD (both entries) -> forwarded (safe names; inner launcher dedupes)
# The wrapper appends its own OCSB_HERMES_AGENT_API_KEYS_ENV_FILE after sanitization.

SECRET_VAL="secret-forw-$$"
UNRELATED_VAL="unrelated-forw-$$"
SAFE_VAL="outer-$$"
HERMES_SAFE_FWD="$({
  OPENROUTER_API_KEY="$SECRET_VAL" \
  UNRELATED_TOKEN="$UNRELATED_VAL" \
  HERMES_HOME=/tmp/tampered \
  OCSB_HERMES_AGENT_API_KEYS_ENV_FILE=/tmp/tampered \
  HERMES_SAFE_FORWARD="$SAFE_VAL" \
  OCSB_FORWARD_ENV="OPENROUTER_API_KEY,UNRELATED_TOKEN,HERMES_HOME,OCSB_HERMES_AGENT_API_KEYS_ENV_FILE,HERMES_SAFE_FORWARD,HERMES_SAFE_FORWARD,123invalid" \
  OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --overwrite --persist-dir "$SANITIZE_PERSIST" -- \
    bash -lc 'printf "HERMES_SAFE_FORWARD=%s\nHERMES_HOME=%s\nOCSB_HERMES_AGENT_API_KEYS_ENV_FILE=%s\nOPENROUTER_API_KEY=%s\nUNRELATED_TOKEN=%s\n" \
      "${HERMES_SAFE_FORWARD:-}" \
      "${HERMES_HOME:-}" \
      "${OCSB_HERMES_AGENT_API_KEYS_ENV_FILE:-}" \
      "${OPENROUTER_API_KEY:-}" \
      "${UNRELATED_TOKEN:-}"'
})"

# Line 1: HERMES_SAFE_FORWARD (safe, forwarded once from host env)
SAFE_FWD_LINE="$(printf '%s\n' "$HERMES_SAFE_FWD" | sed -n '1p')"
# Line 2: HERMES_HOME (reserved; caller value stripped, wrapper sets /home/sandbox/.hermes)
HERMES_HOME_LINE="$(printf '%s\n' "$HERMES_SAFE_FWD" | sed -n '2p')"
# Line 3: OCSB_HERMES_AGENT_API_KEYS_ENV_FILE (reserved; caller value stripped, wrapper sets /tmp/...)
API_ENV_FILE_LINE="$(printf '%s\n' "$HERMES_SAFE_FWD" | sed -n '3p')"
# Line 4: OPENROUTER_API_KEY (secret; stripped from env, but template sources mounted API-key file)
SECRET_FWD_LINE="$(printf '%s\n' "$HERMES_SAFE_FWD" | sed -n '4p')"
# Line 5: UNRELATED_TOKEN (secret-like; stripped from forwarding and not auto-persisted)
UNRELATED_FWD_LINE="$(printf '%s\n' "$HERMES_SAFE_FWD" | sed -n '5p')"

assert "OCSB_FORWARD_ENV: safe non-secret HERMES_SAFE_FORWARD forwarded" \
  test "$SAFE_FWD_LINE" = "HERMES_SAFE_FORWARD=$SAFE_VAL"
assert "OCSB_FORWARD_ENV: reserved HERMES_HOME retains wrapper value" \
  test "$HERMES_HOME_LINE" = "HERMES_HOME=/home/sandbox/.hermes"
assert "OCSB_FORWARD_ENV: reserved OCSB_HERMES_AGENT_API_KEYS_ENV_FILE retains wrapper value" \
  test "$API_ENV_FILE_LINE" = "OCSB_HERMES_AGENT_API_KEYS_ENV_FILE=/tmp/ocsb-hermes-agent-api-keys.env"
# The secret is stripped from the direct env, but Hermes preExec sources the mounted API-key file
# so the final command environment still contains the secret value.
assert "OCSB_FORWARD_ENV: secret OPENROUTER_API_KEY delivered via mounted API-key file" \
  test "$SECRET_FWD_LINE" = "OPENROUTER_API_KEY=$SECRET_VAL"
assert "OCSB_FORWARD_ENV: unrelated token stripped and not auto-persisted" \
  test "$UNRELATED_FWD_LINE" = "UNRELATED_TOKEN="

# Verify the secret IS available through the mounted API-key env file.
GEN_API_FILE="$SANITIZE_PERSIST/state/hermes-agent-api-keys.env"
assert "OCSB_FORWARD_ENV: API-key env file created despite secret in FORWARD_ENV" \
  test -s "$GEN_API_FILE"
assert_contains "OCSB_FORWARD_ENV: secret delivered via mounted API-key env file" \
  "$(cat "$GEN_API_FILE")" "export OPENROUTER_API_KEY=$SECRET_VAL"
assert "OCSB_FORWARD_ENV: unrelated token not in mounted API-key env file" \
  bash -lc '! grep -Fq -- "UNRELATED_TOKEN" "$1"' _ "$GEN_API_FILE"

echo "--- explicit secret-like --env capture ---"
EXPLICIT_PERSIST="$TMPDIR/persist-explicit"
EXPLICIT_TOKEN="explicit-token-$$"
EXPLICIT_OUTPUT="$({
  CUSTOM_PROVIDER_TOKEN="$EXPLICIT_TOKEN" \
  OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --overwrite --persist-dir "$EXPLICIT_PERSIST" \
    --env CUSTOM_PROVIDER_TOKEN -- \
    bash -lc 'printf "%s\n" "${CUSTOM_PROVIDER_TOKEN:-}"'
})"
EXPLICIT_FILE="$EXPLICIT_PERSIST/state/hermes-agent-api-keys.env"
assert "explicit secret-like --env sourced from mounted file" test "$EXPLICIT_OUTPUT" = "$EXPLICIT_TOKEN"
assert_contains "explicit secret-like --env written to mounted file" \
  "$(cat "$EXPLICIT_FILE")" "export CUSTOM_PROVIDER_TOKEN=$EXPLICIT_TOKEN"

echo "--- caller-provided --api-keys-env-file ---"
mkdir -p "$PERSIST_EXTERNAL"
SOURCE_API_FILE="$PERSIST_EXTERNAL/source-api-keys.env"
printf 'export OPENROUTER_API_KEY=%q\n' "source-openrouter-$$" > "$SOURCE_API_FILE"
printf 'export OPENAI_API_KEY=%q\n' "source-openai-$$" >> "$SOURCE_API_FILE"
SOURCE_HASH_BEFORE="$(sha256sum "$SOURCE_API_FILE" | awk '{print $1}')"

SOURCE_OUTPUT="$({
  OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_EXTERNAL" \
    --api-keys-env-file "$SOURCE_API_FILE" -- \
    bash -lc 'printf "%s\n%s\n" "${OPENROUTER_API_KEY:-}" "${OPENAI_API_KEY:-}"'
})"

SOURCE_HASH_AFTER="$(sha256sum "$SOURCE_API_FILE" | awk '{print $1}')"
SRC_SECRET_A_LINE="$(printf '%s\n' "$SOURCE_OUTPUT" | sed -n '1p')"
SRC_SECRET_B_LINE="$(printf '%s\n' "$SOURCE_OUTPUT" | sed -n '2p')"

assert "provided env file is not rewritten" test "$SOURCE_HASH_BEFORE" = "$SOURCE_HASH_AFTER"
assert "provided env file sourced OPENROUTER_API_KEY" test "$SRC_SECRET_A_LINE" = "source-openrouter-$$"
assert "provided env file sourced OPENAI_API_KEY" test "$SRC_SECRET_B_LINE" = "source-openai-$$"

echo "--- reserved env names reject ---"
set +e
RES_PERSIST_OUT="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_MAIN" --env OCSB_HERMES_AGENT_PERSIST_DIR=/tmp/nope -- --version 2>&1)"
RES_PERSIST_RC=$?
RES_API_FILE_OUT="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_MAIN" --env OCSB_HERMES_AGENT_API_KEYS_ENV_FILE=/tmp/nope -- --version 2>&1)"
RES_API_FILE_RC=$?
RES_HERMES_HOME_OUT="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_MAIN" --env HERMES_HOME=/tmp/nope -- --version 2>&1)"
RES_HERMES_HOME_RC=$?
RES_MSG_CWD_OUT="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_MAIN" --env MESSAGING_CWD=/tmp/nope -- --version 2>&1)"
RES_MSG_CWD_RC=$?
RES_NO_GATEWAY_OUT="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_MAIN" --env OCSB_HERMES_NO_GATEWAY=1 -- --version 2>&1)"
RES_NO_GATEWAY_RC=$?
set -e

assert "reserved OCSB_HERMES_AGENT_PERSIST_DIR fails" test "$RES_PERSIST_RC" -ne 0
assert_contains "reserved OCSB_HERMES_AGENT_PERSIST_DIR message" "$RES_PERSIST_OUT" "reserved for the Hermes Agent wrapper"
assert "reserved OCSB_HERMES_AGENT_API_KEYS_ENV_FILE fails" test "$RES_API_FILE_RC" -ne 0
assert_contains "reserved OCSB_HERMES_AGENT_API_KEYS_ENV_FILE message" "$RES_API_FILE_OUT" "reserved for the Hermes Agent wrapper"
assert "reserved HERMES_HOME fails" test "$RES_HERMES_HOME_RC" -ne 0
assert_contains "reserved HERMES_HOME message" "$RES_HERMES_HOME_OUT" "reserved for the Hermes Agent wrapper"
assert "reserved MESSAGING_CWD fails" test "$RES_MSG_CWD_RC" -ne 0
assert_contains "reserved MESSAGING_CWD message" "$RES_MSG_CWD_OUT" "reserved for the Hermes Agent wrapper"
assert "reserved OCSB_HERMES_NO_GATEWAY fails" test "$RES_NO_GATEWAY_RC" -ne 0
assert_contains "reserved OCSB_HERMES_NO_GATEWAY message" "$RES_NO_GATEWAY_OUT" "reserved for the Hermes Agent wrapper"

echo ""
echo "=== hermes-agent Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
