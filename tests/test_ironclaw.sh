#!/usr/bin/env bash
set -euo pipefail

WRAPPER="${1:?Usage: $0 <path-to-ocsb-ironclaw-binary>}"
TMPDIR="$(mktemp -d)"
PERSIST_EMBEDDED="$TMPDIR/persist-embedded"
PERSIST_EXTERNAL="$TMPDIR/persist-external"
PERSIST_SIDECAR="$TMPDIR/persist-sidecar"
FAKE_BIN="$TMPDIR/fake-bin"

PASS=0
FAIL=0

cleanup() {
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

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "SKIP: GitHub Actions runners restrict bwrap netns (RTM_NEWADDR)"
  exit 0
fi

mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/fake-oci" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${OCSB_FAKE_OCI_LOG:?OCSB_FAKE_OCI_LOG is required}"
printf '%s %s\n' "$(basename "$0")" "$*" >> "$log_file"

cmd="${1:-}"
shift || true

case "$cmd" in
  inspect)
    if [[ "${1:-}" == "--format" ]]; then
      shift 2
    fi
    container="${1:-}"
    case "$container" in
      sidecar-running)
        echo "running"
        exit 0
        ;;
      sidecar-stopped)
        echo "exited"
        exit 0
        ;;
      sidecar-missing)
        exit 1
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  start)
    exit 0
    ;;
  run)
    exit 0
    ;;
  exec)
    _container="${1:-}"
    shift || true
    subcmd="${1:-}"
    shift || true
    case "$subcmd" in
      pg_isready)
        exit 0
        ;;
      psql)
        print_db_exists=0
        for arg in "$@"; do
          if [[ "$arg" == "-tAc" ]]; then
            print_db_exists=1
            break
          fi
        done
        if [[ "$print_db_exists" -eq 1 ]]; then
          printf '1\n'
        fi
        exit 0
        ;;
      createdb)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$FAKE_BIN/fake-oci"
ln -s "$FAKE_BIN/fake-oci" "$FAKE_BIN/podman"
ln -s "$FAKE_BIN/fake-oci" "$FAKE_BIN/docker"

echo "=== ironclaw sandbox test suite ==="

echo "--- wrapper help text ---"
HELP_TEXT="$($WRAPPER --help)"
WRAPPER_SCRIPT="$(readlink -f "$WRAPPER")"
WRAPPER_TEXT="$(cat "$WRAPPER_SCRIPT")"
assert_contains "help: persist default uses persist variant" "$HELP_TEXT" 'Default: $HOME/.cache/ocsb/$PERSIST_VARIANT.'
assert_contains "help: arch wrappers share non-arch data dir" "$HELP_TEXT" 'Arch-optimized wrappers share the'
assert_contains "help: db env file path documented" "$HELP_TEXT" 'state/ironclaw-db.env'
assert_contains "help: fixed sidecar container default" "$HELP_TEXT" 'Default: ocsb-ironclaw-db.'
assert_contains "wrapper: persist variant default branch present" "$WRAPPER_TEXT" 'PERSIST_DIR="$HOME/.cache/ocsb/$PERSIST_VARIANT"'
assert "wrapper: persist default no longer uses arch-suffixed VARIANT" bash -lc '! grep -Fq -- "$2" "$1"' _ "$WRAPPER_SCRIPT" 'PERSIST_DIR="$HOME/.cache/ocsb/$VARIANT"'
assert_contains "wrapper: launches from persisted home" "$WRAPPER_TEXT" 'cd "$PERSIST_DIR/home"'
assert_contains "wrapper: fixed sidecar container default" "$WRAPPER_TEXT" 'DB_SIDECAR_CONTAINER="ocsb-ironclaw-db"'
assert "wrapper: no DB env names forwarded via OCSB_FORWARD_ENV" bash -lc '! grep -Fq -- "append_forward_env_name DATABASE_URL" "$1"' _ "$WRAPPER_SCRIPT"
assert_contains "wrapper: DB --env gate present" "$WRAPPER_TEXT" 'if ! is_db_env_name "$_ENV_NAME"; then'
assert_contains "wrapper: reserved internal env gate present" "$WRAPPER_TEXT" 'is_reserved_ironclaw_env_name "$_ENV_NAME"'
assert_contains "wrapper: db env file uses atomic rename" "$WRAPPER_TEXT" 'mv -f "$_db_env_tmp" "$_db_env_file"'
assert_contains "wrapper: sidecar pg18 mount target" "$WRAPPER_TEXT" '/var/lib/postgresql'

