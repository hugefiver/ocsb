#!/usr/bin/env bash
# Deterministic filtered-network ownership and cleanup regression harness.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ALLOWED_SKIP="SKIP[CI-REQUIRED-real-filtered-network]: userns or RTM_NEWADDR unavailable"

CASE_DIR=""
DRIVER_PID=""
TEMP_FIXTURE=""
declare -a CLEANUP_PIDS=()
declare -a CLEANUP_STARTS=()

usage() {
  cat >&2 <<'EOF'
usage:
  tests/test_filtered_cleanup.sh --prepare FIXTURE
  tests/test_filtered_cleanup.sh --case monitor-topology LAUNCHER
  tests/test_filtered_cleanup.sh --case real-secondary NET-LAUNCHER
  tests/test_filtered_cleanup.sh --ci-fake

FIXTURE must be an absolute path outside this checkout.
EOF
  exit 2
}

proc_field() {
  local pid="$1"
  local wanted="$2"
  local stat rest field index=1

  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/stat" ]] || return 1
  IFS= read -r stat < "/proc/$pid/stat" || return 1
  rest="${stat##*) }"
  for field in $rest; do
    if [[ "$index" -eq "$wanted" ]]; then
      printf '%s\n' "$field"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

proc_start() {
  proc_field "$1" 20
}

proc_state() {
  proc_field "$1" 1
}

proc_pgid() {
  proc_field "$1" 3
}

exact_process_live() {
  local pid="$1"
  local start="$2"
  local actual state

  actual="$(proc_start "$pid" 2>/dev/null)" || return 1
  [[ "$actual" == "$start" ]] || return 1
  state="$(proc_state "$pid" 2>/dev/null)" || return 1
  [[ "$state" != Z && "$state" != X && "$state" != x ]]
}

wait_for_file() {
  local path="$1"
  local attempts="${2:-1000}"
  local attempt

  for ((attempt = 0; attempt < attempts; attempt++)); do
    [[ -e "$path" ]] && return 0
    sleep 0.01
  done
  return 1
}

wait_for_exact_process_gone() {
  local pid="$1"
  local start="$2"
  local attempt actual

  for ((attempt = 0; attempt < 1000; attempt++)); do
    actual="$(proc_start "$pid" 2>/dev/null)" || return 0
    [[ "$actual" == "$start" ]] || return 0
    sleep 0.01
  done
  return 1
}

wait_for_zombie_or_dead() {
  local pid="$1"
  local start="$2"
  local attempt actual state

  for ((attempt = 0; attempt < 1000; attempt++)); do
    actual="$(proc_start "$pid" 2>/dev/null)" || return 1
    [[ "$actual" == "$start" ]] || return 1
    state="$(proc_state "$pid" 2>/dev/null)" || return 1
    [[ "$state" == Z || "$state" == X || "$state" == x ]] && return 0
    sleep 0.01
  done
  return 1
}

process_has_lock_fd() {
  local pid="$1"
  local lock_file="$2"
  local fd target

  [[ -d "/proc/$pid/fd" ]] || return 1
  for fd in "/proc/$pid/fd"/*; do
    [[ -e "$fd" ]] || continue
    target="$(readlink -f -- "$fd" 2>/dev/null || true)"
    [[ "$target" == "$lock_file" ]] && return 0
  done
  return 1
}

directory_empty() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  [[ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

remember_process() {
  local pid="$1"
  local start="$2"

  [[ "$pid" =~ ^[1-9][0-9]*$ && "$start" =~ ^[1-9][0-9]*$ ]] || return 1
  CLEANUP_PIDS+=("$pid")
  CLEANUP_STARTS+=("$start")
}

children_of() {
  local parent="$1"
  local stat_path pid ppid

  for stat_path in /proc/[1-9]*/stat; do
    [[ -r "$stat_path" ]] || continue
    pid="${stat_path#/proc/}"
    pid="${pid%/stat}"
    ppid="$(proc_field "$pid" 2 2>/dev/null)" || continue
    [[ "$ppid" == "$parent" ]] && printf '%s\n' "$pid"
  done
}

proc_comm() {
  local pid="$1"
  local comm
  IFS= read -r comm < "/proc/$pid/comm" || return 1
  printf '%s\n' "$comm"
}

canonical_external_path() {
  local requested="$1"
  local resolved

  [[ "$requested" == /* ]] || {
    echo "test_filtered_cleanup: path must be absolute" >&2
    return 2
  }
  resolved="$(realpath -m -- "$requested")"
  case "$resolved" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
      echo "test_filtered_cleanup: refusing path inside repository" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$resolved"
}

cleanup() {
  local attempt index pid start actual

  if [[ -n "$CASE_DIR" && -d "$CASE_DIR/protocol" ]]; then
    : > "$CASE_DIR/protocol/BWRAP_EXIT_ALLOWED" 2>/dev/null || true
    : > "$CASE_DIR/protocol/CALLER_REAP_ALLOWED" 2>/dev/null || true
  fi
  if [[ -n "$DRIVER_PID" ]] && kill -0 "$DRIVER_PID" 2>/dev/null; then
    for ((attempt = 0; attempt < 200; attempt++)); do
      kill -0 "$DRIVER_PID" 2>/dev/null || break
      sleep 0.01
    done
    kill -TERM "$DRIVER_PID" 2>/dev/null || true
    wait "$DRIVER_PID" 2>/dev/null || true
  fi
  DRIVER_PID=""
  for ((index = 0; index < ${#CLEANUP_PIDS[@]}; index++)); do
    pid="${CLEANUP_PIDS[$index]}"
    start="${CLEANUP_STARTS[$index]}"
    actual="$(proc_start "$pid" 2>/dev/null)" || continue
    [[ "$actual" == "$start" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
    for ((attempt = 0; attempt < 200; attempt++)); do
      actual="$(proc_start "$pid" 2>/dev/null)" || break
      [[ "$actual" == "$start" ]] || break
      sleep 0.01
    done
    actual="$(proc_start "$pid" 2>/dev/null)" || continue
    [[ "$actual" == "$start" ]] && kill -KILL "$pid" 2>/dev/null || true
  done
  CLEANUP_PIDS=()
  CLEANUP_STARTS=()
  if [[ -n "$CASE_DIR" ]]; then
    find "$CASE_DIR" -type d -exec chmod u+w -- {} + 2>/dev/null || true
    rm -rf -- "$CASE_DIR"
    CASE_DIR=""
  fi
  if [[ -n "$TEMP_FIXTURE" ]]; then
    rm -rf -- "$TEMP_FIXTURE"
    TEMP_FIXTURE=""
  fi
}
trap cleanup EXIT HUP INT TERM

prepare_fixture() {
  local fixture build_file output

  fixture="$(canonical_external_path "$1")"
  command -v nix >/dev/null 2>&1 || {
    echo "test_filtered_cleanup: nix is required" >&2
    return 1
  }
  install -d -m 0700 -- "$fixture"

  cat > "$fixture/nonreaping-caller.c" <<'EOF'
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static pid_t child = -1;

static void stop_child(int signal_number) {
  (void)signal_number;
  if (child > 0) {
    kill(child, SIGTERM);
    waitpid(child, NULL, 0);
  }
  _exit(128 + SIGTERM);
}

static void write_value(const char *dir, const char *name, long value) {
  char temp[4096];
  char final[4096];
  FILE *stream;
  if (snprintf(temp, sizeof(temp), "%s/%s.tmp", dir, name) >= (int)sizeof(temp) ||
      snprintf(final, sizeof(final), "%s/%s", dir, name) >= (int)sizeof(final)) {
    _exit(111);
  }
  stream = fopen(temp, "w");
  if (stream == NULL || fprintf(stream, "%ld\n", value) < 0 || fclose(stream) != 0 ||
      rename(temp, final) != 0) {
    _exit(111);
  }
}

int main(int argc, char **argv) {
  char barrier[4096];
  struct stat ignored;
  struct timespec pause = { .tv_sec = 0, .tv_nsec = 10000000L };
  int status;

  if (argc < 4 || strcmp(argv[2], "--") != 0 ||
      snprintf(barrier, sizeof(barrier), "%s/CALLER_REAP_ALLOWED", argv[1]) >= (int)sizeof(barrier)) {
    fprintf(stderr, "usage: nonreaping-caller PROTOCOL -- COMMAND [ARG...]\n");
    return 2;
  }
  signal(SIGTERM, stop_child);
  signal(SIGINT, stop_child);
  signal(SIGHUP, stop_child);
  child = fork();
  if (child < 0) {
    perror("fork");
    return 111;
  }
  if (child == 0) {
    execvp(argv[3], &argv[3]);
    perror("execvp");
    _exit(127);
  }
  write_value(argv[1], "CALLER_CHILD", (long)child);
  while (stat(barrier, &ignored) != 0) {
    if (errno != ENOENT) {
      perror("stat barrier");
      stop_child(SIGTERM);
    }
    nanosleep(&pause, NULL);
  }
  if (waitpid(child, &status, 0) != child) {
    perror("waitpid");
    return 111;
  }
  if (WIFEXITED(status)) {
    write_value(argv[1], "CALLER_STATUS", WEXITSTATUS(status));
    return WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    write_value(argv[1], "CALLER_STATUS", 128 + WTERMSIG(status));
    return 128 + WTERMSIG(status);
  }
  return 111;
}
EOF

  build_file="$fixture/build-filtered-cleanup.nix"
  cat > "$build_file" <<'EOF'
let
  repo = builtins.getEnv "OCSB_FILTERED_REPO";
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  fakeBwrapSource = builtins.path {
    path = builtins.toPath (repo + "/tests/fixtures/fake-filtered-bwrap.sh");
    name = "fake-filtered-bwrap.sh";
  };
  fakeSlirpSource = builtins.path {
    path = builtins.toPath (repo + "/tests/fixtures/fake-slirp4netns.sh");
    name = "fake-slirp4netns.sh";
  };
  callerSource = builtins.path {
    path = builtins.toPath (builtins.getEnv "OCSB_FILTERED_CALLER_SOURCE");
    name = "nonreaping-caller.c";
  };
  fakeBubblewrap = pkgs.writeShellApplication {
    name = "bwrap";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
    text = builtins.readFile fakeBwrapSource;
  };
  fakeSlirp4netns = pkgs.writeShellApplication {
    name = "slirp4netns";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile fakeSlirpSource;
  };
  fakePkgs = import flake.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ (_: _: {
      bubblewrap = fakeBubblewrap;
      slirp4netns = fakeSlirp4netns;
    }) ];
  };
  mkSandbox = import (flake.outPath + "/lib/mkSandbox.nix") {
    pkgs = fakePkgs;
    lib = fakePkgs.lib;
  };
  launcher = mkSandbox {
    app.name = "ocsb-filtered-cleanup-test";
    packages = [ fakePkgs.coreutils ];
    workspace = {
      strategy = "direct";
      baseDir = ".ocsb";
      name = "filtered-cleanup";
    };
    network.enable = true;
    env = { };
    mounts = { ro = [ ]; rw = [ ]; };
  };
  caller = pkgs.stdenv.mkDerivation {
    name = "ocsb-filtered-nonreaping-caller";
    src = callerSource;
    dontUnpack = true;
    dontConfigure = true;
    buildPhase = ''
      $CC -std=c17 -Wall -Wextra -Werror "$src" -o nonreaping-caller
    '';
    installPhase = ''
      install -Dm0755 nonreaping-caller "$out/bin/nonreaping-caller"
    '';
  };
in pkgs.symlinkJoin {
  name = "ocsb-filtered-cleanup-fixture";
  paths = [ launcher caller ];
}
EOF

  output="$(
    OCSB_FILTERED_REPO="$REPO_ROOT" \
    OCSB_FILTERED_CALLER_SOURCE="$fixture/nonreaping-caller.c" \
      nix build --impure --no-link --print-out-paths --file "$build_file"
  )"
  [[ -x "$output/bin/ocsb-filtered-cleanup-test" && \
     -x "$output/bin/nonreaping-caller" ]] || {
    echo "test_filtered_cleanup: prepared fixture is incomplete" >&2
    return 1
  }
  printf '%s\n' "$output/bin/ocsb-filtered-cleanup-test"
}

monitor_topology_case() {
  local launcher="$1"
  local fixture_bin caller
  local protocol project state_root tmp_root lock_file launcher_log
  local launcher_pid launcher_start_before launcher_pgid_before launcher_state
  local b_version b_pid b_start b_pgid net_tmp ready_present ready_version
  local monitor_pid monitor_start ready_launcher_pid ready_launcher_start ready_launcher_pgid
  local s_version slirp_pid slirp_start slirp_ppid slirp_pgid slirp_lock monitor_lock
  local temp_parent status owner_failed=0 zombie_failed=0

  [[ -x "$launcher" ]] || {
    echo "test_filtered_cleanup: launcher is not executable: $launcher" >&2
    return 1
  }
  fixture_bin="$(cd -- "$(dirname -- "$launcher")" && pwd -P)"
  caller="$fixture_bin/nonreaping-caller"
  [[ -x "$caller" ]] || {
    echo "test_filtered_cleanup: nonreaping caller missing beside launcher" >&2
    return 1
  }

  CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ocsb-filtered-case.XXXXXX")"
  chmod 0700 "$CASE_DIR"
  protocol="$CASE_DIR/protocol"
  project="$CASE_DIR/project"
  state_root="$CASE_DIR/state"
  tmp_root="$CASE_DIR/tmp"
  launcher_log="$CASE_DIR/launcher.log"
  install -d -m 0700 -- "$protocol" "$project" "$state_root" "$tmp_root"
  lock_file="$state_root/filtered-cleanup/.lock"

  (
    cd -- "$project"
    exec env \
      TMPDIR="$tmp_root" \
      OCSB_STATE_BASE_DIR="$state_root" \
      OCSB_FILTERED_CASE_DIR="$protocol" \
      OCSB_FILTERED_SEARCH_ROOT="$tmp_root" \
      OCSB_FILTERED_LOCK_FILE="$lock_file" \
      "$caller" "$protocol" -- \
      "$launcher" -w filtered-cleanup --overwrite -- -c true
  ) >"$launcher_log" 2>&1 &
  DRIVER_PID=$!

  wait_for_file "$protocol/CALLER_CHILD" || {
    cat "$launcher_log" >&2
    echo "test_filtered_cleanup: caller did not publish launcher pid" >&2
    return 1
  }
  IFS= read -r launcher_pid < "$protocol/CALLER_CHILD"
  launcher_start_before="$(proc_start "$launcher_pid")"
  launcher_pgid_before="$(proc_pgid "$launcher_pid")"
  remember_process "$launcher_pid" "$launcher_start_before"

  wait_for_file "$protocol/BWRAP_STARTED" || {
    cat "$launcher_log" >&2
    echo "test_filtered_cleanup: fake bwrap did not start" >&2
    return 1
  }
  wait_for_file "$protocol/SLIRP_STARTED" || {
    cat "$launcher_log" >&2
    echo "test_filtered_cleanup: fake slirp did not start" >&2
    return 1
  }

  IFS=$'\t' read -r b_version b_pid b_start b_pgid net_tmp ready_present \
    ready_version monitor_pid monitor_start ready_launcher_pid \
    ready_launcher_start ready_launcher_pgid < "$protocol/bwrap-record"
  IFS=$'\t' read -r s_version slirp_pid slirp_start slirp_ppid slirp_pgid \
    slirp_lock monitor_lock < "$protocol/slirp-record"
  remember_process "$slirp_pid" "$slirp_start"

  [[ "$b_version" == v1 && "$s_version" == v1 ]]
  [[ "$b_pid" == "$launcher_pid" && "$b_start" == "$launcher_start_before" && \
     "$b_pgid" == "$launcher_pgid_before" ]] || {
    echo "test_filtered_cleanup: launcher PID/start/PGID changed across bwrap exec" >&2
    return 1
  }

  if [[ "$ready_present" -eq 1 ]]; then
    [[ "$ready_version" == v1 && "$monitor_pid" =~ ^[1-9][0-9]*$ && \
       "$monitor_start" =~ ^[1-9][0-9]*$ && \
       "$ready_launcher_pid" == "$launcher_pid" && \
       "$ready_launcher_start" == "$launcher_start_before" && \
       "$ready_launcher_pgid" == "$launcher_pgid_before" ]] || {
      echo "test_filtered_cleanup: malformed or mismatched MONITOR_READY receipt" >&2
      return 1
    }
    [[ "$(proc_start "$monitor_pid")" == "$monitor_start" ]] || {
      echo "test_filtered_cleanup: monitor identity changed before assertion" >&2
      return 1
    }
    remember_process "$monitor_pid" "$monitor_start"
    [[ "$slirp_ppid" == "$monitor_pid" ]] || {
      echo "test_filtered_cleanup: slirp is not a direct monitor child" >&2
      return 1
    }
    [[ "$slirp_lock" == closed && "$monitor_lock" == closed ]] || {
      echo "test_filtered_cleanup: fake slirp observed inherited workspace lock" >&2
      return 1
    }
    process_has_lock_fd "$monitor_pid" "$lock_file" && {
      echo "test_filtered_cleanup: monitor retains workspace lock fd" >&2
      return 1
    }
  else
    if [[ "$slirp_ppid" == "$launcher_pid" ]]; then
      echo "FAIL[RED-filtered-monitor-owner]: slirp parent is launcher, not monitor" >&2
      owner_failed=1
    else
      echo "test_filtered_cleanup: baseline slirp parent was neither launcher nor a ready monitor" >&2
      return 1
    fi
  fi

  : > "$protocol/BWRAP_EXIT_ALLOWED"
  wait_for_zombie_or_dead "$launcher_pid" "$launcher_start_before" || {
    cat "$launcher_log" >&2
    echo "test_filtered_cleanup: launcher was not observable as Z/X before caller wait" >&2
    return 1
  }
  launcher_state="$(proc_state "$launcher_pid")"
  [[ "$launcher_state" == Z || "$launcher_state" == X || "$launcher_state" == x ]]

  temp_parent="${net_tmp%/*}"
  if [[ "$ready_present" -eq 0 ]]; then
    if [[ -e "$net_tmp" ]]; then
      echo "FAIL[RED-filtered-zombie-cleanup]: FIFO/temp remain while bwrap state is Z" >&2
      zombie_failed=1
    else
      echo "test_filtered_cleanup: old topology unexpectedly removed network temp" >&2
      return 1
    fi
    : > "$protocol/CALLER_REAP_ALLOWED"
    wait "$DRIVER_PID" || status=$?
    DRIVER_PID=""
    status="${status:-0}"
    [[ "$status" -eq 0 ]]
    [[ "$owner_failed" -eq 1 && "$zombie_failed" -eq 1 ]]
    return 1
  fi

  wait_for_file "$protocol/SLIRP_SIGNAL" || {
    cat "$launcher_log" >&2
    echo "test_filtered_cleanup: monitor did not terminate slirp" >&2
    return 1
  }
  wait_for_exact_process_gone "$slirp_pid" "$slirp_start" || {
    echo "test_filtered_cleanup: slirp process was not reaped" >&2
    return 1
  }
  wait_for_exact_process_gone "$monitor_pid" "$monitor_start" || {
    echo "test_filtered_cleanup: monitor remained after cleanup" >&2
    return 1
  }
  for _ in {1..1000}; do
    [[ ! -e "$net_tmp" ]] && directory_empty "$temp_parent" && break
    sleep 0.01
  done
  [[ ! -e "$net_tmp" ]] || {
    echo "test_filtered_cleanup: network temp directory remains" >&2
    return 1
  }
  directory_empty "$temp_parent" || {
    echo "test_filtered_cleanup: network temp parent is not empty" >&2
    return 1
  }

  : > "$protocol/CALLER_REAP_ALLOWED"
  wait "$DRIVER_PID"
  DRIVER_PID=""
  IFS= read -r status < "$protocol/CALLER_STATUS"
  [[ "$status" -eq 0 ]]
  [[ ! -e "/proc/$launcher_pid" && ! -e "/proc/$monitor_pid" && ! -e "/proc/$slirp_pid" ]]

  printf 'TOPOLOGY: launcher=%s/%s pgid=%s monitor=%s/%s slirp=%s/%s ppid=%s\n' \
    "$launcher_pid" "$launcher_start_before" "$launcher_pgid_before" \
    "$monitor_pid" "$monitor_start" "$slirp_pid" "$slirp_start" "$slirp_ppid"
  echo "PASS[GREEN-filtered-monitor]: owner=monitor fd9=closed zombie=recognized slirp=reaped temp=removed"
  echo "CLEANUP PASS: filtered network temp"
}

real_secondary_case() {
  local launcher="$1"
  local run index output status state_root tmp_root project network_parent lock_file
  local wrapper_pid wrapper_start monitor_pid monitor_start slirp_pid slirp_start
  local child grandchild child_comm grandchild_comm output_file attempt

  [[ -x "$launcher" ]] || {
    echo "test_filtered_cleanup: net launcher is not executable: $launcher" >&2
    return 1
  }
  CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ocsb-filtered-real.XXXXXX")"
  chmod 0700 "$CASE_DIR"
  state_root="$CASE_DIR/state"
  tmp_root="$CASE_DIR/tmp"
  project="$REPO_ROOT"
  install -d -m 0700 -- "$state_root" "$tmp_root"
  network_parent="$tmp_root/ocsb-$(id -u)/filtered-network"
  lock_file="$state_root/filtered-real/.lock"

  for index in 1 2; do
    if [[ "$index" -eq 1 ]]; then
      run=(--overwrite)
    else
      run=(--continue)
    fi
    output_file="$CASE_DIR/real-$index.log"
    (
      cd -- "$project"
      exec env TMPDIR="$tmp_root" OCSB_STATE_BASE_DIR="$state_root" \
        "$launcher" -w filtered-real "${run[@]}" -- \
        bash /workspace/tests/test_network.sh
    ) >"$output_file" 2>&1 &
    wrapper_pid=$!
    wrapper_start=""
    for ((attempt = 0; attempt < 100; attempt++)); do
      wrapper_start="$(proc_start "$wrapper_pid" 2>/dev/null)" && break
      sleep 0.01
    done
    [[ -n "$wrapper_start" ]] || {
      echo "test_filtered_cleanup: cannot capture real launcher identity" >&2
      return 1
    }
    remember_process "$wrapper_pid" "$wrapper_start"

    monitor_pid=""
    monitor_start=""
    slirp_pid=""
    slirp_start=""
    for ((attempt = 0; attempt < 1000; attempt++)); do
      while IFS= read -r child; do
        child_comm="$(proc_comm "$child" 2>/dev/null)" || continue
        [[ "$child_comm" != bwrap ]] || continue
        monitor_pid="$child"
        monitor_start="$(proc_start "$monitor_pid" 2>/dev/null)" || {
          monitor_pid=""
          continue
        }
        while IFS= read -r grandchild; do
          grandchild_comm="$(proc_comm "$grandchild" 2>/dev/null)" || continue
          if [[ "$grandchild_comm" == slirp4netns ]]; then
            slirp_pid="$grandchild"
            slirp_start="$(proc_start "$slirp_pid" 2>/dev/null)" || slirp_pid=""
            break
          fi
        done < <(children_of "$monitor_pid")
        [[ -n "$slirp_pid" ]] && break
      done < <(children_of "$wrapper_pid")
      [[ -n "$monitor_pid" && -n "$slirp_pid" ]] && break
      exact_process_live "$wrapper_pid" "$wrapper_start" || break
      sleep 0.01
    done
    if [[ -n "$monitor_pid" ]]; then
      remember_process "$monitor_pid" "$monitor_start"
      process_has_lock_fd "$monitor_pid" "$lock_file" && {
        echo "test_filtered_cleanup: real monitor retains workspace lock fd" >&2
        return 1
      }
    fi
    if [[ -n "$slirp_pid" ]]; then
      remember_process "$slirp_pid" "$slirp_start"
      [[ "$(proc_field "$slirp_pid" 2)" == "$monitor_pid" ]] || {
        echo "test_filtered_cleanup: real slirp is not a direct monitor child" >&2
        return 1
      }
      process_has_lock_fd "$slirp_pid" "$lock_file" && {
        echo "test_filtered_cleanup: real slirp retains workspace lock fd" >&2
        return 1
      }
    fi

    set +e
    wait "$wrapper_pid"
    status=$?
    set -e
    output="$(< "$output_file")"
    printf '%s\n' "$output"

    wait_for_exact_process_gone "$wrapper_pid" "$wrapper_start" || {
      echo "test_filtered_cleanup: real launcher remains after wait" >&2
      return 1
    }
    if [[ -n "$slirp_pid" ]]; then
      wait_for_exact_process_gone "$slirp_pid" "$slirp_start" || {
        echo "test_filtered_cleanup: real slirp remains after launcher exit" >&2
        return 1
      }
    fi
    if [[ -n "$monitor_pid" ]]; then
      wait_for_exact_process_gone "$monitor_pid" "$monitor_start" || {
        echo "test_filtered_cleanup: real monitor remains after launcher exit" >&2
        return 1
      }
    fi

    if [[ "$status" -ne 0 ]]; then
      if grep -Eq 'Creating new namespace failed: Operation not permitted|No permissions to create new namespace|RTM_NEWADDR.*Operation not permitted' <<< "$output"; then
        for _ in {1..500}; do
          [[ ! -d "$network_parent" ]] || directory_empty "$network_parent" || {
            sleep 0.01
            continue
          }
          break
        done
        if [[ -d "$network_parent" ]]; then
          directory_empty "$network_parent" || {
            echo "test_filtered_cleanup: network temp leaked during capability skip" >&2
            return 1
          }
        fi
        echo "$ALLOWED_SKIP"
        echo "CLEANUP PASS: filtered network temp"
        return 0
      fi
      echo "test_filtered_cleanup: real filtered-network run $index failed with status $status" >&2
      return "$status"
    fi

    [[ -n "$monitor_pid" && -n "$slirp_pid" ]] || {
      echo "test_filtered_cleanup: could not save real monitor/slirp identities" >&2
      return 1
    }

    for _ in {1..1000}; do
      [[ -d "$network_parent" ]] && ! directory_empty "$network_parent" || break
      sleep 0.01
    done
    if [[ -d "$network_parent" ]]; then
      directory_empty "$network_parent" || {
        echo "test_filtered_cleanup: network temp leaked after real run $index" >&2
        return 1
      }
    fi
    printf 'REAL TOPOLOGY %s: launcher=%s/%s monitor=%s/%s slirp=%s/%s ppid=%s\n' \
      "$index" "$wrapper_pid" "$wrapper_start" "$monitor_pid" "$monitor_start" \
      "$slirp_pid" "$slirp_start" "$monitor_pid"
  done

  echo "PASS: real filtered network completed twice with second lock acquisition"
  echo "CLEANUP PASS: filtered network temp"
}

ci_fake_case() {
  local launcher

  TEMP_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/ocsb-filtered-fixture.XXXXXX")"
  launcher="$(prepare_fixture "$TEMP_FIXTURE")"
  monitor_topology_case "$launcher"
}

case "${1:-}" in
  --prepare)
    [[ $# -eq 2 ]] || usage
    prepare_fixture "$2"
    ;;
  --case)
    [[ $# -eq 3 ]] || usage
    case "$2" in
      monitor-topology) monitor_topology_case "$3" ;;
      real-secondary) real_secondary_case "$3" ;;
      *) usage ;;
    esac
    ;;
  --ci-fake)
    [[ $# -eq 1 ]] || usage
    ci_fake_case
    ;;
  *)
    usage
    ;;
esac
