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
cleanup() { rm -rf "$TMPDIR"; }
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

PROJECT_DIR="$TMPDIR/project"
mkdir -p "$PROJECT_DIR"

RUN_OUTPUT="$(cd "$PROJECT_DIR" && OCSB_STATE_BASE_DIR="$TMPDIR/state" "$PODMAN_BIN" --backend podman --strategy overlayfs -- -c true 2>&1)" && RUN_EXIT=0 || RUN_EXIT=$?
assert "podman overlayfs runtime rejection exits non-zero" [ "$RUN_EXIT" -ne 0 ]
assert_contains "podman overlayfs rejection explains boundary" "$RUN_OUTPUT" "does not support workspace.strategy=overlayfs"

RUN_OUTPUT2="$(cd "$PROJECT_DIR" && OCSB_STATE_BASE_DIR="$TMPDIR/state" "$NSPAWN_BIN" --backend systemd-nspawn --strategy overlayfs -- -c true 2>&1)" && RUN_EXIT2=0 || RUN_EXIT2=$?
assert "nspawn overlayfs runtime rejection exits non-zero" [ "$RUN_EXIT2" -ne 0 ]
assert_contains "nspawn overlayfs rejection explains boundary" "$RUN_OUTPUT2" "does not support workspace.strategy=overlayfs"

echo ""
echo "=== backend Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