echo "--- wrapper + embedded mode smoke ---"
"$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_EMBEDDED" -- --version

echo "--- embedded mode sandbox probes ---"
EXPECTED_STATE_DIR="$PERSIST_EMBEDDED/state/ironclaw"
PROBE_SCRIPT="$PERSIST_EMBEDDED/home/ironclaw-probe.sh"
mkdir -p "$PERSIST_EMBEDDED/home"
cat > "$PROBE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

expected_state_dir="${1:?expected state dir}"

vector_version="$(psql -h /run/postgresql -d ironclaw -Atqc "SELECT extversion FROM pg_extension WHERE extname='vector';" | tr -d '[:space:]')"
if [[ -z "$vector_version" ]]; then
  echo "vector extension missing" >&2
  exit 1
fi

nix --version >/dev/null

case ":$PATH:" in
  *:/home/sandbox/.nix-profile/bin:*:/nix/var/nix/profiles/default/bin:*) ;;
  *)
    echo "expected nix profile paths in PATH, got $PATH" >&2
    exit 1
    ;;
esac

if [[ "$OCSB_STATE_DIR" != "$expected_state_dir" ]]; then
  echo "expected OCSB_STATE_DIR=$expected_state_dir, got $OCSB_STATE_DIR" >&2
  exit 1
fi

if [[ "$OCSB_NETWORK" != "host" ]]; then
  echo "expected OCSB_NETWORK=host, got $OCSB_NETWORK" >&2
  exit 1
fi

if [[ "${OCSB_IRONCLAW_DB_MODE:-}" != "embedded" ]]; then
  echo "expected OCSB_IRONCLAW_DB_MODE=embedded, got ${OCSB_IRONCLAW_DB_MODE:-<unset>}" >&2
  exit 1
fi

if [[ "${DATABASE_URL:-}" != "postgres:///ironclaw?host=/run/postgresql&sslmode=disable" ]]; then
  echo "unexpected embedded DATABASE_URL: ${DATABASE_URL:-<unset>}" >&2
  exit 1
fi

curl -s --max-time 10 https://example.com >/dev/null
if [[ "$(pwd)" != "/home/sandbox" ]]; then
  echo "expected cwd=/home/sandbox, got $(pwd)" >&2
  exit 1
fi
printf 'workspace-ok' > /home/sandbox/ironclaw-workspace-marker
EOF
chmod +x "$PROBE_SCRIPT"
OCSB_EXEC_OVERRIDE=1 "$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_EMBEDDED" -- bash /home/sandbox/ironclaw-probe.sh "$EXPECTED_STATE_DIR"

echo "--- stable sandbox state check ---"
assert "chroot merged nix store exists" test -d "$EXPECTED_STATE_DIR/chroot/merged/nix/store"
assert "legacy chroot layout removed" test ! -e "$EXPECTED_STATE_DIR/chroot/nix"
assert "ironclaw workspace uses persisted home" test "$(cat "$PERSIST_EMBEDDED/home/ironclaw-workspace-marker")" = "workspace-ok"
assert "ironclaw wrapper does not create separate workspace dir" test ! -e "$PERSIST_EMBEDDED/workspace"

echo "--- external mode validation + forwarding ---"
set +e
EXTERNAL_ERR="$("$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_EXTERNAL" --db-mode external -- --version 2>&1)"
EXTERNAL_RC=$?
set -e
assert "external mode without DATABASE_URL fails" test "$EXTERNAL_RC" -ne 0
assert_contains "external mode failure message" "$EXTERNAL_ERR" "requires DATABASE_URL"

set +e
RESERVED_MODE_ERR="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_EXTERNAL" --db-mode external --env OCSB_IRONCLAW_DB_MODE=embedded -- --version 2>&1)"
RESERVED_MODE_RC=$?
RESERVED_FILE_ERR="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_EXTERNAL" --db-mode external --env OCSB_IRONCLAW_DB_ENV_FILE=/tmp/evil.env -- --version 2>&1)"
RESERVED_FILE_RC=$?
set -e
assert "reserved db mode env fails" test "$RESERVED_MODE_RC" -ne 0
assert_contains "reserved db mode env failure message" "$RESERVED_MODE_ERR" "reserved for the Ironclaw wrapper"
assert "reserved db env file env fails" test "$RESERVED_FILE_RC" -ne 0
assert_contains "reserved db env file failure message" "$RESERVED_FILE_ERR" "reserved for the Ironclaw wrapper"

