#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ONLY=0
TEST_CASE="all"
BUILD_LIGHTWEIGHT_WRAPPER=0
BUILD_SERVICE_FIXTURE=0
BUILD_FIXTURE_DIR=""

if [[ "${1:-}" == "--build-lightweight-wrapper" || "${1:-}" == "--build-service-fixture" ]]; then
  [[ $# -eq 2 ]] || {
    echo "Usage: $0 --build-lightweight-wrapper|--build-service-fixture <fixture-dir>" >&2
    exit 2
  }
  if [[ "$1" == "--build-lightweight-wrapper" ]]; then
    BUILD_LIGHTWEIGHT_WRAPPER=1
  else
    BUILD_SERVICE_FIXTURE=1
  fi
  BUILD_FIXTURE_DIR="$2"
  shift 2
fi

if [[ "${1:-}" == "--source-only" ]]; then
  SOURCE_ONLY=1
  shift
fi

if [[ "${1:-}" == "--case" ]]; then
  [[ $# -ge 2 ]] || {
    echo "Usage: $0 [--source-only] [--case NAME] <path-to-ocsb-hermes-binary>" >&2
    exit 2
  }
  TEST_CASE="$2"
  shift 2
fi

WRAPPER="${1:-}"
if [[ "$BUILD_LIGHTWEIGHT_WRAPPER" -eq 1 || "$BUILD_SERVICE_FIXTURE" -eq 1 ]]; then
  [[ "$SOURCE_ONLY" == "0" && "$TEST_CASE" == "all" && $# -eq 0 ]] || {
    echo "fixture builders cannot be combined with test arguments" >&2
    exit 2
  }
elif [[ "$SOURCE_ONLY" != "1" && -z "$WRAPPER" ]]; then
  echo "Usage: $0 [--source-only] [--case NAME] <path-to-ocsb-hermes-binary>" >&2
  exit 2
fi

build_lightweight_wrapper() {
  local fixture_dir="$1"
  local fixture_out fixture_store

  if [[ -e "$fixture_dir" ]] && [[ -n "$(find "$fixture_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "fixture directory must be empty: $fixture_dir" >&2
    return 1
  fi
  install -d -m 0700 "$fixture_dir"

  fixture_out="$(
    OCSB_TEST_REPO_ROOT="$REPO_ROOT" nix build --no-link --print-out-paths --impure \
      --expr "
        let
          repo = builtins.getEnv \"OCSB_TEST_REPO_ROOT\";
          flake = builtins.getFlake (\"path:\" + repo);
          pkgs = import flake.inputs.nixpkgs { system = \"x86_64-linux\"; };
          fakeInner = pkgs.writeShellScriptBin \"hermes-agent\" ''
            set -euo pipefail
            if [[ -n \"''\${HERMES_FAKE_INNER_LOG:-}\" ]]; then
              printf '%s\\n' \"\$*\" >> \"\$HERMES_FAKE_INNER_LOG\"
            fi
          '';
        in pkgs.callPackage (builtins.toPath (repo + \"/scripts/hermes-wrapper.nix\")) {
          mkHermesAgentSandboxBase = fakeInner;
        }
      "
  )" || return 1
  fixture_store="${fixture_out##*$'\n'}"
  [[ -x "$fixture_store/bin/ocsb-hermes" ]] || {
    echo "lightweight wrapper build did not produce ocsb-hermes" >&2
    return 1
  }
  ln -s "$fixture_store/bin/ocsb-hermes" "$fixture_dir/ocsb-hermes"
  : > "$fixture_dir/.ocsb-hermes-lightweight-fixture"
  chmod 0600 "$fixture_dir/.ocsb-hermes-lightweight-fixture"
  printf '%s\n' "$fixture_dir/ocsb-hermes"
}

build_service_fixture() {
  local fixture_dir="$1"
  local fixture_expr fixture_out fixture_store

  if [[ -e "$fixture_dir" ]] && [[ -n "$(find "$fixture_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "fixture directory must be empty: $fixture_dir" >&2
    return 1
  fi
  install -d -m 0700 "$fixture_dir"
  fixture_expr="$fixture_dir/service-fixture.nix"
  cat > "$fixture_expr" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  fakeNohup = pkgs.writeShellScriptBin "nohup" ''
    set -euo pipefail
    fixture="''${OCSB_GATEWAY_FIXTURE_DIR:?}"
    candidate_on_term() {
      if [[ -e "$fixture/hold-candidate-term" ]]; then
        printf '%s\n' "$$" > "$fixture/candidate-term-seen.fifo"
        IFS= read -r _ < "$fixture/candidate-term-release.fifo"
      fi
      exit 0
    }
    trap candidate_on_term INT TERM
    marker="$fixture/spawn.$$"
    argv_file="$fixture/argv.$$"
    : > "$marker"
    chmod 0600 "$marker"
    printf '%q ' "$@" > "$argv_file"
    printf '\n' >> "$argv_file"
    chmod 0600 "$argv_file"
    printf 'spawn:%s\n' "$$" > "$fixture/event.fifo"
    if [[ -n "''${OCSB_GATEWAY_CANDIDATE_READY_FIFO:-}" ]]; then
      printf '%s\n' "$$" > "$OCSB_GATEWAY_CANDIDATE_READY_FIFO"
    fi

    if [[ -e "/proc/$$/fd/9" ]]; then
      : > "$fixture/candidate-lock-fd.$$"
    fi

    if [[ "$#" -eq 5 && "$2" == "gateway" && "$3" == "supervise" && \
          "$4" == "--candidate-token" && "$5" =~ ^[0-9a-f]{32}$ ]]; then
      printf '%s\n' "$5" > "$fixture/valid-candidate-argv.$$"
      chmod 0600 "$fixture/valid-candidate-argv.$$"
    fi
    if [[ -n "''${OCSB_GATEWAY_CANDIDATE_HELD_READY:-}" ]]; then
      : > "$OCSB_GATEWAY_CANDIDATE_HELD_READY"
      chmod 0600 "$OCSB_GATEWAY_CANDIDATE_HELD_READY"
    fi

    while [[ ! -e "$fixture/release" ]]; do
      IFS= read -r -t 1 _ < "$fixture/release.fifo" || true
    done
    : > "$fixture/released.$$"
    chmod 0600 "$fixture/released.$$"
    exec "$@"
  '';
  fakeHermes = pkgs.writeShellScriptBin "hermes" ''
    set -euo pipefail
    fixture="''${OCSB_GATEWAY_FIXTURE_DIR:?}"
    child_on_term() {
      if [[ -e "$fixture/hold-child-term" ]]; then
        printf '%s\n' "$$" > "$fixture/child-term-seen.fifo"
        IFS= read -r _ < "$fixture/child-term-release.fifo"
      fi
      exit 0
    }
    if [[ "$#" -ne 3 || "$1" != "gateway" || "$2" != "run" || "$3" != "--replace" ]]; then
      printf 'invalid hermes argv:' >&2
      printf ' %q' "$@" >&2
      printf '\n' >&2
      exit 64
    fi
    if [[ -e "/proc/$$/fd/9" ]]; then
      : > "$fixture/child-lock-fd.$$"
    fi
    : > "$fixture/gateway-start.$$"
    chmod 0600 "$fixture/gateway-start.$$"
    if [[ "''${OCSB_GATEWAY_DIE_AFTER_PUBLICATION:-0}" == "1" ]]; then
      : > "''${OCSB_GATEWAY_DEAD_CANDIDATE_READY:?}"
      # A non-catchable death after publication is the state transition that
      # start must refuse; a graceful TERM can leave the supervisor live long
      # enough to be a legitimate claim during its own cleanup.
      kill -KILL "$PPID"
      exit 0
    fi
    trap child_on_term INT TERM
    while true; do
      IFS= read -r -t 1 _ < "$fixture/child-exit.fifo" || true
    done
  '';
  fakeCandidateStartTime = pkgs.writeShellScriptBin "candidate-start-time" ''
    set -euo pipefail
    pid="''${1:?}"
    fixture="''${OCSB_GATEWAY_FIXTURE_DIR:?}"
    if [[ "''${OCSB_GATEWAY_FAIL_CANDIDATE_START_TIME:-0}" == "1" ]]; then
      ready_fifo="''${OCSB_GATEWAY_CANDIDATE_READY_FIFO:?}"
      IFS= read -r ready_pid < "$ready_fifo"
      [[ "$ready_pid" == "$pid" ]]
      printf '%s\n' "$pid" > "$fixture/start-time-capture-failed.$pid"
      chmod 0600 "$fixture/start-time-capture-failed.$pid"
      exit 1
    fi
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/stat" ]]
    IFS= read -r stat_line < "/proc/$pid/stat"
    stat_rest="''${stat_line##*) }"
    read -r -a stat_fields <<< "$stat_rest"
    [[ "''${stat_fields[19]:-}" =~ ^[1-9][0-9]*$ ]]
    printf '%s\n' "''${stat_fields[19]}"
  '';
  fakeChildStartTime = pkgs.writeShellScriptBin "child-start-time" ''
    set -euo pipefail
    pid="''${1:?}"
    fixture="''${OCSB_GATEWAY_FIXTURE_DIR:?}"
    if [[ "''${OCSB_GATEWAY_FAIL_CHILD_START_TIME:-0}" == "1" ]]; then
      printf '%s\n' "$pid" > "$fixture/child-start-time-capture-failed.$pid"
      chmod 0600 "$fixture/child-start-time-capture-failed.$pid"
      exit 1
    fi
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/stat" ]]
    IFS= read -r stat_line < "/proc/$pid/stat"
    stat_rest="''${stat_line##*) }"
    read -r -a stat_fields <<< "$stat_rest"
    [[ "''${stat_fields[19]:-}" =~ ^[1-9][0-9]*$ ]]
    printf '%s\n' "''${stat_fields[19]}"
  '';
  fakeChildCleanupBarrier = pkgs.writeShellScriptBin "child-cleanup-barrier" ''
    set -euo pipefail
    pid="''${1:?}"
    if [[ -n "''${OCSB_GATEWAY_CHILD_CLEANUP_SEEN_FIFO:-}" ]]; then
      printf '%s\n' "$pid" > "$OCSB_GATEWAY_CHILD_CLEANUP_SEEN_FIFO"
      IFS= read -r _ < "''${OCSB_GATEWAY_CHILD_CLEANUP_RELEASE_FIFO:?}"
    fi
  '';
  service = import (builtins.toPath (repo + "/lib/hermes-service.nix")) {
    inherit pkgs;
    nohupCommand = "${fakeNohup}/bin/nohup";
    hermesCommand = "${fakeHermes}/bin/hermes";
    candidateStartTimeCommand = "${fakeCandidateStartTime}/bin/candidate-start-time";
    childStartTimeCommand = "${fakeChildStartTime}/bin/child-start-time";
    childCleanupBarrierCommand = "${fakeChildCleanupBarrier}/bin/child-cleanup-barrier";
  };
in
pkgs.runCommand "ocsb-hermes-service-fixture" {} ''
  mkdir -p "$out/bin"
  ln -s "${service}/bin/service" "$out/bin/service"
  ln -s "${fakeNohup}/bin/nohup" "$out/bin/fake-nohup"
  ln -s "${fakeHermes}/bin/hermes" "$out/bin/fake-hermes"
  ln -s "${fakeCandidateStartTime}/bin/candidate-start-time" "$out/bin/fake-candidate-start-time"
  ln -s "${fakeChildStartTime}/bin/child-start-time" "$out/bin/fake-child-start-time"
  ln -s "${fakeChildCleanupBarrier}/bin/child-cleanup-barrier" "$out/bin/fake-child-cleanup-barrier"
''
NIX
  fixture_out="$(
    OCSB_TEST_REPO_ROOT="$REPO_ROOT" nix build --no-link --print-out-paths --impure \
      --file "$fixture_expr"
  )" || return 1
  fixture_store="${fixture_out##*$'\n'}"
  for _fixture_binary in service fake-nohup fake-hermes fake-candidate-start-time \
    fake-child-start-time fake-child-cleanup-barrier; do
    [[ -x "$fixture_store/bin/$_fixture_binary" ]] || {
      echo "service fixture did not produce $_fixture_binary" >&2
      return 1
    }
    ln -s "$fixture_store/bin/$_fixture_binary" "$fixture_dir/$_fixture_binary"
  done
  rm -f -- "$fixture_expr"
  : > "$fixture_dir/.ocsb-hermes-service-fixture"
  chmod 0600 "$fixture_dir/.ocsb-hermes-service-fixture"
  printf '%s\n' "$fixture_dir/service"
}

if [[ "$BUILD_LIGHTWEIGHT_WRAPPER" -eq 1 ]]; then
  build_lightweight_wrapper "$BUILD_FIXTURE_DIR"
  exit
fi
if [[ "$BUILD_SERVICE_FIXTURE" -eq 1 ]]; then
  build_service_fixture "$BUILD_FIXTURE_DIR"
  exit
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
REPLACE_FIXTURE_PIDS=()
REPLACE_LEGACY_PIDFILE=""
REPLACE_LEGACY_DIR_CREATED=0
LIGHTWEIGHT_FIXTURE_DIR=""
GATEWAY_FIXTURE_PIDS=()
GATEWAY_FIXTURE_DIR=""

cleanup_gateway_fixtures() {
  local pid
  for pid in "${GATEWAY_FIXTURE_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${GATEWAY_FIXTURE_PIDS[@]}"; do
    timeout 5 tail --pid="$pid" -f /dev/null 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  if [[ -n "$GATEWAY_FIXTURE_DIR" ]]; then
    find "$GATEWAY_FIXTURE_DIR" -type d -exec chmod u+w {} + 2>/dev/null || true
    rm -rf -- "$GATEWAY_FIXTURE_DIR"
  fi
  GATEWAY_FIXTURE_PIDS=()
  GATEWAY_FIXTURE_DIR=""
}

cleanup_replace_identity_fixtures() {
  local pid
  for pid in "${REPLACE_FIXTURE_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${REPLACE_FIXTURE_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  if [[ -n "$REPLACE_LEGACY_PIDFILE" ]]; then
    rm -f -- "$REPLACE_LEGACY_PIDFILE"
    if [[ "$REPLACE_LEGACY_DIR_CREATED" -eq 1 ]]; then
      rmdir "${REPLACE_LEGACY_PIDFILE%/*}" 2>/dev/null || true
    fi
  fi
  if [[ -n "$LIGHTWEIGHT_FIXTURE_DIR" ]]; then
    rm -f -- "$LIGHTWEIGHT_FIXTURE_DIR/ocsb-hermes" \
      "$LIGHTWEIGHT_FIXTURE_DIR/.ocsb-hermes-lightweight-fixture" \
      "$LIGHTWEIGHT_FIXTURE_DIR/fake-inner.log"
    rmdir "$LIGHTWEIGHT_FIXTURE_DIR" 2>/dev/null || true
  fi
  REPLACE_FIXTURE_PIDS=()
  REPLACE_LEGACY_PIDFILE=""
  REPLACE_LEGACY_DIR_CREATED=0
  LIGHTWEIGHT_FIXTURE_DIR=""
}

cleanup() {
  cleanup_gateway_fixtures
  cleanup_replace_identity_fixtures
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
FLAKE_TEXT="$(cat "$REPO_ROOT/flake.nix")"
HERMES_SERVICE_TEXT="$(cat "$REPO_ROOT/lib/hermes-service.nix")"
HERMES_WRAPPER_TEXT="$(cat "$REPO_ROOT/scripts/hermes-wrapper.nix")"
HERMES_TEMPLATE_TEXT="$(cat "$REPO_ROOT/templates/hermes-agent.nix")"
HERMES_NIX_CONFIG_TEMPLATE_TEXT="$(cat "$REPO_ROOT/templates/hermes-agent-nix-config.nix")"
assert_contains "source: hermes input points at Hermes Agent v2026.7.20 tag" "$FLAKE_TEXT" 'github:NousResearch/hermes-agent/v2026.7.20'
assert_contains "source: flake imports extracted service helper" "$FLAKE_TEXT" 'import ./lib/hermes-service.nix'
assert_contains "source: helper package defines service binary" "$HERMES_SERVICE_TEXT" 'writeShellScriptBin "service"'
assert_contains "source: service command documents gateway actions" "$HERMES_SERVICE_TEXT" 'service gateway start|stop|restart|status'
assert_contains "source: restart uses upstream replace" "$HERMES_SERVICE_TEXT" 'gateway run --replace'
assert_contains "source: helper stores gateway state under HERMES_HOME" "$HERMES_SERVICE_TEXT" 'state_parent="$HERMES_HOME/service"'
assert_contains "source: helper defines runtime pid dir" "$HERMES_SERVICE_TEXT" 'runtime_dir='
assert_contains "source: helper uses private Task 1 runtime" "$HERMES_SERVICE_TEXT" 'ocsb_runtime_dir'
assert_contains "source: helper persists stopped marker" "$HERMES_SERVICE_TEXT" 'stopped_file="$state_dir/stopped"'
assert_contains "source: helper tracks typed supervisor identity" "$HERMES_SERVICE_TEXT" 'supervisor_record="$(ocsb_process_record_path'
assert_contains "source: start uses reservation protocol" "$HERMES_SERVICE_TEXT" 'gateway_start_or_reserve_locked'
assert_contains "source: candidate claims 128-bit token" "$HERMES_SERVICE_TEXT" 'GATEWAY_RESERVATION_TOKEN'
assert_contains "source: supervisor installs HUP handler" "$HERMES_SERVICE_TEXT" 'trap supervisor_on_signal INT TERM HUP'
assert_contains "source: blocking helpers reject a held lock" "$HERMES_SERVICE_TEXT" 'gateway_assert_unlocked || return 1'
assert_contains "source: failed child cleanup starts after unlock" "$HERMES_SERVICE_TEXT" $'gateway_unlock\n          gateway_finish_failed_supervisor_child'
assert_contains "source: status reports enabled state" "$HERMES_SERVICE_TEXT" 'enabled_state='
assert_contains "template: daemon uses service gateway supervise" "$HERMES_TEMPLATE_TEXT" 'service gateway supervise'
assert_contains "template nix-config: daemon uses service gateway supervise" "$HERMES_NIX_CONFIG_TEMPLATE_TEXT" 'service gateway supervise'
assert_contains "template: installs Hermes service helper" "$HERMES_TEMPLATE_TEXT" 'hermesServicePackage'
assert_contains "template nix-config: installs Hermes service helper" "$HERMES_NIX_CONFIG_TEMPLATE_TEXT" 'hermesServicePackage'
for _env_name in ALIBABA_CODING_PLAN_API_KEY GH_TOKEN GITHUB_TOKEN ZAI_API_KEY Z_AI_API_KEY NOUS_API_KEY QWEN_API_KEY DEEPINFRA_API_KEY UPSTAGE_API_KEY; do
  assert_contains "source: wrapper captures default Hermes API key env $_env_name" "$HERMES_WRAPPER_TEXT" "$_env_name"
done
assert_contains "source: caller file plus explicit secret env is rejected" "$HERMES_WRAPPER_TEXT" 'secret names cannot be combined with --api-keys-env-file'
assert_contains "source: caller file refusal tells users to merge secret names" "$HERMES_WRAPPER_TEXT" 'merge $_API_KEYS_ENV_NAMES_LIST into --api-keys-env-file'

if [[ "$SOURCE_ONLY" == "1" ]]; then
  echo ""
  echo "=== hermes-agent source-only Results: $PASS passed, $FAIL failed ==="
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

proc_start_time() {
  local pid="$1"
  local stat_line stat_rest
  local -a stat_fields
  IFS= read -r stat_line < "/proc/$pid/stat"
  stat_rest="${stat_line##*) }"
  read -r -a stat_fields <<<"$stat_rest"
  printf '%s\n' "${stat_fields[19]}"
}

remove_record_if_line_matches() {
  local record="$1"
  local expected_line="$2"
  local actual_line record_size

  [[ -f "$record" && ! -L "$record" ]] || return 1
  IFS= read -r actual_line < "$record" || return 1
  record_size="$(stat -c %s -- "$record")" || return 1
  [[ "$record_size" -eq $((${#actual_line} + 1)) ]] || return 1
  [[ "$actual_line" == "$expected_line" ]] || return 1
  rm -f -- "$record"
}

gateway_fixture_count() {
  local dir="$1"
  local pattern="$2"
  find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '.' | wc -c
}

gateway_wait_for_count() {
  local dir="$1"
  local pattern="$2"
  local expected="$3"
  timeout 15 bash -c '
    while [[ "$(find "$1" -maxdepth 1 -type f -name "$2" -printf "." | wc -c)" -lt "$3" ]]; do
      sleep 0.05
    done
  ' _ "$dir" "$pattern" "$expected"
}

gateway_release_candidates() {
  local events_dir="$1"
  local release_fd="$2"
  local count="$3"
  local i
  : > "$events_dir/release"
  chmod 0600 "$events_dir/release"
  for ((i = 0; i < count; i++)); do
    printf 'release\n' >&"$release_fd" || true
  done
  gateway_wait_for_count "$events_dir" 'released.*' "$count"
}

gateway_remove_service_fixture() {
  local service="$1"
  local fixture_dir
  fixture_dir="$(dirname "$service")"
  if [[ -f "$fixture_dir/.ocsb-hermes-service-fixture" ]]; then
    rm -f -- "$fixture_dir/service" "$fixture_dir/fake-nohup" \
      "$fixture_dir/fake-hermes" "$fixture_dir/fake-candidate-start-time" \
      "$fixture_dir/fake-child-start-time" "$fixture_dir/fake-child-cleanup-barrier" \
      "$fixture_dir/.ocsb-hermes-service-fixture"
    rmdir "$fixture_dir" 2>/dev/null || true
  fi
}

gateway_reservation_case() {
  local service="$WRAPPER"
  local service_fixture_dir case_dir events_dir runtime_parent home runtime_dir
  local gate_fifo ready_fifo event_fifo release_fifo gate_fd ready_fd event_fd release_fd
  local term_seen_fifo term_release_fifo term_seen_fd term_release_fd term_seen_pid gateway_lock_file
  local -a caller_pids=()
  local i pid rc spawn_count=0 reservation_hits=0 case_failed=0 event
  local record line version record_pid record_start record_instance actual_start
  local supervisor_record="" child_record="" supervisor_pid="" child_pid="" child_instance=""
  local reservation_record="" reservation_pid="" reservation_start="" reservation_token="" reservation_instance=""
  local stale_pid stale_start fake_start status_rc stop_rc candidate_pid candidate_start candidate_token
  local old_child_pid restart_rc restart_out status_out new_child_pid new_child_start
  local overlap_restart_pid overlap_restart_rc overlap_status_rc overlap_status_out
  local timeout_events timeout_runtime_parent timeout_runtime_dir timeout_home timeout_event_fd timeout_release_fd
  local timeout_start_rc timeout_candidate_pid
  local hup_start_rc hup_start_out hup_child_pid hup_child_start hup_failed=0
  local capture_events capture_runtime_parent capture_runtime_dir capture_home capture_event_fd capture_release_fd
  local capture_term_seen_fd capture_term_release_fd capture_term_seen_pid capture_start_pid
  local capture_start_rc capture_candidate_pid capture_failed=0
  local child_capture_events child_capture_runtime_parent child_capture_runtime_dir child_capture_home
  local child_capture_seen_fd child_capture_release_fd child_capture_command_pid child_capture_child_pid
  local child_capture_owner_pid child_capture_rc child_capture_failed=0 child_capture_lock_file
  local -a child_capture_records=()

  [[ -x "$service" && -L "$service" ]] || {
    echo "gateway-reservation requires an executable service fixture" >&2
    return 2
  }
  service_fixture_dir="$(dirname "$service")"
  [[ -f "$service_fixture_dir/.ocsb-hermes-service-fixture" ]] || {
    echo "gateway-reservation requires --build-service-fixture output" >&2
    return 2
  }

  case_dir="$TMPDIR/gateway-reservation"
  events_dir="$case_dir/events"
  runtime_parent="$case_dir/runtime-parent"
  home="$case_dir/home/.hermes"
  install -d -m 0700 "$case_dir" "$events_dir" "$runtime_parent" "$home"
  # Hermes preExec creates this directory under its ordinary umask.
  install -d -m 0755 "$home/logs"
  GATEWAY_FIXTURE_DIR="$case_dir"
  gate_fifo="$events_dir/start-gate.fifo"
  ready_fifo="$events_dir/ready.fifo"
  event_fifo="$events_dir/event.fifo"
  release_fifo="$events_dir/release.fifo"
  term_seen_fifo="$events_dir/child-term-seen.fifo"
  term_release_fifo="$events_dir/child-term-release.fifo"
  mkfifo -m 0600 "$gate_fifo" "$ready_fifo" "$event_fifo" "$release_fifo" \
    "$events_dir/child-exit.fifo" "$term_seen_fifo" "$term_release_fifo"
  exec {gate_fd}<>"$gate_fifo"
  exec {ready_fd}<>"$ready_fifo"
  exec {event_fd}<>"$event_fifo"
  exec {release_fd}<>"$release_fifo"
  exec {term_seen_fd}<>"$term_seen_fifo"
  exec {term_release_fd}<>"$term_release_fifo"

  for i in {1..8}; do
    (
      # A successful observer exits before the parent joins the callers; it
      # must not inherit and run the parent's fixture-cleanup EXIT trap.
      trap - EXIT
      printf '%s\n' "$i" > "$ready_fifo"
      IFS= read -r _ < "$gate_fifo"
      set +e
      env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
        OCSB_GATEWAY_FIXTURE_DIR="$events_dir" \
        "$service" gateway start > "$events_dir/receipt.$i" 2>&1
      caller_rc=$?
      set -e
      printf 'done:%s:%s\n' "$i" "$caller_rc" > "$event_fifo"
      exit "$caller_rc"
    ) &
    caller_pids+=("$!")
  done

  for i in {1..8}; do
    if ! IFS= read -r -t 15 _ <&"$ready_fd"; then
      echo "FAIL: timed out waiting for start caller barrier" >&2
      case_failed=1
      break
    fi
  done
  if [[ "$case_failed" -eq 0 ]]; then
    for i in {1..8}; do
      printf 'go\n' >&"$gate_fd"
    done
  fi

  # The race verdict is event-driven: fake nohup emits a spawn event and each
  # completed caller emits a done event.  GREEN deliberately releases the one
  # candidate only after the seven reservation receipts are observable.
  for i in {1..100}; do
    # Observers deliberately do not complete before the candidate is released,
    # so probe the files rather than blocking for a caller-completion event.
    IFS= read -r -t 0.05 event <&"$event_fd" || true
    spawn_count="$(gateway_fixture_count "$events_dir" 'spawn.*')"
    reservation_hits="$({ grep -hFx 'reservation already active' "$events_dir"/receipt.* 2>/dev/null || true; } | wc -l)"
    if [[ "$spawn_count" -eq 8 && "$reservation_hits" -eq 0 ]] || \
        [[ "$spawn_count" -eq 1 && "$reservation_hits" -eq 7 ]]; then
      break
    fi
    sleep 0.05
  done
  for record in "$events_dir"/spawn.*; do
    [[ -e "$record" ]] || continue
    pid="${record##*.}"
    GATEWAY_FIXTURE_PIDS+=("$pid")
  done

  if [[ "$spawn_count" -eq 8 && "$reservation_hits" -eq 0 ]]; then
    echo "FAIL[RED-gateway-race]: spawn_count=8 reservation_hits=0" >&2
    gateway_release_candidates "$events_dir" "$release_fd" 8 || true
    cleanup_gateway_fixtures
    gateway_remove_service_fixture "$service"
    return 1
  fi

  if [[ "$spawn_count" -ne 1 || "$reservation_hits" -ne 7 ]]; then
    echo "FAIL: unexpected gateway race result: spawn_count=$spawn_count reservation_hits=$reservation_hits" >&2
    case_failed=1
  else
    echo "PASS[GREEN-gateway-race]: spawn_count=1 reservation_hits=7"
  fi

  runtime_dir="$runtime_parent/ocsb-$(id -u)"
  if [[ "$spawn_count" -eq 1 ]]; then
    candidate_pid="$(find "$events_dir" -maxdepth 1 -type f -name 'spawn.*' -printf '%f\n')"
    candidate_pid="${candidate_pid##*.}"
    if ! candidate_start="$(proc_start_time "$candidate_pid" 2>/dev/null)"; then
      candidate_start=""
    fi
    reservation_record="$(find "$runtime_dir" -maxdepth 1 -type f -name 'reservation-*' -print -quit 2>/dev/null || true)"
    if [[ -z "$reservation_record" || -L "$reservation_record" || \
          "$(stat -c %u "$reservation_record" 2>/dev/null || true)" != "$(id -u)" || \
          "$(stat -c %a "$reservation_record" 2>/dev/null || true)" != "600" ]]; then
      echo "FAIL: safe versioned reservation was not observable before claim" >&2
      case_failed=1
    else
      IFS=$'\t' read -r version reservation_pid reservation_start reservation_token reservation_instance < "$reservation_record" || true
      if [[ "$version" != "v1" || "$reservation_pid" != "$candidate_pid" || \
            "$reservation_start" != "$candidate_start" || ! "$reservation_token" =~ ^[0-9a-f]{32}$ || \
            ! "$reservation_instance" =~ ^[0-9a-f]{64}$ ]]; then
        echo "FAIL: reservation did not bind candidate pid/start/token/instance" >&2
        case_failed=1
      fi
    fi
    gateway_wait_for_count "$events_dir" 'valid-candidate-argv.*' 1 || {
      echo "FAIL: fake nohup did not validate candidate argv" >&2
      case_failed=1
    }
    candidate_token="$(cat "$events_dir"/valid-candidate-argv.* 2>/dev/null || true)"
    if [[ -n "$reservation_token" && "$candidate_token" != "$reservation_token" ]]; then
      echo "FAIL: candidate argv token did not match reservation token" >&2
      case_failed=1
    fi
  fi

  if [[ "$spawn_count" -gt 0 ]]; then
    gateway_release_candidates "$events_dir" "$release_fd" "$spawn_count" || {
      echo "FAIL: candidate release did not complete" >&2
      case_failed=1
    }
  fi
  if [[ "$spawn_count" -eq 1 ]]; then
    gateway_wait_for_count "$events_dir" 'gateway-start.*' 1 || {
      echo "FAIL: fake Hermes gateway did not start" >&2
      case_failed=1
    }
  fi

  for pid in "${caller_pids[@]}"; do
    if ! timeout 15 tail --pid="$pid" -f /dev/null 2>/dev/null; then
      echo "FAIL: start caller $pid exceeded global bound" >&2
      kill "$pid" 2>/dev/null || true
      case_failed=1
    fi
    set +e
    wait "$pid"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      echo "FAIL: start caller $pid exited $rc" >&2
      cat -- "$events_dir"/receipt.* >&2 || true
      case_failed=1
    fi
  done

  if ! gateway_wait_for_count "$runtime_dir" 'process-*.pid' 2; then
    echo "FAIL: two typed gateway process records did not appear" >&2
    case_failed=1
  fi
  for record in "$runtime_dir"/process-*.pid; do
    [[ -e "$record" ]] || continue
    if [[ -L "$record" || ! -f "$record" || "$(stat -c %u "$record")" != "$(id -u)" || "$(stat -c %a "$record")" != "600" ]]; then
      echo "FAIL: unsafe typed gateway record: $record" >&2
      case_failed=1
      continue
    fi
    IFS=$'\t' read -r version record_pid record_start record_instance < "$record" || true
    if [[ "$version" != "v1" || ! "$record_pid" =~ ^[1-9][0-9]*$ || \
          ! "$record_start" =~ ^[1-9][0-9]*$ || ! "$record_instance" =~ ^[0-9a-f]{64}$ ]]; then
      echo "FAIL: malformed typed gateway record: $record" >&2
      case_failed=1
      continue
    fi
    actual_start="$(proc_start_time "$record_pid" 2>/dev/null || true)"
    if [[ "$actual_start" != "$record_start" ]]; then
      echo "FAIL: typed gateway record does not match live identity: $record" >&2
      case_failed=1
      continue
    fi
    if [[ -e "$events_dir/gateway-start.$record_pid" ]]; then
      child_record="$record"
      child_pid="$record_pid"
      child_instance="$record_instance"
    else
      supervisor_record="$record"
      supervisor_pid="$record_pid"
    fi
  done
  if [[ -z "$supervisor_record" || -z "$child_record" ]]; then
    echo "FAIL: typed supervisor and child records were not distinguishable" >&2
    case_failed=1
  fi
  if [[ "$(gateway_fixture_count "$events_dir" 'gateway-start.*')" -ne 1 ]]; then
    echo "FAIL: expected exactly one fake gateway start" >&2
    case_failed=1
  fi
  if [[ "$(gateway_fixture_count "$events_dir" 'candidate-lock-fd.*')" -ne 0 || \
        "$(gateway_fixture_count "$events_dir" 'child-lock-fd.*')" -ne 0 ]]; then
    echo "FAIL: candidate or child inherited gateway lock fd" >&2
    case_failed=1
  fi
  if compgen -G "$runtime_dir/reservation-*" > /dev/null; then
    echo "FAIL: claimed reservation remained present" >&2
    case_failed=1
  fi

  if [[ -n "$child_pid" && -n "$child_record" ]]; then
    old_child_pid="$child_pid"
    set +e
    restart_out="$(env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
      OCSB_GATEWAY_FIXTURE_DIR="$events_dir" "$service" gateway restart 2>&1)"
    restart_rc=$?
    set -e
    if [[ "$restart_rc" -ne 0 || "$restart_out" != *'gateway restart requested'* ]]; then
      echo "FAIL: gateway restart did not complete a child generation change" >&2
      printf '  restart rc=%s output=%s\n' "$restart_rc" "$restart_out" >&2
      case_failed=1
    fi
    gateway_wait_for_count "$events_dir" 'gateway-start.*' 2 || {
      echo "FAIL: restart did not launch exactly one replacement child" >&2
      case_failed=1
    }
    timeout 15 tail --pid="$old_child_pid" -f /dev/null 2>/dev/null || {
      echo "FAIL: restart did not reap the old child identity" >&2
      case_failed=1
    }
    IFS=$'\t' read -r version new_child_pid new_child_start record_instance < "$child_record" || true
    actual_start="$(proc_start_time "$new_child_pid" 2>/dev/null || true)"
    if [[ "$version" != "v1" || "$new_child_pid" == "$old_child_pid" || \
          "$new_child_start" != "$actual_start" || "$record_instance" != "$child_instance" || \
          ! -e "$events_dir/gateway-start.$new_child_pid" ]]; then
      echo "FAIL: restart replacement did not publish a different valid typed child record" >&2
      case_failed=1
    else
      child_pid="$new_child_pid"
    fi
    set +e
    status_out="$(env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
      OCSB_GATEWAY_FIXTURE_DIR="$events_dir" "$service" gateway status 2>&1)"
    status_rc=$?
    set -e
    if [[ "$status_rc" -ne 0 || "$status_out" != *"pid $child_pid"* ]]; then
      echo "FAIL: status did not snapshot the replacement child" >&2
      case_failed=1
    fi
    if [[ "$(gateway_fixture_count "$events_dir" 'gateway-start.*')" -ne 2 || \
          "$(gateway_fixture_count "$events_dir" 'child-lock-fd.*')" -ne 0 ]]; then
      echo "FAIL: restart produced duplicate children or leaked the lock fd" >&2
      case_failed=1
    fi
  fi

  if [[ -n "$child_pid" ]]; then
    old_child_pid="$child_pid"
    env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
      OCSB_GATEWAY_FIXTURE_DIR="$events_dir" "$service" gateway restart \
      > "$events_dir/overlap-restart.receipt" 2>&1 &
    overlap_restart_pid=$!
    timeout 15 tail --pid="$old_child_pid" -f /dev/null 2>/dev/null || {
      echo "FAIL: overlapping restart did not terminate its old child" >&2
      kill "$overlap_restart_pid" 2>/dev/null || true
      case_failed=1
    }
    env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
      OCSB_GATEWAY_FIXTURE_DIR="$events_dir" "$service" gateway stop >/dev/null 2>&1 || case_failed=1
    timeout 15 tail --pid="$overlap_restart_pid" -f /dev/null 2>/dev/null || {
      echo "FAIL: restart wait was not bounded after a later stop" >&2
      kill "$overlap_restart_pid" 2>/dev/null || true
      case_failed=1
    }
    set +e
    wait "$overlap_restart_pid"
    overlap_restart_rc=$?
    set -e
    if [[ "$overlap_restart_rc" -ne 0 ]] || \
       ! grep -Fq 'gateway restart superseded by stop' "$events_dir/overlap-restart.receipt"; then
      echo "FAIL: later stop did not supersede the in-flight restart" >&2
      case_failed=1
    fi
    set +e
    overlap_status_out="$(env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
      OCSB_GATEWAY_FIXTURE_DIR="$events_dir" "$service" gateway status 2>&1)"
    overlap_status_rc=$?
    set -e
    if [[ "$overlap_status_rc" -eq 0 || "$overlap_status_out" != *'gateway stopped disabled'* || \
          -e "$child_record" ]]; then
      echo "FAIL: stop/restart overlap did not linearize to disabled with no child" >&2
      case_failed=1
    fi
    child_pid=""
  fi

  sleep 60 &
  stale_pid=$!
  GATEWAY_FIXTURE_PIDS+=("$stale_pid")
  stale_start="$(proc_start_time "$stale_pid")"
  fake_start=$((stale_start + 1))
  if [[ -n "$child_record" ]]; then
    printf 'v1\t%s\t%s\t%s\n' "$stale_pid" "$fake_start" "$child_instance" > "$child_record"
    chmod 0600 "$child_record"
    set +e
    env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
      OCSB_GATEWAY_FIXTURE_DIR="$events_dir" "$service" gateway status >/dev/null 2>&1
    status_rc=$?
    set -e
    if [[ "$status_rc" -eq 0 || -e "$child_record" ]] || ! kill -0 "$stale_pid" 2>/dev/null; then
      echo "FAIL: status did not CAS-clean stale typed child identity safely" >&2
      case_failed=1
    fi
    printf 'v1\t%s\t%s\t%s\n' "$stale_pid" "$fake_start" "$child_instance" > "$child_record"
    chmod 0600 "$child_record"
    set +e
    env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
      OCSB_GATEWAY_FIXTURE_DIR="$events_dir" "$service" gateway stop >/dev/null 2>&1
    stop_rc=$?
    set -e
    if [[ "$stop_rc" -ne 0 || -e "$child_record" ]] || ! kill -0 "$stale_pid" 2>/dev/null; then
      echo "FAIL: stop did not CAS-clean stale typed child identity safely" >&2
      case_failed=1
    fi
  fi

  if [[ -n "$reservation_record" && -n "$reservation_instance" ]]; then
    printf 'v1\t%s\t%s\t%s\t%s\n' "$stale_pid" "$fake_start" \
      0123456789abcdef0123456789abcdef "$reservation_instance" > "$reservation_record"
    chmod 0600 "$reservation_record"
    set +e
    env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
      OCSB_GATEWAY_FIXTURE_DIR="$events_dir" "$service" gateway status >/dev/null 2>&1
    status_rc=$?
    set -e
    if [[ "$status_rc" -eq 0 || -e "$reservation_record" ]] || ! kill -0 "$stale_pid" 2>/dev/null; then
      echo "FAIL: status did not CAS-clean stale reservation identity safely" >&2
      case_failed=1
    fi
  fi

  if [[ -n "$supervisor_pid" && -n "$child_record" ]]; then
    set +e
    hup_start_out="$(env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
      OCSB_GATEWAY_FIXTURE_DIR="$events_dir" "$service" gateway start 2>&1)"
    hup_start_rc=$?
    set -e
    if [[ "$hup_start_rc" -ne 0 ]]; then
      echo "FAIL: could not start an active child for HUP handling: $hup_start_out" >&2
      case_failed=1
      hup_failed=1
    fi
    gateway_wait_for_count "$events_dir" 'gateway-start.*' 3 || {
      echo "FAIL: HUP fixture did not start its active child" >&2
      case_failed=1
      hup_failed=1
    }
    gateway_wait_for_count "$runtime_dir" 'process-*.pid' 2 || {
      echo "FAIL: HUP fixture did not publish supervisor and child records" >&2
      case_failed=1
      hup_failed=1
    }
    IFS=$'\t' read -r version hup_child_pid hup_child_start record_instance < "$child_record" || true
    actual_start="$(proc_start_time "$hup_child_pid" 2>/dev/null || true)"
    if [[ "$version" != "v1" || "$hup_child_start" != "$actual_start" || \
          "$record_instance" != "$child_instance" || ! -e "$events_dir/gateway-start.$hup_child_pid" ]]; then
      echo "FAIL: HUP fixture child did not have a valid typed identity" >&2
      case_failed=1
      hup_failed=1
    fi
    if [[ "$hup_child_pid" =~ ^[1-9][0-9]*$ ]]; then
      GATEWAY_FIXTURE_PIDS+=("$hup_child_pid")
    fi
    : > "$events_dir/hold-child-term"
    chmod 0600 "$events_dir/hold-child-term"
    kill -HUP "$supervisor_pid" 2>/dev/null || {
      echo "FAIL: could not deliver HUP to typed supervisor" >&2
      case_failed=1
      hup_failed=1
    }
    if ! IFS= read -r -t 15 term_seen_pid <&"$term_seen_fd" || \
       [[ "$term_seen_pid" != "$hup_child_pid" ]]; then
      echo "FAIL: HUP did not reach the exact child TERM barrier" >&2
      case_failed=1
      hup_failed=1
    fi
    gateway_lock_file="$(find "$runtime_dir" -maxdepth 1 -type f \
      -name 'hermes-gateway-*.lock' -print -quit 2>/dev/null || true)"
    if ! kill -0 "$supervisor_pid" 2>/dev/null || ! kill -0 "$hup_child_pid" 2>/dev/null || \
       [[ ! -f "$supervisor_record" || ! -f "$child_record" ]] || \
       [[ -z "$gateway_lock_file" ]] || ! flock -n "$gateway_lock_file" true; then
      echo "FAIL: HUP handler waited or removed records while holding the gateway lock" >&2
      case_failed=1
      hup_failed=1
    fi
    printf 'release\n' >&"$term_release_fd"
    if [[ "$hup_child_pid" =~ ^[1-9][0-9]*$ ]]; then
      timeout 15 tail --pid="$hup_child_pid" -f /dev/null 2>/dev/null || {
        echo "FAIL: HUP handler did not TERM and reap the exact child" >&2
        case_failed=1
        hup_failed=1
      }
    fi
    timeout 15 tail --pid="$supervisor_pid" -f /dev/null 2>/dev/null || {
      echo "FAIL: HUP handler did not exit the supervisor" >&2
      case_failed=1
      hup_failed=1
    }
    if compgen -G "$runtime_dir/process-*.pid" > /dev/null || \
       compgen -G "$runtime_dir/reservation-*" > /dev/null; then
      echo "FAIL: HUP cleanup left typed records or a reservation" >&2
      case_failed=1
      hup_failed=1
    fi
    if [[ "$hup_failed" -eq 0 ]]; then
      echo "PASS[GREEN-gateway-hup]: child_reaped=1 records_clean=1"
    fi
    supervisor_pid=""
    child_pid=""
  fi

  if [[ -n "$supervisor_pid" ]]; then
    kill "$supervisor_pid" 2>/dev/null || true
    timeout 15 tail --pid="$supervisor_pid" -f /dev/null 2>/dev/null || kill -KILL "$supervisor_pid" 2>/dev/null || true
  fi
  kill "$stale_pid" 2>/dev/null || true
  wait "$stale_pid" 2>/dev/null || true
  if compgen -G "$runtime_dir/process-*.pid" > /dev/null || compgen -G "$runtime_dir/reservation-*" > /dev/null; then
    echo "FAIL: gateway records or reservation remained after cleanup" >&2
    for record in "$runtime_dir"/process-*.pid "$runtime_dir"/reservation-*; do
      [[ -e "$record" || -L "$record" ]] || continue
      printf '  remaining %s: ' "$record" >&2
      cat "$record" >&2 || true
    done
    case_failed=1
  fi
  for record in "$runtime_dir"/hermes-gateway-*.lock; do
    [[ -e "$record" ]] || continue
    if ! flock -n "$record" true; then
      echo "FAIL: gateway lock remained held after supervisor cleanup" >&2
      case_failed=1
    fi
  done
  for pid in "${GATEWAY_FIXTURE_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "FAIL: gateway fixture pid remained live after cleanup: $pid" >&2
      case_failed=1
    fi
  done

  timeout_events="$case_dir/unclaimed/events"
  timeout_runtime_parent="$case_dir/unclaimed/runtime-parent"
  timeout_runtime_dir="$timeout_runtime_parent/ocsb-$(id -u)"
  timeout_home="$case_dir/unclaimed/home/.hermes"
  install -d -m 0700 "$timeout_events" "$timeout_runtime_parent" "$timeout_home"
  mkfifo -m 0600 "$timeout_events/event.fifo" "$timeout_events/release.fifo" \
    "$timeout_events/child-exit.fifo"
  exec {timeout_event_fd}<>"$timeout_events/event.fifo"
  exec {timeout_release_fd}<>"$timeout_events/release.fifo"
  set +e
  env -u XDG_RUNTIME_DIR TMPDIR="$timeout_runtime_parent" HERMES_HOME="$timeout_home" \
    OCSB_GATEWAY_FIXTURE_DIR="$timeout_events" \
    timeout 25 "$service" gateway start > "$timeout_events/receipt" 2>&1
  timeout_start_rc=$?
  set -e
  if [[ "$timeout_start_rc" -eq 0 ]] || \
     ! grep -Fq 'supervisor reservation was not claimed within 5 seconds' "$timeout_events/receipt"; then
    echo "FAIL: unclaimed reservation did not fail within its bounded timeout" >&2
    echo "  start rc: $timeout_start_rc" >&2
    tail -n 120 "$timeout_events/receipt" | sed 's/^/  receipt: /' >&2 || true
    case_failed=1
  fi
  if ! IFS= read -r -t 1 event <&"$timeout_event_fd" || [[ "$event" != spawn:* ]] || \
     [[ "$(gateway_fixture_count "$timeout_events" 'spawn.*')" -ne 1 ]]; then
    echo "FAIL: unclaimed reservation fixture did not spawn exactly one candidate" >&2
    case_failed=1
  fi
  timeout_candidate_pid="$(find "$timeout_events" -maxdepth 1 -type f -name 'spawn.*' -printf '%f\n' 2>/dev/null || true)"
  timeout_candidate_pid="${timeout_candidate_pid##*.}"
  if [[ "$timeout_candidate_pid" =~ ^[1-9][0-9]*$ ]]; then
    timeout 5 tail --pid="$timeout_candidate_pid" -f /dev/null 2>/dev/null || {
      echo "FAIL: timed-out reservation candidate remained live" >&2
      case_failed=1
    }
  fi
  if compgen -G "$timeout_runtime_dir/process-*.pid" > /dev/null || \
     compgen -G "$timeout_runtime_dir/reservation-*" > /dev/null; then
    echo "FAIL: unclaimed reservation cleanup left coordination records" >&2
    case_failed=1
  fi
  for record in "$timeout_runtime_dir"/hermes-gateway-*.lock; do
    [[ -e "$record" ]] || continue
    if ! flock -n "$record" true; then
      echo "FAIL: timed-out reservation left its lock held" >&2
      case_failed=1
    fi
  done
  exec {timeout_event_fd}>&-
  exec {timeout_release_fd}>&-

  capture_events="$case_dir/start-time-failure/events"
  capture_runtime_parent="$case_dir/start-time-failure/runtime-parent"
  capture_runtime_dir="$capture_runtime_parent/ocsb-$(id -u)"
  capture_home="$case_dir/start-time-failure/home/.hermes"
  install -d -m 0700 "$capture_events" "$capture_runtime_parent" "$capture_home"
  mkfifo -m 0600 "$capture_events/event.fifo" "$capture_events/release.fifo" \
    "$capture_events/child-exit.fifo" "$capture_events/candidate-ready.fifo" \
    "$capture_events/candidate-term-seen.fifo" "$capture_events/candidate-term-release.fifo"
  exec {capture_event_fd}<>"$capture_events/event.fifo"
  exec {capture_release_fd}<>"$capture_events/release.fifo"
  exec {capture_term_seen_fd}<>"$capture_events/candidate-term-seen.fifo"
  exec {capture_term_release_fd}<>"$capture_events/candidate-term-release.fifo"
  : > "$capture_events/hold-candidate-term"
  chmod 0600 "$capture_events/hold-candidate-term"
  env -u XDG_RUNTIME_DIR TMPDIR="$capture_runtime_parent" HERMES_HOME="$capture_home" \
    OCSB_GATEWAY_FIXTURE_DIR="$capture_events" \
    OCSB_GATEWAY_FAIL_CANDIDATE_START_TIME=1 \
    OCSB_GATEWAY_CANDIDATE_READY_FIFO="$capture_events/candidate-ready.fifo" \
    timeout 20 "$service" gateway start > "$capture_events/receipt" 2>&1 &
  capture_start_pid=$!
  GATEWAY_FIXTURE_PIDS+=("$capture_start_pid")
  if ! IFS= read -r -t 15 capture_term_seen_pid <&"$capture_term_seen_fd"; then
    echo "FAIL: start-time failure candidate did not reach its TERM barrier" >&2
    capture_failed=1
    case_failed=1
  fi
  if ! IFS= read -r -t 1 event <&"$capture_event_fd" || [[ "$event" != spawn:* ]] || \
     [[ "$(gateway_fixture_count "$capture_events" 'spawn.*')" -ne 1 ]] || \
     [[ "$(gateway_fixture_count "$capture_events" 'start-time-capture-failed.*')" -ne 1 ]]; then
    echo "FAIL: start-time failure injection did not observe exactly one spawned candidate" >&2
    capture_failed=1
    case_failed=1
  fi
  capture_candidate_pid="$(find "$capture_events" -maxdepth 1 -type f \
    -name 'start-time-capture-failed.*' -printf '%f\n' 2>/dev/null || true)"
  capture_candidate_pid="${capture_candidate_pid##*.}"
  if [[ "$capture_candidate_pid" =~ ^[1-9][0-9]*$ ]]; then
    GATEWAY_FIXTURE_PIDS+=("$capture_candidate_pid")
  else
    echo "FAIL: start-time failure candidate pid was not recorded" >&2
    capture_failed=1
    case_failed=1
  fi
  gateway_lock_file="$(find "$capture_runtime_dir" -maxdepth 1 -type f \
    -name 'hermes-gateway-*.lock' -print -quit 2>/dev/null || true)"
  if [[ "$capture_term_seen_pid" != "$capture_candidate_pid" ]] || \
     ! kill -0 "$capture_start_pid" 2>/dev/null || \
     ! kill -0 "$capture_candidate_pid" 2>/dev/null || \
     [[ -z "$gateway_lock_file" ]] || ! flock -n "$gateway_lock_file" true; then
    echo "FAIL: start-time recovery did not wait outside the gateway lock for its exact child" >&2
    capture_failed=1
    case_failed=1
  fi
  if compgen -G "$capture_runtime_dir/process-*.pid" > /dev/null || \
     compgen -G "$capture_runtime_dir/reservation-*" > /dev/null; then
    echo "FAIL: start-time capture failure left reservation or typed records" >&2
    capture_failed=1
    case_failed=1
  fi
  printf 'release\n' >&"$capture_term_release_fd"
  timeout 15 tail --pid="$capture_start_pid" -f /dev/null 2>/dev/null || {
    echo "FAIL: start-time failure start command did not finish after candidate release" >&2
    capture_failed=1
    case_failed=1
  }
  set +e
  wait "$capture_start_pid"
  capture_start_rc=$?
  set -e
  if [[ "$capture_start_rc" -eq 0 ]] || \
     ! grep -Fq 'candidate start time unavailable; candidate reaped' "$capture_events/receipt"; then
    echo "FAIL: injected candidate start-time capture failure did not fail and reap" >&2
    capture_failed=1
    case_failed=1
  fi
  if [[ "$capture_candidate_pid" =~ ^[1-9][0-9]*$ ]]; then
    timeout 5 tail --pid="$capture_candidate_pid" -f /dev/null 2>/dev/null || {
      echo "FAIL: start-time failure candidate was not reaped" >&2
      capture_failed=1
      case_failed=1
    }
  fi
  for record in "$capture_runtime_dir"/hermes-gateway-*.lock; do
    [[ -e "$record" ]] || continue
    if ! flock -n "$record" true; then
      echo "FAIL: start-time capture failure left its lock held" >&2
      capture_failed=1
      case_failed=1
    fi
  done
  if [[ "$capture_failed" -eq 0 ]]; then
    echo "PASS[GREEN-gateway-starttime-failure]: candidate_reaped=1 records_clean=1"
  fi
  exec {capture_event_fd}>&-
  exec {capture_release_fd}>&-
  exec {capture_term_seen_fd}>&-
  exec {capture_term_release_fd}>&-

  child_capture_events="$case_dir/child-start-time-failure/events"
  child_capture_runtime_parent="$case_dir/child-start-time-failure/runtime-parent"
  child_capture_runtime_dir="$child_capture_runtime_parent/ocsb-$(id -u)"
  child_capture_home="$case_dir/child-start-time-failure/home/.hermes"
  install -d -m 0700 "$child_capture_events" "$child_capture_runtime_parent" "$child_capture_home"
  install -d -m 0755 "$child_capture_home/logs"
  mkfifo -m 0600 "$child_capture_events/child-exit.fifo" \
    "$child_capture_events/cleanup-seen.fifo" "$child_capture_events/cleanup-release.fifo"
  exec {child_capture_seen_fd}<>"$child_capture_events/cleanup-seen.fifo"
  exec {child_capture_release_fd}<>"$child_capture_events/cleanup-release.fifo"
  env -u XDG_RUNTIME_DIR TMPDIR="$child_capture_runtime_parent" HERMES_HOME="$child_capture_home" \
    OCSB_GATEWAY_FIXTURE_DIR="$child_capture_events" \
    OCSB_GATEWAY_FAIL_CHILD_START_TIME=1 \
    OCSB_GATEWAY_CHILD_CLEANUP_SEEN_FIFO="$child_capture_events/cleanup-seen.fifo" \
    OCSB_GATEWAY_CHILD_CLEANUP_RELEASE_FIFO="$child_capture_events/cleanup-release.fifo" \
    timeout 20 "$service" gateway supervise > "$child_capture_events/receipt" 2>&1 &
  child_capture_command_pid=$!
  GATEWAY_FIXTURE_PIDS+=("$child_capture_command_pid")
  if ! IFS= read -r -t 15 child_capture_child_pid <&"$child_capture_seen_fd"; then
    echo "FAIL: child start-time failure did not reach its cleanup barrier" >&2
    child_capture_failed=1
    case_failed=1
  fi
  if [[ ! "$child_capture_child_pid" =~ ^[1-9][0-9]*$ ]] || \
     [[ "$(gateway_fixture_count "$child_capture_events" 'child-start-time-capture-failed.*')" -ne 1 ]]; then
    echo "FAIL: child start-time failure injection did not identify one direct child" >&2
    child_capture_failed=1
    case_failed=1
  else
    GATEWAY_FIXTURE_PIDS+=("$child_capture_child_pid")
  fi
  mapfile -t child_capture_records < <(find "$child_capture_runtime_dir" -maxdepth 1 -type f \
    -name 'process-*.pid' -print 2>/dev/null || true)
  if [[ "${#child_capture_records[@]}" -ne 1 ]]; then
    echo "FAIL: child cleanup barrier did not retain exactly the supervisor typed record" >&2
    child_capture_failed=1
    case_failed=1
  else
    IFS=$'\t' read -r version child_capture_owner_pid record_start record_instance \
      < "${child_capture_records[0]}"
    if [[ "$version" != "v1" || ! "$child_capture_owner_pid" =~ ^[1-9][0-9]*$ ]] || \
       ! kill -0 "$child_capture_owner_pid" 2>/dev/null; then
      echo "FAIL: child cleanup barrier supervisor record was not a live typed identity" >&2
      child_capture_failed=1
      case_failed=1
    else
      GATEWAY_FIXTURE_PIDS+=("$child_capture_owner_pid")
    fi
  fi
  child_capture_lock_file="$(find "$child_capture_runtime_dir" -maxdepth 1 -type f \
    -name 'hermes-gateway-*.lock' -print -quit 2>/dev/null || true)"
  if [[ -z "$child_capture_lock_file" ]] || ! flock -n "$child_capture_lock_file" true || \
     ! kill -0 "$child_capture_command_pid" 2>/dev/null || \
     ! kill -0 "$child_capture_child_pid" 2>/dev/null; then
    echo "FAIL: child cleanup barrier was not live with the gateway lock free" >&2
    child_capture_failed=1
    case_failed=1
  fi
  if compgen -G "$child_capture_runtime_dir/reservation-*" > /dev/null; then
    echo "FAIL: direct supervisor child cleanup unexpectedly created a reservation" >&2
    child_capture_failed=1
    case_failed=1
  fi
  printf 'release\n' >&"$child_capture_release_fd"
  timeout 15 tail --pid="$child_capture_command_pid" -f /dev/null 2>/dev/null || {
    echo "FAIL: child start-time failure supervisor did not finish after cleanup release" >&2
    child_capture_failed=1
    case_failed=1
  }
  set +e
  wait "$child_capture_command_pid"
  child_capture_rc=$?
  set -e
  if [[ "$child_capture_rc" -eq 0 ]] || \
     ! grep -Fq 'child start time unavailable; child reaped' "$child_capture_events/receipt"; then
    echo "FAIL: injected child start-time failure did not fail and reap" >&2
    child_capture_failed=1
    case_failed=1
  fi
  if [[ "$child_capture_child_pid" =~ ^[1-9][0-9]*$ ]]; then
    timeout 5 tail --pid="$child_capture_child_pid" -f /dev/null 2>/dev/null || {
      echo "FAIL: child start-time failure direct child was not reaped" >&2
      child_capture_failed=1
      case_failed=1
    }
  fi
  if compgen -G "$child_capture_runtime_dir/process-*.pid" > /dev/null || \
     compgen -G "$child_capture_runtime_dir/reservation-*" > /dev/null; then
    echo "FAIL: child start-time failure left typed records or a reservation" >&2
    child_capture_failed=1
    case_failed=1
  fi
  for record in "$child_capture_runtime_dir"/hermes-gateway-*.lock; do
    [[ -e "$record" ]] || continue
    if ! flock -n "$record" true; then
      echo "FAIL: child start-time failure left its gateway lock held" >&2
      child_capture_failed=1
      case_failed=1
    fi
  done
  if [[ "$child_capture_failed" -eq 0 ]]; then
    echo "PASS[GREEN-gateway-child-starttime-failure]: child_reaped=1 lock_free=1 records_clean=1"
  fi
  exec {child_capture_seen_fd}>&-
  exec {child_capture_release_fd}>&-
  exec {term_seen_fd}>&-
  exec {term_release_fd}>&-

  cleanup_gateway_fixtures
  gateway_remove_service_fixture "$service"
  if [[ -e "$case_dir" || -e "$service_fixture_dir" ]]; then
    echo "FAIL: gateway fixture directory remained after cleanup" >&2
    case_failed=1
  fi
  if [[ "$case_failed" -ne 0 ]]; then
    return 1
  fi
  echo "CLEANUP PASS: gateway fixtures"
}

gateway_dead_candidate_case() {
  local service="$WRAPPER" fixture_dir case_dir events runtime_parent runtime_dir home
  local held_ready published_ready owner_receipt observer_receipt owner_pid observer_pid owner_rc observer_rc
  local candidate_pid child_pid reservation_record records release_fifo release_fd

  [[ -x "$service" && -L "$service" ]] || {
    echo "gateway-dead-candidate requires an executable service fixture" >&2
    return 2
  }
  fixture_dir="$(dirname "$service")"
  [[ -f "$fixture_dir/.ocsb-hermes-service-fixture" ]] || {
    echo "gateway-dead-candidate requires --build-service-fixture output" >&2
    return 2
  }

  case_dir="$TMPDIR/gateway-dead-candidate"
  events="$case_dir/events"
  runtime_parent="$case_dir/runtime-parent"
  runtime_dir="$runtime_parent/ocsb-$(id -u)"
  home="$case_dir/home/.hermes"
  held_ready="$events/candidate-held"
  published_ready="$events/candidate-published"
  owner_receipt="$events/owner-receipt"
  observer_receipt="$events/observer-receipt"
  release_fifo="$events/release.fifo"
  install -d -m 0700 "$events" "$runtime_parent" "$home"
  install -d -m 0755 "$home/logs"
  mkfifo -m 0600 "$release_fifo"
  exec {release_fd}<>"$release_fifo"
  GATEWAY_FIXTURE_DIR="$case_dir"

  env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
    OCSB_GATEWAY_FIXTURE_DIR="$events" OCSB_GATEWAY_DIE_AFTER_PUBLICATION=1 \
    OCSB_GATEWAY_CANDIDATE_HELD_READY="$held_ready" \
    OCSB_GATEWAY_DEAD_CANDIDATE_READY="$published_ready" \
    "$service" gateway start >"$owner_receipt" 2>&1 &
  owner_pid=$!
  GATEWAY_FIXTURE_PIDS+=("$owner_pid")
  gateway_wait_for_count "$events" 'candidate-held' 1 || {
    echo 'gateway dead-candidate fixture did not hold the owner candidate before exec' >&2
    return 1
  }
  candidate_pid="$(find "$events" -maxdepth 1 -type f -name 'spawn.*' -printf '%f\n' | sed 's/^spawn\.//')"
  gateway_wait_for_count "$runtime_dir" 'reservation-*' 1 || {
    echo 'gateway dead-candidate fixture did not retain a reservation while the candidate was held' >&2
    return 1
  }
  reservation_record="$(find "$runtime_dir" -maxdepth 1 -type f -name 'reservation-*' -print -quit)"
  if [[ -z "$candidate_pid" || ! "$candidate_pid" =~ ^[1-9][0-9]*$ || -z "$reservation_record" ||
        -e "$events/release" ]] || ! kill -0 "$candidate_pid" 2>/dev/null; then
    echo 'gateway dead-candidate fixture did not hold one live candidate under its reservation' >&2
    return 1
  fi
  env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" HERMES_HOME="$home" \
    OCSB_GATEWAY_FIXTURE_DIR="$events" OCSB_GATEWAY_DIE_AFTER_PUBLICATION=1 \
    "$service" gateway start >"$observer_receipt" 2>&1 &
  observer_pid=$!
  GATEWAY_FIXTURE_PIDS+=("$observer_pid")
  if ! timeout 15 bash -c 'until grep -Fxq "reservation already active" "$1"; do sleep 0.05; done' \
    _ "$observer_receipt"; then
    echo 'gateway dead-candidate observer did not report the exact active reservation' >&2
    return 1
  fi
  gateway_release_candidates "$events" "$release_fd" 1 || {
    echo 'gateway dead-candidate fixture did not release the held candidate' >&2
    return 1
  }
  gateway_wait_for_count "$events" 'candidate-published' 1 || {
    echo 'gateway dead-candidate fixture did not publish before candidate death' >&2
    return 1
  }
  set +e
  wait "$owner_pid"
  owner_rc=$?
  wait "$observer_pid"
  observer_rc=$?
  set -e
  records="$(find "$runtime_dir" -maxdepth 1 -type f \( -name 'process-*.pid' -o -name 'reservation-*' \) -print -quit)"
  if [[ "$owner_rc" -eq 0 || "$observer_rc" -eq 0 || -n "$records" || -e "$events/LOCK_FD_INHERITED" ||
        -n "$(grep -F 'gateway started' "$owner_receipt" "$observer_receipt" || true)" ]]; then
    echo 'gateway dead-candidate fixture accepted a vanished supervisor claim' >&2
    return 1
  fi
  if ! timeout 5 tail --pid="$candidate_pid" -f /dev/null 2>/dev/null; then
    echo 'gateway dead-candidate fixture did not owner-reap the direct candidate' >&2
    return 1
  fi
  child_pid="$(find "$events" -maxdepth 1 -type f -name 'gateway-start.*' -printf '%f\n' | sed 's/^gateway-start\.//')"
  if [[ ! "$child_pid" =~ ^[1-9][0-9]*$ ]] || \
     ! timeout 5 tail --pid="$child_pid" -f /dev/null 2>/dev/null; then
    echo 'gateway dead-candidate fixture left the published child process alive' >&2
    return 1
  fi
  for record in "$runtime_dir"/hermes-gateway-*.lock; do
    [[ -e "$record" ]] || continue
    flock -n "$record" true || {
      echo 'gateway dead-candidate fixture left its lock held' >&2
      return 1
    }
  done
  exec {release_fd}>&-
  cleanup_gateway_fixtures
  gateway_remove_service_fixture "$service"
  [[ ! -e "$case_dir" && ! -e "$fixture_dir" ]] || {
    echo 'gateway dead-candidate fixture cleanup failed' >&2
    return 1
  }
  echo 'PASS[GREEN-gateway-dead-candidate]: candidate-death refused; child-reaped records-clean'
  echo 'CLEANUP PASS: gateway dead-candidate fixture'
}

replace_identity_case() {
  local workspace_name="replace-identity"
  local runtime_parent runtime_dir legacy_dir
  local persist_match persist_cross match_state cross_state
  local role match_instance cross_instance match_record cross_record
  local cross_pid non_bwrap_pid cross_start non_bwrap_start
  local cross_line match_line wrong_line
  local replace_out replace_rc case_failed=0 cleanup_failed=0
  local lightweight_fixture_dir pid

  [[ -x "$WRAPPER" && -L "$WRAPPER" ]] || {
    echo "replace-identity requires an executable lightweight wrapper" >&2
    return 2
  }
  lightweight_fixture_dir="$(dirname "$WRAPPER")"
  [[ -f "$lightweight_fixture_dir/.ocsb-hermes-lightweight-fixture" ]] || {
    echo "replace-identity requires a wrapper built by --build-lightweight-wrapper" >&2
    return 2
  }
  LIGHTWEIGHT_FIXTURE_DIR="$lightweight_fixture_dir"
  : > "$lightweight_fixture_dir/fake-inner.log"
  chmod 0600 "$lightweight_fixture_dir/fake-inner.log"

  runtime_parent="$TMPDIR/runtime-parent"
  runtime_dir="$runtime_parent/ocsb-$(id -u)"
  legacy_dir="/tmp/ocsb"
  local legacy_pidfile="$legacy_dir/hermes-agent.pid"
  if [[ -e "$legacy_pidfile" || -L "$legacy_pidfile" ]]; then
    echo "replace-identity requires no pre-existing legacy pidfile: $legacy_pidfile" >&2
    return 2
  fi
  REPLACE_LEGACY_PIDFILE="$legacy_pidfile"
  if [[ ! -e "$legacy_dir" ]]; then
    install -d -m 0700 "$legacy_dir"
    REPLACE_LEGACY_DIR_CREATED=1
  elif [[ -L "$legacy_dir" || ! -d "$legacy_dir" || ! -w "$legacy_dir" ]]; then
    echo "replace-identity cannot safely create legacy pidfile under $legacy_dir" >&2
    return 2
  fi
  install -d -m 0700 "$runtime_parent" "$runtime_dir"

  persist_match="$TMPDIR/persist-match"
  persist_cross="$TMPDIR/persist-cross"
  match_state="$(realpath -m "$persist_match/state/$workspace_name")"
  cross_state="$(realpath -m "$persist_cross/state/$workspace_name")"
  role="sandbox:hermes-agent"
  match_instance="$(printf '%s\0%s' "$role" "$match_state" | sha256sum | cut -d ' ' -f1)"
  cross_instance="$(printf '%s\0%s' "$role" "$cross_state" | sha256sum | cut -d ' ' -f1)"
  match_record="$runtime_dir/process-$match_instance.pid"
  cross_record="$runtime_dir/process-$cross_instance.pid"

  sleep 60 &
  cross_pid=$!
  REPLACE_FIXTURE_PIDS+=("$cross_pid")
  sleep 60 &
  non_bwrap_pid=$!
  REPLACE_FIXTURE_PIDS+=("$non_bwrap_pid")
  cross_start="$(proc_start_time "$cross_pid")"
  non_bwrap_start="$(proc_start_time "$non_bwrap_pid")"
  cross_line="$(printf 'v1\t%s\t%s\t%s' "$cross_pid" "$cross_start" "$cross_instance")"
  match_line="$(printf 'v1\t%s\t%s\t%s' "$non_bwrap_pid" "$non_bwrap_start" "$match_instance")"
  printf '%s\n' "$cross_pid" > "$REPLACE_LEGACY_PIDFILE"
  chmod 0600 "$REPLACE_LEGACY_PIDFILE"
  printf '%s\n' "$cross_line" > "$cross_record"
  chmod 0600 "$cross_record"
  printf '%s\n' "$match_line" > "$match_record"
  chmod 0600 "$match_record"

  set +e
  replace_out="$(env -u XDG_RUNTIME_DIR TMPDIR="$runtime_parent" \
    HERMES_FAKE_INNER_LOG="$lightweight_fixture_dir/fake-inner.log" \
    "$WRAPPER" --persist-dir "$persist_match" --workspace ignored -w "$workspace_name" \
    --gateway --replace 2>&1)"
  replace_rc=$?
  set -e

  if ! kill -0 "$cross_pid" 2>/dev/null || ! kill -0 "$non_bwrap_pid" 2>/dev/null; then
    echo "FAIL[RED-hermes-replace-identity]: cross-persist or non-bwrap fixture was signaled" >&2
    case_failed=1
  else
    if [[ "$replace_rc" -eq 0 ]]; then
      echo "FAIL: --replace succeeded despite a matching non-bwrap record" >&2
      case_failed=1
    fi
    if ! grep -Fq "ocsb-hermes: refusing --replace:" <<<"$replace_out"; then
      echo "FAIL: --replace did not emit the required refusal prefix" >&2
      case_failed=1
    fi
    if ! grep -Fqi "not a bwrap" <<<"$replace_out"; then
      echo "FAIL: --replace did not validate the last workspace's non-bwrap record" >&2
      case_failed=1
    fi
    if [[ -s "$lightweight_fixture_dir/fake-inner.log" ]]; then
      echo "FAIL: replacement launched the fake inner launcher after refusal" >&2
      case_failed=1
    fi
  fi

  wrong_line="${cross_line%?}0"
  if [[ "$wrong_line" == "$cross_line" ]]; then
    wrong_line="${cross_line%?}1"
  fi
  if remove_record_if_line_matches "$cross_record" "$wrong_line" || [[ ! -f "$cross_record" ]]; then
    echo "FAIL: cross-persist record was removed without a full-line CAS match" >&2
    case_failed=1
  fi
  if ! remove_record_if_line_matches "$cross_record" "$cross_line"; then
    echo "FAIL: cross-persist record was not removed by its full-line CAS match" >&2
    case_failed=1
  fi
  wrong_line="${match_line%?}0"
  if [[ "$wrong_line" == "$match_line" ]]; then
    wrong_line="${match_line%?}1"
  fi
  if remove_record_if_line_matches "$match_record" "$wrong_line" || [[ ! -f "$match_record" ]]; then
    echo "FAIL: matching record was removed without a full-line CAS match" >&2
    case_failed=1
  fi
  if ! remove_record_if_line_matches "$match_record" "$match_line"; then
    echo "FAIL: matching record was not removed by its full-line CAS match" >&2
    case_failed=1
  fi

  cleanup_replace_identity_fixtures
  for pid in "$cross_pid" "$non_bwrap_pid"; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "FAIL: fixture PID remained live after cleanup: $pid" >&2
      cleanup_failed=1
    fi
  done
  if [[ -e "$runtime_dir/process-$cross_instance.pid" || -e "$runtime_dir/process-$match_instance.pid" || -e "$legacy_dir/hermes-agent.pid" ]]; then
    echo "FAIL: Hermes replace fixture record remained after cleanup" >&2
    cleanup_failed=1
  fi
  if [[ -e "$lightweight_fixture_dir" ]]; then
    echo "FAIL: lightweight Hermes fixture directory remained after cleanup" >&2
    cleanup_failed=1
  fi

  if [[ "$case_failed" -ne 0 || "$cleanup_failed" -ne 0 ]]; then
    return 1
  fi
  echo "PASS[GREEN-hermes-replace-identity]: fixtures alive; replacement refused"
  echo "CLEANUP PASS: hermes replace fixtures"
  echo "CLEANUP DETAIL: fixture PIDs dead: $cross_pid $non_bwrap_pid; directory removed: $lightweight_fixture_dir"
}

caller_file_secret_case() {
  local lightweight_fixture_dir case_dir caller_file inner_log
  local before_hash before_mtime before_mode after_hash after_mtime after_mode
  local secret_value="green-deterministic-secret"
  local reject_out reject_rc caller_only_rc non_secret_rc
  local case_failed=0

  [[ -x "$WRAPPER" && -L "$WRAPPER" ]] || {
    echo "caller-file-secret requires an executable lightweight wrapper" >&2
    return 2
  }
  lightweight_fixture_dir="$(dirname "$WRAPPER")"
  [[ -f "$lightweight_fixture_dir/.ocsb-hermes-lightweight-fixture" ]] || {
    echo "caller-file-secret requires a wrapper built by --build-lightweight-wrapper" >&2
    return 2
  }
  LIGHTWEIGHT_FIXTURE_DIR="$lightweight_fixture_dir"
  case_dir="$TMPDIR/caller-file-secret"
  install -d -m 0700 "$case_dir"
  caller_file="$case_dir/caller-api-keys.env"
  inner_log="$lightweight_fixture_dir/fake-inner.log"
  printf 'export OPENROUTER_API_KEY=caller-controlled\n' > "$caller_file"
  chmod 0400 "$caller_file"
  before_hash="$(sha256sum "$caller_file" | awk '{print $1}')"
  before_mtime="$(stat -c %y "$caller_file")"
  before_mode="$(stat -c %a "$caller_file")"

  : > "$inner_log"
  chmod 0600 "$inner_log"
  set +e
  reject_out="$(HERMES_FAKE_INNER_LOG="$inner_log" "$WRAPPER" \
    --persist-dir "$case_dir/persist-reject" \
    --api-keys-env-file "$caller_file" \
    --env CUSTOM_PROVIDER_TOKEN="$secret_value" 2>&1)"
  reject_rc=$?
  set -e

  if [[ "$reject_rc" -ne 2 ]]; then
    echo "FAIL: caller file plus explicit secret-like --env did not exit 2" >&2
    case_failed=1
  fi
  if ! grep -Fq 'CUSTOM_PROVIDER_TOKEN' <<<"$reject_out"; then
    echo "FAIL: caller file refusal did not name CUSTOM_PROVIDER_TOKEN" >&2
    case_failed=1
  fi
  if ! grep -Fq 'merge CUSTOM_PROVIDER_TOKEN into --api-keys-env-file' <<<"$reject_out"; then
    echo "FAIL: caller file refusal did not provide merge guidance" >&2
    case_failed=1
  fi
  if grep -Fq "$secret_value" <<<"$reject_out" || grep -Fq "$secret_value" "$inner_log"; then
    echo "FAIL: caller file refusal exposed an explicit secret value" >&2
    case_failed=1
  fi
  if [[ -s "$inner_log" ]]; then
    echo "FAIL: caller file refusal invoked the inner launcher" >&2
    case_failed=1
  fi

  : > "$inner_log"
  HERMES_FAKE_INNER_LOG="$inner_log" "$WRAPPER" \
    --persist-dir "$case_dir/persist-caller-only" \
    --api-keys-env-file "$caller_file"
  caller_only_rc=$?
  if [[ "$caller_only_rc" -ne 0 ]] || [[ ! -s "$inner_log" ]] || \
    ! grep -Fq -- "--ro $caller_file:/tmp/ocsb-hermes-agent-api-keys.env" "$inner_log"; then
    echo "FAIL: caller file alone was not passed read-only to the inner launcher" >&2
    case_failed=1
  fi

  : > "$inner_log"
  HERMES_FAKE_INNER_LOG="$inner_log" "$WRAPPER" \
    --persist-dir "$case_dir/persist-non-secret" \
    --api-keys-env-file "$caller_file" \
    --env FOO=bar
  non_secret_rc=$?
  if [[ "$non_secret_rc" -ne 0 ]] || [[ ! -s "$inner_log" ]] || \
    ! grep -Fq -- '--env FOO=bar' "$inner_log"; then
    echo "FAIL: caller file plus non-secret --env did not reach the inner launcher" >&2
    case_failed=1
  fi

  after_hash="$(sha256sum "$caller_file" | awk '{print $1}')"
  after_mtime="$(stat -c %y "$caller_file")"
  after_mode="$(stat -c %a "$caller_file")"
  if [[ "$before_hash" != "$after_hash" || "$before_mtime" != "$after_mtime" || "$before_mode" != "$after_mode" ]]; then
    echo "FAIL: caller-provided API key file changed during lightweight checks" >&2
    case_failed=1
  fi

  cleanup_replace_identity_fixtures
  rm -rf -- "$case_dir"
  if [[ -e "$case_dir" || -e "$lightweight_fixture_dir" ]]; then
    echo "FAIL: caller-file secret lightweight fixtures remained after cleanup" >&2
    case_failed=1
  fi

  if [[ "$case_failed" -ne 0 ]]; then
    return 1
  fi
  echo "PASS[GREEN-hermes-caller-file-secret]: nonzero merge diagnostic; caller hash unchanged; launcher log empty"
  echo "CLEANUP PASS: hermes caller-file secret fixtures"
}

if [[ "$TEST_CASE" != "all" ]]; then
  case "$TEST_CASE" in
    gateway-reservation)
      gateway_reservation_case
      ;;
    gateway-dead-candidate)
      gateway_dead_candidate_case
      ;;
    replace-identity)
      replace_identity_case
      ;;
    caller-file-secret)
      caller_file_secret_case
      ;;
    *)
      echo "unknown test case: $TEST_CASE" >&2
      exit 2
      ;;
  esac
  exit
fi

is_real_bwrap_capability_denial() {
  grep -Eq \
    'Creating new namespace failed: Operation not permitted|No permissions to create new namespace|RTM_NEWADDR.*Operation not permitted' \
    <<<"$1"
}

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
set +e
SMOKE_OUTPUT="$("$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_MAIN" -- --version 2>&1)"
SMOKE_RC=$?
set -e
printf '%s\n' "$SMOKE_OUTPUT"
if [[ "$SMOKE_RC" -ne 0 ]]; then
  if is_real_bwrap_capability_denial "$SMOKE_OUTPUT"; then
    echo 'SKIP[CI-REQUIRED-hermes-real-bwrap]: userns or RTM_NEWADDR unavailable'
    exit 0
  fi
  exit "$SMOKE_RC"
fi

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

if [[ "${TERMINAL_CWD:-}" != "/home/sandbox" ]]; then
  echo "expected TERMINAL_CWD=/home/sandbox, got ${TERMINAL_CWD:-<unset>}" >&2
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
RES_MSG_CWD_OUT="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_MAIN" --env TERMINAL_CWD=/tmp/nope -- --version 2>&1)"
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
assert "reserved TERMINAL_CWD fails" test "$RES_MSG_CWD_RC" -ne 0
assert_contains "reserved TERMINAL_CWD message" "$RES_MSG_CWD_OUT" "reserved for the Hermes Agent wrapper"
assert "reserved OCSB_HERMES_NO_GATEWAY fails" test "$RES_NO_GATEWAY_RC" -ne 0
assert_contains "reserved OCSB_HERMES_NO_GATEWAY message" "$RES_NO_GATEWAY_OUT" "reserved for the Hermes Agent wrapper"

echo ""
echo "=== hermes-agent Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
