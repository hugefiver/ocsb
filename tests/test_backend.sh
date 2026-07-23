#!/usr/bin/env bash
# Backend option and launcher regression tests that do not require podman/nspawn.
set -euo pipefail

PASS=0
FAIL=0

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

assert_not() {
  local desc="$1"; shift
  if ! "$@"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_fails() {
  local desc="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected failure but succeeded)" >&2
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

FLAKE_DIR="$(realpath "${1:?Usage: $0 <path-to-ocsb-flake> [--case NAME]}")"
shift
TEST_CASE="all"
if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != "--case" ]]; then
    echo "Usage: $0 <path-to-ocsb-flake> [--case NAME]" >&2
    exit 2
  fi
  TEST_CASE="$2"
fi
TMPDIR="$(mktemp -d)"
FIXTURE_PIDS=()
cleanup() {
  local pid
  for pid in "${FIXTURE_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${FIXTURE_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  find "$TMPDIR" -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "=== backend option test suite ==="

build_backend() {
  local name="$1"
  local backend="$2"
  nix build --no-link --print-out-paths \
    --impure --expr "
      let
        flake = builtins.getFlake \"path:$FLAKE_DIR\";
        pkgs = import flake.inputs.nixpkgs { system = \"x86_64-linux\"; };
        mkSandbox = import $FLAKE_DIR/lib/mkSandbox.nix { inherit pkgs; lib = pkgs.lib; };
      in mkSandbox {
        app.name = \"$name\";
        packages = with pkgs; [ coreutils ];
        workspace = { strategy = \"direct\"; baseDir = \".ocsb\"; name = \"_\"; };
        backend.type = \"$backend\";
        network.enable = null;
        env = {};
        mounts.ro = [];
        mounts.rw = [];
      }
    "
}

build_backend_expr() {
  local name="$1"
  local expr="$2"
  nix build --no-link --print-out-paths \
    --impure --expr "
      let
        flake = builtins.getFlake \"path:$FLAKE_DIR\";
        pkgs = import flake.inputs.nixpkgs { system = \"x86_64-linux\"; };
        mkSandbox = import $FLAKE_DIR/lib/mkSandbox.nix { inherit pkgs; lib = pkgs.lib; };
      in mkSandbox ({ pkgs, ... }: {
        app.name = \"$name\";
        packages = with pkgs; [ coreutils ];
        workspace = { strategy = \"direct\"; baseDir = \".ocsb\"; name = \"_\"; };
        env = {};
        mounts.ro = [];
        mounts.rw = [];
      } // ($expr))
    "
}

read_launcher_text() {
  local wrapper="$1"
  local wrapper_script
  wrapper_script="$(readlink -f "$wrapper")"
  local launcher
  launcher="$(sed -n 's/^exec \([^ ]*\) .*/\1/p' "$wrapper_script" | head -n1)"
  if [[ -z "$launcher" ]]; then
    echo "cannot find launcher path in $wrapper_script" >&2
    return 1
  fi
  cat "$launcher"
}

build_generic_daemon_fixture() {
  local fixture_nix="$TMPDIR/generic-daemon-pip-fixture.nix"

  cat > "$fixture_nix" <<'EOF'
{ flakeDir }:
let
  flake = builtins.getFlake "path:${flakeDir}";
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  mkSandbox = import (flakeDir + "/lib/mkSandbox.nix") { inherit pkgs; lib = pkgs.lib; };
in mkSandbox {
  app = {
    name = "generic-daemon-pip-fixture";
    daemon = [
      {
        command = ''
          printf '%s\n' 'GENERIC_DAEMON_MARKER' >> "$OCSB_DAEMON_MARKER"
        '';
        restart = true;
      }
    ];
  };
  packages = with pkgs; [ coreutils ];
  workspace = {
    strategy = "direct";
    baseDir = ".ocsb";
    name = "_";
    sandboxDir = "/workspace";
  };
  backend.type = "bubblewrap";
  network.enable = null;
  env = {
    HOME = "/workspace/home";
    OCSB_DAEMON_MARKER = "/workspace/daemon.marker";
    OCSB_FOREGROUND_MARKER = "/workspace/foreground.marker";
    HTTP_PROXY = "http://127.0.0.1:9";
    HTTPS_PROXY = "http://127.0.0.1:9";
    ALL_PROXY = "http://127.0.0.1:9";
    http_proxy = "http://127.0.0.1:9";
    https_proxy = "http://127.0.0.1:9";
    all_proxy = "http://127.0.0.1:9";
    NO_PROXY = "";
    PIP_INDEX_URL = "http://127.0.0.1:9/simple";
    PIP_DEFAULT_TIMEOUT = "1";
    PIP_RETRIES = "0";
    PIP_NO_INDEX = "1";
    PIP_CONSTRAINT = "/workspace/pip-constraint.txt";
    PIP_DISABLE_PIP_VERSION_CHECK = "1";
  };
  mounts.ro = [];
  mounts.rw = [];
}
EOF

  nix build --no-link --print-out-paths --impure \
    --file "$fixture_nix" --argstr flakeDir "$FLAKE_DIR"
}

read_generic_daemon_supervisor() {
  local launcher_text="$1"
  local supervisor

  supervisor="$(grep -oE '/nix/store/[^[:space:]"]+-supervisor' <<<"$launcher_text" | head -n1)"
  if [[ -z "$supervisor" || ! -f "$supervisor" ]]; then
    echo "cannot find generic daemon supervisor in generated launcher" >&2
    return 1
  fi
  cat "$supervisor"
}

supervisor_has_hermes_pip_coupling() {
  grep -Eq 'HERMES_HOME|TERMINAL_CWD|\.hermes-venv|/pip|PYTHONPATH|python3 -m venv' <<<"$1"
}

build_process_fixture() {
  nix build --no-link --print-out-paths \
    --impure --expr "
      let
        flake = builtins.getFlake \"path:$FLAKE_DIR\";
        pkgs = import flake.inputs.nixpkgs { system = \"x86_64-linux\"; };
        runtimeProcess = import $FLAKE_DIR/lib/runtime-process.nix { inherit pkgs; lib = pkgs.lib; };
      in pkgs.writeShellScriptBin \"ocsb-process-record-fixture\" ''
        set -euo pipefail
        \${runtimeProcess.shellHelpers}
        case \"\$1\" in
          runtime-dir)
            ocsb_runtime_dir
            ;;
          digest)
            ocsb_instance_digest \"\$2\" \"\$3\"
            ;;
          path)
            ocsb_process_record_path \"\$2\" \"\$3\"
            ;;
          write)
            ocsb_write_process_record \"\$2\" \"\$3\" \"\$4\"
            ;;
          validate)
            ocsb_validate_process_record \"\$2\" \"\$3\"
            printf 'VALID\\t%s\\t%s\\t%s\\n' \"\$OCSB_RECORD_PID\" \"\$OCSB_RECORD_START\" \"\$OCSB_RECORD_INSTANCE\"
            ;;
          remove)
            ocsb_remove_matching_process_record \"\$2\" \"\$3\"
            ;;
          remove-barrier)
            eval \"\$(declare -f ocsb__read_process_record_line | sed '1s/ocsb__read_process_record_line/_fixture_read_process_record_line/')\"
            ocsb__read_process_record_line() {
              _fixture_read_process_record_line \"\$@\" || return 1
              : > \"''\${OCSB_PROCESS_RECORD_READY:?}\"
              while [[ ! -e \"''\${OCSB_PROCESS_RECORD_RELEASE:?}\" ]]; do
                \${pkgs.coreutils}/bin/sleep 0.01
              done
            }
            ocsb_remove_matching_process_record \"\$2\" \"\$3\"
            ;;
          write-then-child)
            ocsb_write_process_record \"\$2\" \"\$3\" \"\$4\"
            _runtime=\"\$(ocsb_runtime_dir)\"
            \${pkgs.bash}/bin/bash -c '
              for _fd in /proc/\$\$/fd/*; do
                _target=\"\$(readlink \"\$_fd\" 2>/dev/null || true)\"
                [[ \"\$_target\" != \"\$1\" ]] || exit 1
              done
            ' _ \"\$_runtime\"
            ;;
          *)
            exit 2
            ;;
        esac
      ''
    "
}

proc_start_field_22() {
  local pid="$1"
  local stat_line rest
  local -a fields
  IFS= read -r stat_line < "/proc/$pid/stat"
  rest="${stat_line##*) }"
  read -r -a fields <<<"$rest"
  printf '%s\n' "${fields[19]}"
}

wait_for_record() {
  local path="$1"
  local pid="$2"
  local attempt
  for attempt in $(seq 1 100); do
    [[ -f "$path" ]] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

process_record_schema_case() {
  local fixture_out fixture_store fixture_bin fixture_script fixture_text
  local xdg_parent runtime_dir fallback_parent fallback_runtime unsafe_parent
  local state_base role_one role_two state_one state_two instance_one instance_two
  local record_one record_two schema_pid schema_start expected_line actual_line validation
  local cas_pid cas_line wrong_line replacement_pid replacement_start replacement_line
  local cas_ready cas_release cas_remove_pid cas_writer_pid cas_remove_rc cas_writer_rc writer_blocked
  local one_out one_store one_bin two_out two_store two_bin project_dir
  local job_one job_two launcher_record_one launcher_record_two
  local launcher_instance_one launcher_instance_two launcher_line_one launcher_line_two
  local tag launcher_pid_one launcher_start_one launcher_record_instance_one
  local launcher_pid_two launcher_start_two launcher_record_instance_two

  fixture_out="$(build_process_fixture 2>&1)" || {
    echo "$fixture_out" >&2
    return 1
  }
  fixture_store="${fixture_out##*$'\n'}"
  fixture_bin="$fixture_store/bin/ocsb-process-record-fixture"
  fixture_script="$(readlink -f "$fixture_bin")"
  fixture_text="$(cat "$fixture_script")"

  assert_contains "process record write locks the runtime-directory inode" "$fixture_text" 'ocsb__lock_process_record_dir'
  assert_contains "process record write uses held-directory mktemp" "$fixture_text" 'mktemp "$OCSB_PROCESS_RECORD_LOCK_DIR/.process-record.XXXXXX"'
  assert_contains "process record publish uses held-directory atomic mv -T" "$fixture_text" 'mv -T -- "$_tmp" "$OCSB_PROCESS_RECORD_LOCK_DIR/$_base"'
  assert_contains "process record writer emits strict v1 tabs" "$fixture_text" "printf 'v1\\t%s\\t%s\\t%s\\n'"

  xdg_parent="$TMPDIR/xdg-runtime"
  install -d -m 0700 "$xdg_parent"
  runtime_dir="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" runtime-dir)"
  assert "XDG runtime path is private ocsb child" [ "$runtime_dir" = "$xdg_parent/ocsb" ]
  assert "XDG runtime directory mode is 0700" [ "$(stat -c %a "$runtime_dir")" = "700" ]
  assert "XDG runtime directory owner is current uid" [ "$(stat -c %u "$runtime_dir")" = "$(id -u)" ]
  assert_not "XDG runtime directory is not a symlink" [ -L "$runtime_dir" ]

  fallback_parent="$TMPDIR/fallback-parent"
  install -d -m 0700 "$fallback_parent"
  fallback_runtime="$(env -u XDG_RUNTIME_DIR TMPDIR="$fallback_parent" "$fixture_bin" runtime-dir)"
  assert "fallback runtime path includes current uid" [ "$fallback_runtime" = "$fallback_parent/ocsb-$(id -u)" ]
  assert "fallback runtime directory mode is 0700" [ "$(stat -c %a "$fallback_runtime")" = "700" ]

  unsafe_parent="$TMPDIR/unsafe-parent"
  install -d -m 0777 "$unsafe_parent"
  assert_fails "fallback rejects current-uid world-writable parent" \
    env -u XDG_RUNTIME_DIR TMPDIR="$unsafe_parent" "$fixture_bin" runtime-dir
  chmod 0700 "$unsafe_parent"

  state_base="$TMPDIR/process-state"
  mkdir -p "$state_base"
  role_one="runtime-one"
  role_two="runtime-two"
  state_one="$(realpath -m "$state_base/runtime-one")"
  state_two="$(realpath -m "$state_base/runtime-two")"
  instance_one="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" digest "$role_one" "$state_one")"
  instance_two="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" digest "$role_two" "$state_two")"
  record_one="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" path "$role_one" "$state_one")"
  record_two="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" path "$role_two" "$state_two")"
  if [[ "$instance_one" =~ ^[0-9a-f]{64}$ ]]; then
    echo "  PASS: instance digest is 64 lowercase hex"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: instance digest is 64 lowercase hex" >&2
    FAIL=$((FAIL + 1))
  fi
  assert "distinct role/path identities produce distinct record names" [ "$record_one" != "$record_two" ]
  assert "record filename is process-digest.pid" [ "$(basename "$record_one")" = "process-$instance_one.pid" ]

  sleep 60 &
  schema_pid=$!
  FIXTURE_PIDS+=("$schema_pid")
  XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" write "$record_one" "$schema_pid" "$instance_one"
  schema_start="$(proc_start_field_22 "$schema_pid")"
  expected_line="$(printf 'v1\t%s\t%s\t%s' "$schema_pid" "$schema_start" "$instance_one")"
  actual_line="$(cat "$record_one")"
  assert "record has exact v1 PID start instance schema" [ "$actual_line" = "$expected_line" ]
  assert "record contains exactly one line" [ "$(wc -l < "$record_one")" -eq 1 ]
  assert "record mode is 0600" [ "$(stat -c %a "$record_one")" = "600" ]
  assert "record owner is current uid" [ "$(stat -c %u "$record_one")" = "$(id -u)" ]
  assert_not "record is not a symlink" [ -L "$record_one" ]
  validation="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$record_one" "$instance_one")"
  assert "reader exports validated process fields" \
    [ "$validation" = "$(printf 'VALID\t%s\t%s\t%s' "$schema_pid" "$schema_start" "$instance_one")" ]
  assert_fails "reader rejects wrong instance" \
    env XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$record_one" "$instance_two"

  chmod 0644 "$record_one"
  assert_fails "reader rejects wrong record mode" \
    env XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$record_one" "$instance_one"
  chmod 0600 "$record_one"
  rm -f "$record_one"
  mkdir "$record_one"
  assert_fails "reader rejects non-regular record" \
    env XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$record_one" "$instance_one"
  rmdir "$record_one"

  printf '%s\n' "$schema_pid" > "$record_one"
  chmod 0600 "$record_one"
  assert_fails "reader rejects legacy PID-only record" \
    env XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$record_one" "$instance_one"
  printf 'v1\t%s\t%s\t%s\n' "$schema_pid" "$((schema_start + 1))" "$instance_one" > "$record_one"
  assert_fails "reader rejects changed process start time" \
    env XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$record_one" "$instance_one"

  printf '%s\n' "$expected_line" > "$record_one"
  kill "$schema_pid"
  wait "$schema_pid" 2>/dev/null || true
  assert_fails "reader rejects dead PID" \
    env XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$record_one" "$instance_one"
  rm -f "$record_one"

  sleep 60 &
  cas_pid=$!
  FIXTURE_PIDS+=("$cas_pid")
  XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" write "$record_one" "$cas_pid" "$instance_one"
  cas_line="$(cat "$record_one")"
  wrong_line="${cas_line%?}0"
  assert_fails "CAS removal rejects a non-matching full line" \
    env XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" remove "$record_one" "$wrong_line"
  assert "CAS mismatch leaves record present" [ -f "$record_one" ]
  XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" remove "$record_one" "$cas_line"
  assert_not "CAS match removes record" [ -e "$record_one" ]

  # The remover pauses after reading the expected line while it still owns the
  # runtime-directory inode lock.  The publisher must wait, then publish its
  # replacement after the matching remove completes.
  XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" write "$record_one" "$cas_pid" "$instance_one"
  cas_line="$(cat "$record_one")"
  cas_ready="$TMPDIR/process-record-cas.ready"
  cas_release="$TMPDIR/process-record-cas.release"
  rm -f -- "$cas_ready" "$cas_release"
  env XDG_RUNTIME_DIR="$xdg_parent" OCSB_PROCESS_RECORD_READY="$cas_ready" \
    OCSB_PROCESS_RECORD_RELEASE="$cas_release" "$fixture_bin" remove-barrier "$record_one" "$cas_line" &
  cas_remove_pid=$!
  FIXTURE_PIDS+=("$cas_remove_pid")
  for _attempt in $(seq 1 100); do
    [[ -e "$cas_ready" ]] && break
    sleep 0.02
  done
  [[ -e "$cas_ready" ]] || {
    echo "process-record CAS remover did not reach its deterministic barrier" >&2
    return 1
  }
  sleep 60 &
  replacement_pid=$!
  FIXTURE_PIDS+=("$replacement_pid")
  replacement_start="$(proc_start_field_22 "$replacement_pid")"
  replacement_line="$(printf 'v1\t%s\t%s\t%s' "$replacement_pid" "$replacement_start" "$instance_one")"
  env XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" write "$record_one" "$replacement_pid" "$instance_one" &
  cas_writer_pid=$!
  FIXTURE_PIDS+=("$cas_writer_pid")
  sleep 0.1
  if kill -0 "$cas_writer_pid" 2>/dev/null && [[ "$(cat "$record_one")" == "$cas_line" ]]; then
    writer_blocked=1
  else
    writer_blocked=0
  fi
  : > "$cas_release"
  set +e
  wait "$cas_remove_pid"; cas_remove_rc=$?
  wait "$cas_writer_pid"; cas_writer_rc=$?
  set -e
  assert "CAS publisher waits behind matching removal" [ "$writer_blocked" -eq 1 ]
  assert "CAS remover consumes only the original line" [ "$cas_remove_rc" -eq 0 ]
  assert "CAS publisher succeeds after matching removal" [ "$cas_writer_rc" -eq 0 ]
  assert "replacement preserved" [ "$(cat "$record_one")" = "$replacement_line" ]
  XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$record_one" "$instance_one" >/dev/null
  assert "process lock FD closes before bwrap/gateway child boundary" \
    env XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" write-then-child "$record_one" "$replacement_pid" "$instance_one"
  rm -f -- "$cas_ready" "$cas_release" "$record_one"
  kill "$replacement_pid" 2>/dev/null || true
  wait "$replacement_pid" 2>/dev/null || true
  kill "$cas_pid"
  wait "$cas_pid" 2>/dev/null || true
  assert "atomic writes leave no temporary record" \
    test -z "$(find "$runtime_dir" -maxdepth 1 -name '.process-record.*' -print -quit)"

  one_out="$(build_backend runtime-one bubblewrap 2>&1)" || {
    echo "$one_out" >&2
    return 1
  }
  one_store="${one_out##*$'\n'}"
  one_bin="$one_store/bin/runtime-one"
  two_out="$(build_backend runtime-two bubblewrap 2>&1)" || {
    echo "$two_out" >&2
    return 1
  }
  two_store="${two_out##*$'\n'}"
  two_bin="$two_store/bin/runtime-two"
  project_dir="$TMPDIR/runtime-project"
  mkdir -p "$project_dir"
  launcher_instance_one="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" digest "sandbox:runtime-one" "$state_base/runtime-one")"
  launcher_instance_two="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" digest "sandbox:runtime-two" "$state_base/runtime-two")"
  launcher_record_one="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" path "sandbox:runtime-one" "$state_base/runtime-one")"
  launcher_record_two="$(XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" path "sandbox:runtime-two" "$state_base/runtime-two")"

  (cd "$project_dir" && exec env XDG_RUNTIME_DIR="$xdg_parent" OCSB_STATE_BASE_DIR="$state_base" \
    "$one_bin" -w runtime-one --strategy direct --overwrite -- -c 'sleep 60') \
    >"$TMPDIR/runtime-one.log" 2>&1 &
  job_one=$!
  FIXTURE_PIDS+=("$job_one")
  (cd "$project_dir" && exec env XDG_RUNTIME_DIR="$xdg_parent" OCSB_STATE_BASE_DIR="$state_base" \
    "$two_bin" -w runtime-two --strategy direct --overwrite -- -c 'sleep 60') \
    >"$TMPDIR/runtime-two.log" 2>&1 &
  job_two=$!
  FIXTURE_PIDS+=("$job_two")

  if ! wait_for_record "$launcher_record_one" "$job_one" || ! wait_for_record "$launcher_record_two" "$job_two"; then
    cat "$TMPDIR/runtime-one.log" "$TMPDIR/runtime-two.log" >&2
    return 1
  fi
  assert "concurrent launchers use distinct process record names" \
    [ "$launcher_record_one" != "$launcher_record_two" ]
  XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$launcher_record_one" "$launcher_instance_one" >/dev/null
  XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" validate "$launcher_record_two" "$launcher_instance_two" >/dev/null
  launcher_line_one="$(cat "$launcher_record_one")"
  launcher_line_two="$(cat "$launcher_record_two")"
  IFS=$'\t' read -r tag launcher_pid_one launcher_start_one launcher_record_instance_one <<<"$launcher_line_one"
  IFS=$'\t' read -r tag launcher_pid_two launcher_start_two launcher_record_instance_two <<<"$launcher_line_two"
  assert "runtime-one record identifies its outer bwrap" [ "$launcher_pid_one" = "$job_one" ]
  assert "runtime-two record identifies its outer bwrap" [ "$launcher_pid_two" = "$job_two" ]

  kill "$launcher_pid_one" "$launcher_pid_two"
  wait "$job_one" 2>/dev/null || true
  wait "$job_two" 2>/dev/null || true
  assert_fails "saved runtime-one PID is dead after cleanup" kill -0 "$launcher_pid_one"
  assert_fails "saved runtime-two PID is dead after cleanup" kill -0 "$launcher_pid_two"
  XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" remove "$launcher_record_one" "$launcher_line_one"
  XDG_RUNTIME_DIR="$xdg_parent" "$fixture_bin" remove "$launcher_record_two" "$launcher_line_two"
  assert "controlled runtime has no process records" \
    test -z "$(find "$runtime_dir" -maxdepth 1 -name 'process-*.pid' -print -quit)"
  rm -rf "$runtime_dir" "$fallback_runtime"
  FIXTURE_PIDS=()

  if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS[GREEN-process-record-cas]: replacement preserved; lock-fd-closed"
    echo "PASS[GREEN-process-record-schema]: strict v1 process records validated"
    echo "CLEANUP PASS: runtime record fixtures"
    return 0
  fi
  return 1
}

write_rootfs_fake_backend() {
  local path="$1"

  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

backend="${FAKE_ROOTFS_BACKEND:?missing fake backend name}"

if [[ "$backend" == podman && "${1:-}" == --remote=false && "${2:-}" == unshare ]]; then
  shift 2
  helper="${1:?fake podman unshare requires a helper}"
  shift
  if [[ "$(id -u)" -ne 0 ]]; then
    exec unshare --user --map-root-user -- "$helper" "$@"
  fi
  exec "$helper" "$@"
fi

rootfs=""
data=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote=false|run|--rm|--userns=keep-id|--user|--workdir|--quiet|--machine|--user|--chdir)
      if [[ "$1" == --user || "$1" == --workdir ]]; then
        shift 2
      else
        shift
      fi
      ;;
    --rootfs)
      rootfs="${2:?missing rootfs path}"
      shift 2
      ;;
    --directory=*)
      rootfs="${1#--directory=}"
      shift
      ;;
    --volume)
      mount_spec="${2:?missing podman volume}"
      mount_source="${mount_spec%%:*}"
      mount_destination_and_mode="${mount_spec#*:}"
      if [[ "${mount_destination_and_mode%%:*}" == /data ]]; then
        data="$mount_source"
      fi
      shift 2
      ;;
    --bind=*)
      mount_spec="${1#--bind=}"
      mount_source="${mount_spec%%:*}"
      mount_destination="${mount_spec#*:}"
      if [[ "$mount_destination" == /data ]]; then
        data="$mount_source"
      fi
      shift
      ;;
    --private-network|--setenv=*|--bind-ro=*)
      shift
      ;;
    --)
      break
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$rootfs" ]] || {
  echo "fake-rootfs: missing rootfs for $backend" >&2
  exit 64
}
[[ -n "$data" ]] || {
  echo "fake-rootfs: missing explicit /data mount for $backend" >&2
  exit 64
}

rootfs_state=absent
home_state=absent
external_state=absent
[[ -e "$rootfs/tmp/ocsb-sentinel" ]] && rootfs_state=present
[[ -e "$rootfs/home/sandbox/ocsb-home-sentinel" ]] && home_state=present
[[ -e "$data/ocsb-external-sentinel" ]] && external_state=present
printf 'fake-rootfs backend=%s rootfs=%s home=%s external=%s\n' \
  "$backend" "$rootfs_state" "$home_state" "$external_state"

mkdir -p "$rootfs/tmp" "$rootfs/home/sandbox" "$data"
printf '%s\n' "$backend" > "$rootfs/tmp/ocsb-sentinel"
printf '%s\n' "$backend" > "$rootfs/home/sandbox/ocsb-home-sentinel"
printf '%s\n' "$backend" > "$data/ocsb-external-sentinel"

if [[ "$rootfs_state" == present || "$home_state" == present ]]; then
  exit 42
fi
EOF
  chmod 0755 "$path"
}

run_rootfs_fake_backend() {
  local backend="$1"
  local launcher="$2"
  local project="$3"
  local state_base="$4"
  local runtime="$5"
  local fake_bin="$6"
  local data="$7"
  local workspace="$8"
  local lifecycle="$9"

  (
    cd "$project"
    export PATH="$fake_bin:$PATH"
    export XDG_RUNTIME_DIR="$runtime"
    export OCSB_STATE_BASE_DIR="$state_base"
    export FAKE_ROOTFS_BACKEND="$backend"
    if [[ "$backend" == systemd-nspawn ]]; then
      if [[ "$(id -u)" -eq 0 ]]; then
        "$launcher" -w "$workspace" --strategy direct "$lifecycle" --rw "$data:/data" -- -c true
      else
        unshare --user --map-current-user --mount --keep-caps --fork -- \
          "$launcher" -w "$workspace" --strategy direct "$lifecycle" --rw "$data:/data" -- -c true
      fi
    else
      "$launcher" -w "$workspace" --strategy direct "$lifecycle" --rw "$data:/data" -- -c true
    fi
  )
}

rootfs_fake_report() {
  local backend="$1"
  local output="$2"

  grep -E "^fake-rootfs backend=$backend rootfs=(present|absent) home=(present|absent) external=(present|absent)$" \
    <<<"$output" | tail -n 1
}

rootfs_fake_field() {
  local report="$1"
  local field="$2"
  local value

  value="${report#*"${field}="}"
  printf '%s\n' "${value%% *}"
}

rootfs_fake_layout_is_safe() {
  local rootfs="$1"
  local state_dir

  state_dir="${rootfs%/rootfs}"
  [[ "$state_dir" != "$rootfs" && ! -L "$state_dir" && -d "$state_dir" ]] || return 1
  [[ "$(realpath -e -- "$state_dir")" == "$state_dir" ]] || return 1
  [[ "$(stat -c %u -- "$state_dir")" == "$(id -u)" ]] || return 1
  [[ "$(stat -c %a -- "$state_dir")" == 700 ]] || return 1
  [[ ! -L "$rootfs" && -d "$rootfs" ]] || return 1
  [[ "$(realpath -e -- "$rootfs")" == "$rootfs" ]] || return 1
  [[ "$(stat -c %u -- "$rootfs")" == "$(id -u)" ]] || return 1
  [[ "$(stat -c %a -- "$rootfs")" == 700 ]] || return 1
  [[ -d "$rootfs/usr/bin" && -d "$rootfs/usr/lib" && -d "$rootfs/usr/lib64" ]] || return 1
  [[ -d "$rootfs/nix/store" && -d "$rootfs/nix/var/nix" && -d "$rootfs/workspace" ]] || return 1
  [[ -d "$rootfs/home/sandbox/.config" && -d "$rootfs/home/sandbox/.local" ]] || return 1
  [[ -d "$rootfs/run" && -d "$rootfs/var/lib/postgresql" && -d "$rootfs/etc" ]] || return 1
  [[ "$(stat -c %a -- "$rootfs/tmp")" == 1777 ]] || return 1
  [[ -L "$rootfs/bin" && "$(readlink -- "$rootfs/bin")" == usr/bin ]] || return 1
  [[ -L "$rootfs/lib" && "$(readlink -- "$rootfs/lib")" == usr/lib ]] || return 1
  [[ -L "$rootfs/lib64" && "$(readlink -- "$rootfs/lib64")" == usr/lib64 ]] || return 1
}

container_rootfs_persistence_case() {
  local podman_out nspawn_out podman_store nspawn_store podman_bin nspawn_bin
  local fixture project state_base runtime fake_bin data podman_workspace nspawn_workspace
  local podman_first podman_second nspawn_first nspawn_second
  local podman_first_rc podman_second_rc nspawn_first_rc nspawn_second_rc
  local podman_report nspawn_report podman_rootfs podman_home podman_external
  local nspawn_rootfs nspawn_home nspawn_external
  local podman_layout_safe=0 nspawn_layout_safe=0

  podman_out="$(build_backend_expr rootfs-podman '{ backend.type = "podman"; experimental.nixStoreMode = "closure"; }' 2>&1)" || {
    echo "$podman_out" >&2
    return 1
  }
  podman_store="${podman_out##*$'\n'}"
  podman_bin="$podman_store/bin/rootfs-podman"

  nspawn_out="$(build_backend_expr rootfs-nspawn '{ backend.type = "systemd-nspawn"; experimental.nixStoreMode = "closure"; }' 2>&1)" || {
    echo "$nspawn_out" >&2
    return 1
  }
  nspawn_store="${nspawn_out##*$'\n'}"
  nspawn_bin="$nspawn_store/bin/rootfs-nspawn"

  fixture="$TMPDIR/rootfs-fake-runtime"
  project="$fixture/project"
  state_base="$fixture/state"
  runtime="$fixture/runtime"
  fake_bin="$fixture/fake-bin"
  data="$fixture/data"
  podman_workspace="rootfs-podman"
  nspawn_workspace="rootfs-nspawn"
  install -d -m 0700 "$project" "$state_base" "$runtime" "$fake_bin" "$data/podman" "$data/nspawn"
  write_rootfs_fake_backend "$fake_bin/podman"
  write_rootfs_fake_backend "$fake_bin/systemd-nspawn"

  podman_first="$(run_rootfs_fake_backend podman "$podman_bin" "$project" "$state_base" "$runtime" "$fake_bin" "$data/podman" "$podman_workspace" --overwrite 2>&1)" && podman_first_rc=0 || podman_first_rc=$?
  podman_second="$(run_rootfs_fake_backend podman "$podman_bin" "$project" "$state_base" "$runtime" "$fake_bin" "$data/podman" "$podman_workspace" --continue 2>&1)" && podman_second_rc=0 || podman_second_rc=$?
  nspawn_first="$(run_rootfs_fake_backend systemd-nspawn "$nspawn_bin" "$project" "$state_base" "$runtime" "$fake_bin" "$data/nspawn" "$nspawn_workspace" --overwrite 2>&1)" && nspawn_first_rc=0 || nspawn_first_rc=$?
  nspawn_second="$(run_rootfs_fake_backend systemd-nspawn "$nspawn_bin" "$project" "$state_base" "$runtime" "$fake_bin" "$data/nspawn" "$nspawn_workspace" --continue 2>&1)" && nspawn_second_rc=0 || nspawn_second_rc=$?

  podman_report="$(rootfs_fake_report podman "$podman_second")"
  nspawn_report="$(rootfs_fake_report systemd-nspawn "$nspawn_second")"
  podman_rootfs="$(rootfs_fake_field "$podman_report" rootfs)"
  podman_home="$(rootfs_fake_field "$podman_report" home)"
  podman_external="$(rootfs_fake_field "$podman_report" external)"
  nspawn_rootfs="$(rootfs_fake_field "$nspawn_report" rootfs)"
  nspawn_home="$(rootfs_fake_field "$nspawn_report" home)"
  nspawn_external="$(rootfs_fake_field "$nspawn_report" external)"
  rootfs_fake_layout_is_safe "$state_base/$podman_workspace/rootfs" && podman_layout_safe=1
  rootfs_fake_layout_is_safe "$state_base/$nspawn_workspace/rootfs" && nspawn_layout_safe=1

  if [[ "$podman_first_rc" -ne 0 || "$nspawn_first_rc" -ne 0 ]]; then
    printf '%s\n%s\n' "$podman_first" "$nspawn_first" >&2
    return 1
  fi

  if [[ "$podman_rootfs" == present && "$nspawn_rootfs" == present ]]; then
    printf '%s\n' 'FAIL[RED-container-rootfs-persistence]: podman=present nspawn=present'
    printf '%s\n%s\n' "$podman_second" "$nspawn_second" >&2
    return 1
  fi

  if [[ "$podman_second_rc" -ne 0 || "$nspawn_second_rc" -ne 0 ||
        "$podman_rootfs" != absent || "$nspawn_rootfs" != absent ||
        "$podman_home" != absent || "$nspawn_home" != absent ||
        "$podman_external" != present || "$nspawn_external" != present ]]; then
    printf '%s\n%s\n' "$podman_second" "$nspawn_second" >&2
    return 1
  fi

  if [[ "$podman_layout_safe" -ne 1 || "$nspawn_layout_safe" -ne 1 ||
        ! -f "$data/podman/ocsb-external-sentinel" ||
        ! -f "$data/nspawn/ocsb-external-sentinel" ]]; then
    echo "container rootfs safety layout or explicit mounted state check failed" >&2
    return 1
  fi

  rm -rf -- "$fixture"
  if [[ -e "$fixture" || -L "$fixture" || "${#FIXTURE_PIDS[@]}" -ne 0 ||
        -n "$(find "$TMPDIR" -maxdepth 1 -name 'result*' -print -quit)" ]]; then
    echo "rootfs fake runtime cleanup failed" >&2
    return 1
  fi

  printf '%s\n' 'PASS[GREEN-container-rootfs-persistence]: podman=absent nspawn=absent'
  printf '%s\n' 'CLEANUP PASS: rootfs fake runtime'
}

generic_daemon_pip_case() {
  local fixture_out fixture_store fixture_bin launcher_text supervisor_text
  local fixture project state_base runtime daemon_marker foreground_marker
  local foreground_command run_output run_rc daemon_marker_count=0 missing_marker
  local source_coupled=0 markers_reached=0 cleanup_ok=0 count_rejects_missing=0

  fixture="$TMPDIR/generic-daemon-pip"
  project="$fixture/project"
  state_base="$fixture/state"
  runtime="$fixture/runtime"
  daemon_marker="$project/daemon.marker"
  foreground_marker="$project/foreground.marker"
  install -d -m 0700 "$project" "$project/home" "$state_base" "$runtime"
  printf '%s\n' 'pip==0' > "$project/pip-constraint.txt"

  fixture_out="$(build_generic_daemon_fixture 2>&1)" || {
    echo "$fixture_out" >&2
    return 1
  }
  fixture_store="${fixture_out##*$'\n'}"
  fixture_bin="$fixture_store/bin/generic-daemon-pip-fixture"
  launcher_text="$(read_launcher_text "$fixture_bin")"
  supervisor_text="$(read_generic_daemon_supervisor "$launcher_text")" || return 1

  if supervisor_has_hermes_pip_coupling "$supervisor_text"; then
    source_coupled=1
  fi

  foreground_command='
    for _attempt in $(seq 1 100); do
      if [[ -f "$OCSB_DAEMON_MARKER" ]] && [[ $(wc -l < "$OCSB_DAEMON_MARKER") -ge 2 ]]; then
        printf "%s\\n" "GENERIC_FOREGROUND_MARKER" > "$OCSB_FOREGROUND_MARKER"
        exit 0
      fi
      sleep 0.05
    done
    exit 1
  '
  run_output="$(
    cd "$project"
    timeout 15s "$fixture_bin" -w generic-daemon-pip --strategy direct --overwrite -- \
      -c "$foreground_command" 2>&1
  )" && run_rc=0 || run_rc=$?

  if [[ -f "$daemon_marker" ]]; then
    daemon_marker_count="$(awk '$0 == "GENERIC_DAEMON_MARKER" { count++ } END { print count + 0 }' "$daemon_marker")"
  fi
  missing_marker="$TMPDIR/generic-daemon-pip-missing.marker"
  rm -f -- "$missing_marker"
  if awk '$0 == "GENERIC_DAEMON_MARKER" { count++ } END { print count + 0 }' "$missing_marker" >/dev/null 2>&1; then
    count_rejects_missing=0
  else
    count_rejects_missing=1
  fi
  if [[ "$daemon_marker_count" -ge 2 && -f "$foreground_marker" &&
        "$(cat "$foreground_marker")" == "GENERIC_FOREGROUND_MARKER" ]]; then
    markers_reached=1
  fi

  rm -f -- "$TMPDIR/generic-daemon-pip-fixture.nix"
  rm -rf -- "$fixture"
  if [[ ! -e "$fixture" && ! -L "$fixture" &&
        ! -e "$TMPDIR/generic-daemon-pip-fixture.nix" &&
        -z "$(find "$TMPDIR" -maxdepth 1 -name 'result*' -print -quit)" ]]; then
    cleanup_ok=1
  fi
  if [[ "$cleanup_ok" -ne 1 ]]; then
    echo "generic daemon fixture cleanup failed" >&2
    return 1
  fi

  if [[ "$source_coupled" -eq 1 && "$markers_reached" -ne 1 ]]; then
    printf '%s\n' 'FAIL[RED-generic-daemon-pip]: supervisor contains Hermes venv or pip'
    printf '%s\n' "$run_output" >&2
    printf '%s\n' 'CLEANUP PASS: generic daemon fixture'
    return 1
  fi

  if [[ "$source_coupled" -ne 0 ]]; then
    echo "generic daemon supervisor remains Hermes/Python-coupled" >&2
    return 1
  fi
  if [[ "$run_rc" -ne 0 || "$markers_reached" -ne 1 ]]; then
    printf '%s\n' "$run_output" >&2
    echo "generic daemon offline fixture did not reach both markers" >&2
    return 1
  fi
  if [[ "$count_rejects_missing" -ne 1 ]]; then
    echo 'generic daemon marker counter accepted a missing producer' >&2
    return 1
  fi

  printf 'offline markers: GENERIC_DAEMON_MARKER count=%s; GENERIC_FOREGROUND_MARKER\n' "$daemon_marker_count"
  printf '%s\n' 'PASS[GREEN-backend-count-swallow]: missing producer is not fail-swallowed'
  printf '%s\n' 'PASS[GREEN-generic-daemon-pip]: source clean; offline daemon and foreground markers present'
  printf '%s\n' 'CLEANUP PASS: generic daemon fixture'
}

if [[ "$TEST_CASE" != "all" ]]; then
  case "$TEST_CASE" in
    process-record-schema)
      process_record_schema_case
      ;;
    container-rootfs-persistence)
      container_rootfs_persistence_case
      ;;
    generic-daemon-pip)
      generic_daemon_pip_case
      ;;
    *)
      echo "unknown test case: $TEST_CASE" >&2
      exit 2
      ;;
  esac
  echo ""
  echo "=== backend Results: $PASS passed, $FAIL failed ==="
  [[ "$FAIL" -eq 0 ]]
  exit
fi

PODMAN_OUT="$(build_backend test-podman-backend podman 2>&1)" || {
  echo "$PODMAN_OUT" >&2
  exit 1
}
PODMAN_STORE="${PODMAN_OUT##*$'\n'}"
PODMAN_BIN="$PODMAN_STORE/bin/test-podman-backend"
PODMAN_TEXT="$(read_launcher_text "$PODMAN_BIN")"

assert_contains "podman launcher records backend" "$PODMAN_TEXT" "BACKEND_TYPE=podman"
assert_contains "podman launcher delegates through mount anchor" "$PODMAN_TEXT" \
  "build_mount_anchor_helper_args podman current PODMAN_BACKEND_ARGV"
assert_contains "podman launcher uses keep-id" "$PODMAN_TEXT" "--userns=keep-id"
assert_contains "podman launcher rejects extra host sources" "$PODMAN_TEXT" \
  "backend.podman.extraArgs cannot add host path sources"
assert_contains "container rootfs requires the held workspace lock" "$PODMAN_TEXT" \
  "container rootfs preparation requires the workspace lock on FD 9"
assert_contains "container rootfs validates canonical state" "$PODMAN_TEXT" \
  '"$CONTAINER_ROOTFS_ACCESS" != "$_state_real/rootfs"'
assert_contains "container rootfs rejects unsafe rootfs links" "$PODMAN_TEXT" \
  'unsafe container rootfs path: $CONTAINER_ROOTFS is not a non-symlink directory'
assert_contains "container rootfs deletion stays on its filesystem" "$PODMAN_TEXT" \
  'rm -rf --one-file-system -- "$CONTAINER_ROOTFS_ACCESS"'
assert_contains "container rootfs rebuilds sticky temporary storage" "$PODMAN_TEXT" \
  'chmod 1777 -- "$CONTAINER_ROOTFS_ACCESS/tmp"'
assert_contains "attach resets root into sandbox filesystem" "$PODMAN_TEXT" "-r --wdns=/"
assert_contains "attach requires the matching typed process record" "$PODMAN_TEXT" 'ocsb_validate_process_record "$OCSB_PROCESS_RECORD" "$OCSB_INSTANCE"'
assert_contains "attach process record rejects legacy formats" "$PODMAN_TEXT" '_record_re="^v1${_tab}([1-9][0-9]*)${_tab}([1-9][0-9]*)${_tab}([0-9a-f]{64})$"'
assert_contains "attach validates bwrap comm" "$PODMAN_TEXT" 'proc_comm "$_candidate_pid"'
assert_contains "explicit attach accepts only recorded outer or resolved init" "$PODMAN_TEXT" '"$ATTACH_TARGET" != "$_BWRAP_PID" && "$ATTACH_TARGET" != "$_INIT_PID"'
assert_contains "attach rejects ambiguous init children" "$PODMAN_TEXT" "has multiple sandbox-init children"
assert_contains "attach records process identity before filtered bwrap exec" "$PODMAN_TEXT" $'record_attach_process\n      exec ${pkgs.bubblewrap}/bin/bwrap \\'
assert_contains "attach records process identity before simple bwrap exec" "$PODMAN_TEXT" 'record_attach_process
      exec ${pkgs.bubblewrap}/bin/bwrap "'
assert_contains "attach keeps pidfile while sandbox is still starting" "$PODMAN_TEXT" '_ATTACH_STALE=1'
assert_contains "attach retries while bwrap child starts" "$PODMAN_TEXT" 'while [[ $_ATTACH_TRIES -lt 20 ]]; do'
assert_contains "attach wraps payload with env capture" "$PODMAN_TEXT" "env-capture"
assert_contains "attach shell sources captured environment" "$PODMAN_TEXT" 'source /tmp/ocsb-attach.env'
assert_contains "attach starts shell with clean host env" "$PODMAN_TEXT" "env -i"

NSPAWN_OUT="$(build_backend test-nspawn-backend systemd-nspawn 2>&1)" || {
  echo "$NSPAWN_OUT" >&2
  exit 1
}
NSPAWN_STORE="${NSPAWN_OUT##*$'\n'}"
NSPAWN_BIN="$NSPAWN_STORE/bin/test-nspawn-backend"
NSPAWN_TEXT="$(read_launcher_text "$NSPAWN_BIN")"

assert_contains "nspawn launcher records backend" "$NSPAWN_TEXT" "BACKEND_TYPE=systemd-nspawn"
assert_contains "nspawn launcher delegates through mount anchor" "$NSPAWN_TEXT" \
  "build_mount_anchor_helper_args systemd-nspawn current NSPAWN_BACKEND_ARGV"
assert_contains "nspawn launcher rejects filtered network" "$NSPAWN_TEXT" "supports only host or blocked networking"
assert_contains "nspawn launcher preserves caller uid" "$NSPAWN_TEXT" '--user="$HOST_UID"'
assert_contains "nspawn launcher rejects extra host sources" "$NSPAWN_TEXT" \
  "backend.systemdNspawn.extraArgs cannot add host path sources"

NSPAWN_FILTERED_OUT="$(build_backend_expr test-nspawn-filtered '{ backend.type = "systemd-nspawn"; network.enable = true; }' 2>&1)" || {
  echo "$NSPAWN_FILTERED_OUT" >&2
  exit 1
}
NSPAWN_FILTERED_STORE="${NSPAWN_FILTERED_OUT##*$'\n'}"
NSPAWN_FILTERED_BIN="$NSPAWN_FILTERED_STORE/bin/test-nspawn-filtered"

DUAL_OUT="$(build_backend_expr test-podman-dual '{ backend.type = "podman"; experimental.dualLayer = true; }' 2>&1)" || {
  echo "$DUAL_OUT" >&2
  exit 1
}
DUAL_STORE="${DUAL_OUT##*$'\n'}"
DUAL_BIN="$DUAL_STORE/bin/test-podman-dual"

PODMAN_UNSAFE_OUT="$(build_backend_expr test-podman-unsafe-extra '{ backend.type = "podman"; backend.podman.extraArgs = [ "--volumes-from=attacker" ]; }' 2>&1)" || {
  echo "$PODMAN_UNSAFE_OUT" >&2
  exit 1
}
PODMAN_UNSAFE_STORE="${PODMAN_UNSAFE_OUT##*$'\n'}"
PODMAN_UNSAFE_BIN="$PODMAN_UNSAFE_STORE/bin/test-podman-unsafe-extra"

NSPAWN_UNSAFE_OUT="$(build_backend_expr test-nspawn-unsafe-extra '{ backend.type = "systemd-nspawn"; backend.systemdNspawn.extraArgs = [ "--directory=/tmp/attacker" ]; }' 2>&1)" || {
  echo "$NSPAWN_UNSAFE_OUT" >&2
  exit 1
}
NSPAWN_UNSAFE_STORE="${NSPAWN_UNSAFE_OUT##*$'\n'}"
NSPAWN_UNSAFE_BIN="$NSPAWN_UNSAFE_STORE/bin/test-nspawn-unsafe-extra"

PROJECT_DIR="$TMPDIR/project"
mkdir -p "$PROJECT_DIR"
FAKE_BACKEND_DIR="$TMPDIR/fake-backends"
mkdir -p "$FAKE_BACKEND_DIR"
printf '#!/bin/sh\nexit 99\n' > "$FAKE_BACKEND_DIR/podman"
printf '#!/bin/sh\nexit 99\n' > "$FAKE_BACKEND_DIR/systemd-nspawn"
chmod 0755 "$FAKE_BACKEND_DIR/podman" "$FAKE_BACKEND_DIR/systemd-nspawn"

RUN_OUTPUT="$(cd "$PROJECT_DIR" && OCSB_STATE_BASE_DIR="$TMPDIR/state" "$PODMAN_BIN" --backend podman --strategy overlayfs -- -c true 2>&1)" && RUN_EXIT=0 || RUN_EXIT=$?
assert "podman overlayfs runtime rejection exits non-zero" [ "$RUN_EXIT" -ne 0 ]
assert_contains "podman overlayfs rejection explains boundary" "$RUN_OUTPUT" "does not support workspace.strategy=overlayfs"

RUN_OUTPUT2="$(cd "$PROJECT_DIR" && OCSB_STATE_BASE_DIR="$TMPDIR/state" "$NSPAWN_BIN" --backend systemd-nspawn --strategy overlayfs -- -c true 2>&1)" && RUN_EXIT2=0 || RUN_EXIT2=$?
assert "nspawn overlayfs runtime rejection exits non-zero" [ "$RUN_EXIT2" -ne 0 ]
assert_contains "nspawn overlayfs rejection explains boundary" "$RUN_OUTPUT2" "does not support workspace.strategy=overlayfs"

mkdir -p "$PROJECT_DIR/ovl-src"
RUN_OUTPUT3="$(cd "$PROJECT_DIR" && OCSB_STATE_BASE_DIR="$TMPDIR/state" "$PODMAN_BIN" --backend podman --strategy direct --overlay-mount "$PROJECT_DIR/ovl-src:/workspace/ovl" -- -c true 2>&1)" && RUN_EXIT3=0 || RUN_EXIT3=$?
assert "podman overlay-mount runtime rejection exits non-zero" [ "$RUN_EXIT3" -ne 0 ]
assert_contains "podman overlay-mount rejection explains boundary" "$RUN_OUTPUT3" "does not support --overlay-mount"

RUN_OUTPUT4="$(cd "$PROJECT_DIR" && OCSB_STATE_BASE_DIR="$TMPDIR/state" "$DUAL_BIN" --backend podman --strategy direct -- -c true 2>&1)" && RUN_EXIT4=0 || RUN_EXIT4=$?
assert "podman dual-layer runtime rejection exits non-zero" [ "$RUN_EXIT4" -ne 0 ]
assert_contains "podman dual-layer rejection explains boundary" "$RUN_OUTPUT4" "experimental.dualLayer is bubblewrap-only"

RUN_OUTPUT5="$(cd "$PROJECT_DIR" && OCSB_STATE_BASE_DIR="$TMPDIR/state" "$NSPAWN_FILTERED_BIN" --backend systemd-nspawn --strategy direct -- -c true 2>&1)" && RUN_EXIT5=0 || RUN_EXIT5=$?
assert "nspawn filtered runtime rejection exits non-zero" [ "$RUN_EXIT5" -ne 0 ]
assert_contains "nspawn filtered rejection explains boundary" "$RUN_OUTPUT5" "supports only host or blocked networking"

RUN_OUTPUT_UNSAFE_PODMAN="$(cd "$PROJECT_DIR" && PATH="$FAKE_BACKEND_DIR:$PATH" OCSB_STATE_BASE_DIR="$TMPDIR/state" "$PODMAN_UNSAFE_BIN" --strategy direct --overwrite -- -c true 2>&1)" && RUN_EXIT_UNSAFE_PODMAN=0 || RUN_EXIT_UNSAFE_PODMAN=$?
assert "podman extra host source rejection exits non-zero" [ "$RUN_EXIT_UNSAFE_PODMAN" -ne 0 ]
assert_contains "podman volumes-from source is refused" "$RUN_OUTPUT_UNSAFE_PODMAN" "backend.podman.extraArgs cannot add host path sources"

RUN_OUTPUT_UNSAFE_NSPAWN="$(cd "$PROJECT_DIR" && PATH="$FAKE_BACKEND_DIR:$PATH" OCSB_STATE_BASE_DIR="$TMPDIR/state" "$NSPAWN_UNSAFE_BIN" --strategy direct --overwrite -- -c true 2>&1)" && RUN_EXIT_UNSAFE_NSPAWN=0 || RUN_EXIT_UNSAFE_NSPAWN=$?
assert "nspawn extra host source rejection exits non-zero" [ "$RUN_EXIT_UNSAFE_NSPAWN" -ne 0 ]
assert_contains "nspawn alternate directory source is refused" "$RUN_OUTPUT_UNSAFE_NSPAWN" "backend.systemdNspawn.extraArgs cannot add host path sources"

OCSB_STATE_BASE_DIR="$TMPDIR/state" "$PODMAN_BIN" --backend bubblewrap -w backend-mismatch --strategy direct --overwrite -- -c true >/dev/null
RUN_OUTPUT6="$(cd "$PROJECT_DIR" && OCSB_STATE_BASE_DIR="$TMPDIR/state" "$PODMAN_BIN" --backend podman -w backend-mismatch --strategy direct --continue -- -c true 2>&1)" && RUN_EXIT6=0 || RUN_EXIT6=$?
assert "backend mismatch continue exits non-zero" [ "$RUN_EXIT6" -ne 0 ]
assert_contains "backend mismatch explains original backend" "$RUN_OUTPUT6" "was created with backend 'bubblewrap'"

echo ""
echo "=== backend Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