EXTERNAL_DB_URL="postgres://extuser:extpass@db.example:5432/ironclaw?sslmode=require"
EXTERNAL_NON_DB_FLAG="external-non-db-flag-$$"
mkdir -p "$PERSIST_EXTERNAL/state"
printf 'stale-db-env\n' > "$PERSIST_EXTERNAL/state/ironclaw-db.env"
chmod 0644 "$PERSIST_EXTERNAL/state/ironclaw-db.env"
EXTERNAL_OUTPUT="$(
  PATH="$FAKE_BIN:$PATH" \
  OCSB_FAKE_OCI_LOG="$TMPDIR/external-sidecar.log" \
  DATABASE_SSLMODE="require" \
  DATABASE_POOL_SIZE="7" \
  IRONCLAW_WRAPPER_NON_DB_FLAG="$EXTERNAL_NON_DB_FLAG" \
  OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_EXTERNAL" --db-mode external \
  --env "DATABASE_URL=$EXTERNAL_DB_URL" --env DATABASE_SSLMODE --env DATABASE_POOL_SIZE --env IRONCLAW_WRAPPER_NON_DB_FLAG -- \
  bash -lc 'printf "%s\n%s\n%s\n%s\n%s\n%s\n" "$OCSB_IRONCLAW_DB_MODE" "$DATABASE_URL" "$DATABASE_BACKEND" "$DATABASE_SSLMODE" "$DATABASE_POOL_SIZE" "$IRONCLAW_WRAPPER_NON_DB_FLAG"'
)"
EXT_MODE_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '1p')"
EXT_URL_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '2p')"
EXT_BACKEND_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '3p')"
EXT_SSLMODE_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '4p')"
EXT_POOL_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '5p')"
EXT_NON_DB_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '6p')"

EXTERNAL_DB_ENV_FILE="$PERSIST_EXTERNAL/state/ironclaw-db.env"
assert "external db env file exists" test -s "$EXTERNAL_DB_ENV_FILE"
assert "external db env file mode 0600" test "$(stat -c %a "$EXTERNAL_DB_ENV_FILE")" = "600"
assert "external db env file exports DATABASE_URL" grep -Fq -- "export DATABASE_URL=" "$EXTERNAL_DB_ENV_FILE"
assert "external db env file stale content removed" bash -lc '! grep -Fq -- "stale-db-env" "$1"' _ "$EXTERNAL_DB_ENV_FILE"
assert "external db env temp files cleaned" bash -lc '! compgen -G "$1/state/.ironclaw-db.env.*" >/dev/null' _ "$PERSIST_EXTERNAL"

EXT_ENVFILE_CHECK="$({
  source "$EXTERNAL_DB_ENV_FILE"
  printf "%s\n%s\n%s\n%s\n" "${DATABASE_URL:-}" "${DATABASE_BACKEND:-}" "${DATABASE_SSLMODE:-}" "${DATABASE_POOL_SIZE:-}"
})"
EXT_FILE_URL_LINE="$(printf '%s\n' "$EXT_ENVFILE_CHECK" | sed -n '1p')"
EXT_FILE_BACKEND_LINE="$(printf '%s\n' "$EXT_ENVFILE_CHECK" | sed -n '2p')"
EXT_FILE_SSLMODE_LINE="$(printf '%s\n' "$EXT_ENVFILE_CHECK" | sed -n '3p')"
EXT_FILE_POOL_LINE="$(printf '%s\n' "$EXT_ENVFILE_CHECK" | sed -n '4p')"

assert "external mode forwarded db mode" test "$EXT_MODE_LINE" = "external"
assert "external mode forwarded DATABASE_URL" test "$EXT_URL_LINE" = "$EXTERNAL_DB_URL"
assert "external mode forwarded DATABASE_BACKEND" test "$EXT_BACKEND_LINE" = "postgres"
assert "external mode forwarded DATABASE_SSLMODE" test "$EXT_SSLMODE_LINE" = "require"
assert "external mode forwarded DATABASE_POOL_SIZE" test "$EXT_POOL_LINE" = "7"
assert "external mode forwards non-db --env" test "$EXT_NON_DB_LINE" = "$EXTERNAL_NON_DB_FLAG"
assert "external db env file has DATABASE_URL" test "$EXT_FILE_URL_LINE" = "$EXTERNAL_DB_URL"
assert "external db env file has DATABASE_BACKEND" test "$EXT_FILE_BACKEND_LINE" = "postgres"
assert "external db env file has DATABASE_SSLMODE" test "$EXT_FILE_SSLMODE_LINE" = "require"
assert "external db env file has DATABASE_POOL_SIZE" test "$EXT_FILE_POOL_LINE" = "7"
assert "external mode skips embedded initdb" test ! -e "$PERSIST_EXTERNAL/pgdata/PG_VERSION"
assert "external mode does not touch sidecar runtime" test ! -s "$TMPDIR/external-sidecar.log"

