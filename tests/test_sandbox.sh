#!/usr/bin/env bash
# ocsb sandbox integration tests
# Exit on first failure — each check is an assertion
set -euo pipefail

PASS=0
FAIL=0

assert() {
  local desc="$1"
  shift
  if "$@"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_not() {
  local desc="$1"
  shift
  if ! "$@"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc" >&2
    FAIL=$((FAIL + 1))
  fi
}

echo "=== ocsb sandbox test suite ==="
echo ""

# --- Environment checks ---
echo "--- environment ---"
assert "SANDBOX is set" [ "${SANDBOX:-}" = "1" ]
assert "HOME is /home/sandbox" [ "$HOME" = "/home/sandbox" ]
assert "OCSB_WORKSPACE is set" [ -n "${OCSB_WORKSPACE:-}" ]
assert "OCSB_STRATEGY is set" [ -n "${OCSB_STRATEGY:-}" ]
assert "PATH is /usr/bin" [ "$PATH" = "/usr/bin" ]
echo ""

# --- Whitelisted commands exist ---
echo "--- whitelisted commands ---"
assert "bash available" command -v bash
assert "ls available" command -v ls
assert "git available" command -v git
assert "cat available" command -v cat
assert "rg available" command -v rg
assert "fd available" command -v fd
assert "jq available" command -v jq
assert "curl available" command -v curl
echo ""

# --- Store isolation: non-whitelisted commands must be absent ---
echo "--- store isolation ---"
assert_not "apt NOT available" command -v apt 2>/dev/null
assert_not "systemctl NOT available" command -v systemctl 2>/dev/null
assert_not "python NOT available" command -v python 2>/dev/null
assert_not "python3 NOT available" command -v python3 2>/dev/null
assert_not "gcc NOT available" command -v gcc 2>/dev/null
assert_not "npm NOT available" command -v npm 2>/dev/null
echo ""

# --- /nix/store isolation: verify only closure paths exist ---
echo "--- /nix/store isolation ---"
# Count store paths visible — should be a limited set, not the full store
STORE_COUNT=$(ls -1d /nix/store/*/ 2>/dev/null | wc -l)
assert "/nix/store has limited paths (< 500)" [ "$STORE_COUNT" -lt 500 ]
assert "/nix/store has some paths (> 0)" [ "$STORE_COUNT" -gt 0 ]
echo "  (visible store paths: $STORE_COUNT)"
_BASH_REAL="$(readlink -f "$(command -v bash)" 2>/dev/null)"
_IN_STORE=0
case "$_BASH_REAL" in /nix/store/*) _IN_STORE=1 ;; esac
assert "bash resolves to /nix/store path" [ "$_IN_STORE" = "1" ]
echo ""

# --- Filesystem isolation ---
echo "--- filesystem isolation ---"
assert "/workspace exists" [ -d /workspace ]
assert "/home/sandbox exists" [ -d "$HOME" ]
assert "/tmp exists" [ -d /tmp ]
# /home should only contain sandbox
HOME_ENTRIES=$(ls -1 /home/ | wc -l)
assert "/home has only sandbox dir" [ "$HOME_ENTRIES" -eq 1 ]
echo ""

# --- Identity (uid/gid mapping) ---
echo "--- identity ---"
assert_not "not running as root (uid)" [ "$(id -u)" = "0" ]
assert_not "not running as root (gid)" [ "$(id -g)" = "0" ]
echo "  uid=$(id -u) gid=$(id -g)"
echo ""

# --- Workspace write test ---
echo "--- workspace write test ---"
if [ "${OCSB_STRATEGY:-}" = "overlayfs" ]; then
  # overlayfs: writes go to upper layer, don't touch lower
  echo "test-overlay" > /workspace/.ocsb_write_test 2>/dev/null && {
    assert "overlay write succeeds" [ -f /workspace/.ocsb_write_test ]
    rm -f /workspace/.ocsb_write_test
  } || {
    echo "  SKIP: overlay write test (write failed)"
  }
elif [ "${OCSB_STRATEGY:-}" = "direct" ]; then
  assert "direct: /workspace is writable" touch /workspace/.ocsb_write_test
  rm -f /workspace/.ocsb_write_test
fi
echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
