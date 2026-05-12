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

FLAKE_DIR="$(realpath "${1:?Usage: $0 <path-to-ocsb-flake>}")"
TMPDIR="$(mktemp -d)"
cleanup() {
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

PODMAN_OUT="$(build_backend test-podman-backend podman 2>&1)" || {
  echo "$PODMAN_OUT" >&2
  exit 1
}
PODMAN_STORE="${PODMAN_OUT##*$'\n'}"
PODMAN_BIN="$PODMAN_STORE/bin/test-podman-backend"
PODMAN_TEXT="$(read_launcher_text "$PODMAN_BIN")"

assert_contains "podman launcher records backend" "$PODMAN_TEXT" "BACKEND_TYPE=podman"
assert_contains "podman launcher has podman exec path" "$PODMAN_TEXT" "exec podman"
assert_contains "podman launcher uses keep-id" "$PODMAN_TEXT" "--userns=keep-id"
assert_contains "attach resets root into sandbox filesystem" "$PODMAN_TEXT" "-r --wdns=/"
assert_contains "attach pidfile records proc start time" "$PODMAN_TEXT" '_pid_start="$(proc_start_time "$$")"'
assert_contains "attach pidfile accepts legacy one-field format" "$PODMAN_TEXT" 'read -r _BWRAP_PID _BWRAP_START < "$_PIDFILE"'
assert_contains "attach validates bwrap comm" "$PODMAN_TEXT" 'proc_comm "$_candidate_pid"'
assert_contains "attach accepts sandbox init bwrap pid" "$PODMAN_TEXT" 'if [[ "$_parent_comm" == "bwrap" ]]; then'
assert_contains "attach rejects ambiguous init children" "$PODMAN_TEXT" "has multiple sandbox-init children"
assert_contains "attach records pidfile before filtered bwrap exec" "$PODMAN_TEXT" $'record_attach_pidfile\n      exec ${pkgs.bubblewrap}/bin/bwrap \\'
assert_contains "attach records pidfile before simple bwrap exec" "$PODMAN_TEXT" 'record_attach_pidfile
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
assert_contains "nspawn launcher has nspawn exec path" "$NSPAWN_TEXT" "exec systemd-nspawn"
assert_contains "nspawn launcher rejects filtered network" "$NSPAWN_TEXT" "supports only host or blocked networking"
assert_contains "nspawn launcher preserves caller uid" "$NSPAWN_TEXT" '--user="$('

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

PROJECT_DIR="$TMPDIR/project"
mkdir -p "$PROJECT_DIR"

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

OCSB_STATE_BASE_DIR="$TMPDIR/state" "$PODMAN_BIN" --backend bubblewrap -w backend-mismatch --strategy direct --overwrite -- -c true >/dev/null
RUN_OUTPUT6="$(cd "$PROJECT_DIR" && OCSB_STATE_BASE_DIR="$TMPDIR/state" "$PODMAN_BIN" --backend podman -w backend-mismatch --strategy direct --continue -- -c true 2>&1)" && RUN_EXIT6=0 || RUN_EXIT6=$?
assert "backend mismatch continue exits non-zero" [ "$RUN_EXIT6" -ne 0 ]
assert_contains "backend mismatch explains original backend" "$RUN_OUTPUT6" "was created with backend 'bubblewrap'"

echo ""
echo "=== backend Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