echo "--- sidecar mode: running container reuse ---"
RUNNING_LOG="$TMPDIR/sidecar-running.log"
mkdir -p "$PERSIST_SIDECAR"
printf 'fake-sidecar-password' > "$PERSIST_SIDECAR/sidecar-db-password"
chmod 0600 "$PERSIST_SIDECAR/sidecar-db-password"
SIDE_OUTPUT_RUNNING="$(
  PATH="$FAKE_BIN:$PATH" \
  OCSB_FAKE_OCI_LOG="$RUNNING_LOG" \
  IRONCLAW_WRAPPER_NON_DB_FLAG="sidecar-non-db-$$" \
  OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_SIDECAR" \
    --db-mode sidecar --db-sidecar-runtime podman --db-sidecar-container sidecar-running --db-sidecar-port 55439 \
    --env IRONCLAW_WRAPPER_NON_DB_FLAG -- \
    bash -lc 'printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n" "$OCSB_IRONCLAW_DB_MODE" "$PGHOST" "$PGPORT" "$PGUSER" "$PGDATABASE" "$PGPASSWORD" "$DATABASE_BACKEND" "$DATABASE_URL" "$IRONCLAW_WRAPPER_NON_DB_FLAG"'
)"
SC_MODE_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '1p')"
SC_HOST_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '2p')"
SC_PORT_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '3p')"
SC_USER_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '4p')"
SC_DB_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '5p')"
SC_PASS_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '6p')"
SC_BACKEND_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '7p')"
SC_URL_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '8p')"
SC_NON_DB_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '9p')"
SC_PASS_FILE="$(cat "$PERSIST_SIDECAR/sidecar-db-password")"
SC_URL_EXPECTED="postgres://ironclaw:$SC_PASS_FILE@127.0.0.1:55439/ironclaw?sslmode=disable"
SC_DB_ENV_FILE="$PERSIST_SIDECAR/state/ironclaw-db.env"

assert "sidecar mode forwarded db mode" test "$SC_MODE_LINE" = "sidecar"
assert "sidecar mode forwarded PGHOST" test "$SC_HOST_LINE" = "127.0.0.1"
assert "sidecar mode forwarded PGPORT" test "$SC_PORT_LINE" = "55439"
assert "sidecar mode forwarded PGUSER" test "$SC_USER_LINE" = "ironclaw"
assert "sidecar mode forwarded PGDATABASE" test "$SC_DB_LINE" = "ironclaw"
assert "sidecar mode forwarded password" test "$SC_PASS_LINE" = "$SC_PASS_FILE"
assert "sidecar mode forwarded DATABASE_BACKEND" test "$SC_BACKEND_LINE" = "postgres"
assert "sidecar mode synthesized DATABASE_URL" test "$SC_URL_LINE" = "$SC_URL_EXPECTED"
assert "sidecar mode forwards non-db --env" test "$SC_NON_DB_LINE" = "sidecar-non-db-$$"

assert "sidecar password file exists" test -s "$PERSIST_SIDECAR/sidecar-db-password"
assert "sidecar password file mode 0600" test "$(stat -c %a "$PERSIST_SIDECAR/sidecar-db-password")" = "600"
assert "sidecar data dir exists" test -d "$PERSIST_SIDECAR/pgdata-sidecar"
assert "sidecar mode skips embedded initdb" test ! -e "$PERSIST_SIDECAR/pgdata/PG_VERSION"
assert "sidecar db env file exists" test -s "$SC_DB_ENV_FILE"
assert "sidecar db env file mode 0600" test "$(stat -c %a "$SC_DB_ENV_FILE")" = "600"

