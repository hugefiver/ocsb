#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: test_dual_layer_host.sh <red-env|green-env|red-sandboxdir|green-sandboxdir> LAUNCHER
EOF
  exit 64
}

[[ $# -eq 2 ]] || usage

SCENARIO="$1"
LAUNCHER="$2"
case "$SCENARIO" in
  red-env|green-env|red-sandboxdir|green-sandboxdir) ;;
  *) usage ;;
esac

[[ -x "$LAUNCHER" ]] || {
  echo "test: launcher is not executable: $LAUNCHER" >&2
  exit 64
}

FIXTURE_ROOT="$(mktemp -d /tmp/ocsb-dual-layer-host.XXXXXX)"
STATE_ROOT="$(mktemp -d /tmp/ocsb-dual-layer-state.XXXXXX)"
STDERR_FILE="$FIXTURE_ROOT/launcher.stderr"

cleanup() {
  # The chroot store contains read-only files. Only directories need their
  # owner write bit restored for host-side fixture removal.
  find "$STATE_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  rm -rf "$FIXTURE_ROOT" "$STATE_ROOT"
}
trap cleanup EXIT INT TERM

run_env_fixture() {
  local workspace_action="${1:---overwrite}"

  cat > "$FIXTURE_ROOT/probe-env.sh" <<'PROBE'
#!/usr/bin/bash
set -euo pipefail

printf 'OUTER_FOO=<%s>\n' "$FOO"
printf 'OUTER_SPACED=<%s>\n' "$SPACED_VALUE"
printf 'OUTER_HOME=<%s>\n' "$HOME"
printf 'OUTER_PATH=<%s>\n' "$PATH"
printf 'OUTER_TERM=<%s>\n' "$TERM"
printf 'OUTER_SSL=<%s>\n' "$SSL_CERT_FILE"
printf 'OUTER_SANDBOX=<%s>\n' "$SANDBOX"
printf 'OUTER_DUAL=<%s>\n' "$OCSB_DUAL_LAYER"

exec "$SHELL" -c '
  printf "INNER_FOO=<%s>\\n" "$FOO"
  printf "INNER_SPACED=<%s>\\n" "$SPACED_VALUE"
  printf "INNER_HOME=<%s>\\n" "$HOME"
  printf "INNER_PATH=<%s>\\n" "$PATH"
  printf "INNER_TERM=<%s>\\n" "$TERM"
  printf "INNER_SSL=<%s>\\n" "$SSL_CERT_FILE"
  printf "INNER_SANDBOX=<%s>\\n" "$SANDBOX"
  printf "INNER_DUAL=<%s>\\n" "$OCSB_DUAL_LAYER"
'
PROBE
  chmod 700 "$FIXTURE_ROOT/probe-env.sh"

  (
    cd "$FIXTURE_ROOT"
    FOO=bar \
      SPACED_VALUE='value with spaces=equals' \
      HOME=/hostile/home \
      PATH=/hostile/path \
      TERM=hostile-term \
      SSL_CERT_FILE=/hostile/cert \
      SANDBOX=hostile-sandbox \
      OCSB_DUAL_LAYER=hostile-dual \
      OCSB_FORWARD_ENV='FOO,SPACED_VALUE,HOME,PATH,TERM,SSL_CERT_FILE,SANDBOX,OCSB_DUAL_LAYER' \
      OCSB_STATE_BASE_DIR="$STATE_ROOT" \
      "$LAUNCHER" --strategy direct "$workspace_action" -- /workspace/probe-env.sh
  ) 2>"$STDERR_FILE"
}

run_sandboxdir_fixture() {
  cat > "$FIXTURE_ROOT/probe-pwd.sh" <<'PROBE'
#!/usr/bin/bash
set -euo pipefail
exec "$SHELL" -c 'pwd'
PROBE
  chmod 700 "$FIXTURE_ROOT/probe-pwd.sh"

  (
    cd "$FIXTURE_ROOT"
    OCSB_STATE_BASE_DIR="$STATE_ROOT" \
      "$LAUNCHER" --strategy direct --overwrite -- /home/sandbox/probe-pwd.sh
  ) 2>"$STDERR_FILE"
}