SC_ENVFILE_CHECK="$({
  source "$SC_DB_ENV_FILE"
  printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n" "${PGHOST:-}" "${PGPORT:-}" "${PGUSER:-}" "${PGDATABASE:-}" "${PGPASSWORD:-}" "${DATABASE_BACKEND:-}" "${DATABASE_URL:-}"
})"
SC_FILE_HOST_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '1p')"
SC_FILE_PORT_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '2p')"
SC_FILE_USER_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '3p')"
SC_FILE_DB_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '4p')"
SC_FILE_PASS_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '5p')"
SC_FILE_BACKEND_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '6p')"
SC_FILE_URL_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '7p')"

assert "sidecar db env file has PGHOST" test "$SC_FILE_HOST_LINE" = "127.0.0.1"
assert "sidecar db env file has PGPORT" test "$SC_FILE_PORT_LINE" = "55439"
assert "sidecar db env file has PGUSER" test "$SC_FILE_USER_LINE" = "ironclaw"
assert "sidecar db env file has PGDATABASE" test "$SC_FILE_DB_LINE" = "ironclaw"
assert "sidecar db env file has PGPASSWORD" test "$SC_FILE_PASS_LINE" = "$SC_PASS_FILE"
assert "sidecar db env file has DATABASE_BACKEND" test "$SC_FILE_BACKEND_LINE" = "postgres"
assert "sidecar db env file has DATABASE_URL" test "$SC_FILE_URL_LINE" = "$SC_URL_EXPECTED"

RUNNING_LOG_TEXT="$(cat "$RUNNING_LOG")"
assert_contains "sidecar running: uses podman runtime" "$RUNNING_LOG_TEXT" "podman inspect --format {{.State.Status}} sidecar-running"
assert "sidecar running: does not start container" bash -lc '! grep -Fq -- "podman start sidecar-running" "$1"' _ "$RUNNING_LOG"
assert "sidecar running: does not run new container" bash -lc '! grep -Fq -- "podman run -d --name sidecar-running" "$1"' _ "$RUNNING_LOG"
assert "sidecar running: readiness probe executed" grep -Fq -- "podman exec sidecar-running pg_isready" "$RUNNING_LOG"

echo "--- sidecar mode: stopped container start ---"
STOPPED_LOG="$TMPDIR/sidecar-stopped.log"
PATH="$FAKE_BIN:$PATH" OCSB_FAKE_OCI_LOG="$STOPPED_LOG" OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_SIDECAR" \
    --db-mode sidecar --db-sidecar-runtime podman --db-sidecar-container sidecar-stopped --db-sidecar-port 55439 -- \
    bash -lc 'echo stopped-case-ok' >/dev/null
STOPPED_LOG_TEXT="$(cat "$STOPPED_LOG")"
assert_contains "sidecar stopped: inspect by name" "$STOPPED_LOG_TEXT" "podman inspect --format {{.State.Status}} sidecar-stopped"
assert_contains "sidecar stopped: starts existing container" "$STOPPED_LOG_TEXT" "podman start sidecar-stopped"
assert "sidecar stopped: does not run new container" bash -lc '! grep -Fq -- "podman run -d --name sidecar-stopped" "$1"' _ "$STOPPED_LOG"

echo "--- sidecar mode: missing container create/run (docker runtime) ---"
MISSING_LOG="$TMPDIR/sidecar-missing.log"
PATH="$FAKE_BIN:$PATH" OCSB_FAKE_OCI_LOG="$MISSING_LOG" OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_SIDECAR" \
    --db-mode sidecar --db-sidecar-runtime docker --db-sidecar-container sidecar-missing --db-sidecar-port 55439 -- \
    bash -lc 'echo missing-case-ok' >/dev/null
MISSING_LOG_TEXT="$(cat "$MISSING_LOG")"
assert_contains "sidecar missing: uses docker runtime" "$MISSING_LOG_TEXT" "docker inspect --format {{.State.Status}} sidecar-missing"
assert_contains "sidecar missing: creates new container" "$MISSING_LOG_TEXT" "docker run -d --name sidecar-missing"
assert_contains "sidecar missing: mounts pg18 data root" "$MISSING_LOG_TEXT" "$PERSIST_SIDECAR/pgdata-sidecar:/var/lib/postgresql"
assert "sidecar missing: does not call start" bash -lc '! grep -Fq -- "docker start sidecar-missing" "$1"' _ "$MISSING_LOG"

echo ""
echo "=== ironclaw Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