require_output_line() {
  local expected="$1"
  if ! grep -Fxq "$expected" <<<"$2"; then
    echo "test: missing output: $expected" >&2
    printf 'test: captured output:\n%s\n' "$2" >&2
    return 1
  fi
}

case "$SCENARIO" in
  red-env)
    output="$(run_env_fixture)"
    require_output_line 'OUTER_FOO=<bar>' "$output"
    require_output_line 'OUTER_SPACED=<value with spaces=equals>' "$output"
    require_output_line 'OUTER_HOME=</hostile/home>' "$output"
    require_output_line 'OUTER_PATH=</hostile/path>' "$output"
    require_output_line 'OUTER_TERM=<hostile-term>' "$output"
    require_output_line 'OUTER_SSL=</hostile/cert>' "$output"
    require_output_line 'OUTER_SANDBOX=<hostile-sandbox>' "$output"
    require_output_line 'OUTER_DUAL=<hostile-dual>' "$output"
    if ! require_output_line 'INNER_FOO=<>' "$output"; then
      echo "BLOCKED[RED-dual-layer-env]: baseline inner FOO was not empty" >&2
      exit 2
    fi
    printf '%s\n' 'FAIL[RED-dual-layer-env]: inner FOO is empty'
    exit 1
    ;;

  green-env)
    output="$(run_env_fixture)"
    require_output_line 'OUTER_FOO=<bar>' "$output"
    require_output_line 'OUTER_SPACED=<value with spaces=equals>' "$output"
    require_output_line 'OUTER_HOME=</hostile/home>' "$output"
    require_output_line 'OUTER_PATH=</hostile/path>' "$output"
    require_output_line 'OUTER_TERM=<hostile-term>' "$output"
    require_output_line 'OUTER_SSL=</hostile/cert>' "$output"
    require_output_line 'OUTER_SANDBOX=<hostile-sandbox>' "$output"
    require_output_line 'OUTER_DUAL=<hostile-dual>' "$output"
    require_output_line 'INNER_FOO=<bar>' "$output"
    require_output_line 'INNER_SPACED=<value with spaces=equals>' "$output"
    require_output_line 'INNER_HOME=</home/sandbox>' "$output"
    require_output_line 'INNER_PATH=</home/sandbox/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin>' "$output"
    require_output_line 'INNER_TERM=<xterm-256color>' "$output"
    if ! grep -Exq 'INNER_SSL=</nix/store/.*/etc/ssl/certs/ca-bundle\.crt>' <<<"$output"; then
      echo 'test: inner SSL_CERT_FILE did not use the fixed CA bundle' >&2
      exit 1
    fi
    require_output_line 'INNER_SANDBOX=<1>' "$output"
    require_output_line 'INNER_DUAL=<inner>' "$output"
    rerun_output="$(run_env_fixture --continue)"
    require_output_line 'INNER_FOO=<bar>' "$rerun_output"
    require_output_line 'INNER_DUAL=<inner>' "$rerun_output"
    printf '%s\n' 'PASS[GREEN-dual-layer-env]: FOO=bar'
    ;;

  red-sandboxdir)
    if output="$(run_sandboxdir_fixture)"; then
      echo 'BLOCKED[RED-dual-layer-sandboxdir]: baseline launcher unexpectedly succeeded' >&2
      exit 2
    fi
    if ! grep -Fq '/workspace' "$STDERR_FILE"; then
      echo 'BLOCKED[RED-dual-layer-sandboxdir]: launcher stderr did not identify /workspace' >&2
      cat "$STDERR_FILE" >&2
      exit 2
    fi
    printf '%s\n' 'CONFIRMED[RED-dual-layer-sandboxdir]: launcher stderr identifies hard-coded /workspace failure'
    printf '%s\n' 'FAIL[RED-dual-layer-sandboxdir]: inner wrapper required /workspace'
    exit 1
    ;;

  green-sandboxdir)
    output="$(run_sandboxdir_fixture)"
    require_output_line '/home/sandbox' "$output"
    printf '%s\n' 'PASS[GREEN-dual-layer-sandboxdir]: pwd=/home/sandbox'
    ;;
esac
