#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# ocsb dual-layer sandbox test suite
#
# Runs INSIDE the OUTER sandbox (Layer 1) where:
#   - Host network is available (--share-net)
#   - $SHELL points to the sandbox-shell wrapper
#   - OCSB_DUAL_LAYER=outer
#
# Tests verify both Layer 1 (outer) and Layer 2 (inner) properties.
# =============================================================

PASS=0
FAIL=0
SKIP=0

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

skip() {
  local desc="$1"
  echo "  SKIP: $desc"
  SKIP=$((SKIP + 1))
}

echo "=== ocsb dual-layer test suite ==="
echo ""

# ----- Layer 1 (outer sandbox) environment -----
echo "--- Layer 1: outer sandbox environment ---"
assert "OCSB_NETWORK is 'dual-layer'" [ "${OCSB_NETWORK:-}" = "dual-layer" ]
assert "OCSB_DUAL_LAYER is 'outer'" [ "${OCSB_DUAL_LAYER:-}" = "outer" ]
assert "SANDBOX is set" [ "${SANDBOX:-}" = "1" ]
_HAS_SHELL=0
echo "${SHELL:-}" | grep -q sandbox-shell && _HAS_SHELL=1
assert "SHELL points to sandbox-shell" [ "$_HAS_SHELL" = "1" ]
assert "workspace is /workspace" [ -d /workspace ]
echo ""

# ----- Layer 1: host network available -----
echo "--- Layer 1: host network access ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 https://httpbin.org/get 2>/dev/null) || true
assert "outer sandbox has internet access (got $HTTP_CODE)" [ "$HTTP_CODE" != "000" ] && [ -n "$HTTP_CODE" ]
echo ""

# ----- Layer 2 (inner sandbox via $SHELL) -----
echo "--- Layer 2: inner sandbox via \$SHELL -c ---"

# The wrapper shell should work as a bash drop-in
INNER_OUTPUT=$($SHELL -c 'echo INNER_WORKS' 2>/dev/null) || true
assert "inner sandbox executes commands" [ "$INNER_OUTPUT" = "INNER_WORKS" ]

# Inner sandbox should have OCSB_DUAL_LAYER=inner
INNER_LAYER=$($SHELL -c 'echo $OCSB_DUAL_LAYER' 2>/dev/null) || true
assert "inner OCSB_DUAL_LAYER is 'inner'" [ "$INNER_LAYER" = "inner" ]

# Inner sandbox should have SANDBOX=1
INNER_SANDBOX=$($SHELL -c 'echo $SANDBOX' 2>/dev/null) || true
assert "inner SANDBOX is '1'" [ "$INNER_SANDBOX" = "1" ]

# Inner sandbox should have /workspace mounted (rw)
INNER_WS=$($SHELL -c 'test -d /workspace && echo YES || echo NO' 2>/dev/null) || true
assert "inner sandbox has /workspace" [ "$INNER_WS" = "YES" ]

# Inner sandbox should have PATH set
INNER_PATH=$($SHELL -c 'echo $PATH' 2>/dev/null) || true
assert "inner sandbox has PATH" [ -n "$INNER_PATH" ]
echo ""

# ----- Layer 2: network isolation -----
echo "--- Layer 2: inner sandbox network isolation ---"
# Inner sandbox should NOT have network access (--unshare-net without slirp)
INNER_NET=$($SHELL -c 'curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 https://httpbin.org/get 2>/dev/null' 2>/dev/null) || true
assert "inner sandbox has NO internet (got ${INNER_NET:-empty})" [ "${INNER_NET:-000}" = "000" ]
echo ""

# ----- Layer 2: filesystem isolation -----
echo "--- Layer 2: inner sandbox filesystem ---"

# /nix/store should be available (read-only)
INNER_NIX=$($SHELL -c 'test -d /nix/store && echo YES || echo NO' 2>/dev/null) || true
assert "inner sandbox has /nix/store" [ "$INNER_NIX" = "YES" ]

# /tmp should be a fresh tmpfs (writable)
INNER_TMP=$($SHELL -c 'touch /tmp/test_$$; echo $?' 2>/dev/null) || true
assert "inner sandbox /tmp is writable" [ "$INNER_TMP" = "0" ]

# /home should be fresh (not the outer /home)
INNER_HOME=$($SHELL -c 'echo $HOME' 2>/dev/null) || true
assert "inner sandbox HOME is /home/sandbox" [ "$INNER_HOME" = "/home/sandbox" ]
echo ""

# ----- Layer 2: workspace write-through -----
echo "--- Layer 2: workspace write-through ---"
# Files created in inner /workspace should be visible in outer /workspace
_TEST_FILE="/workspace/.ocsb-dual-layer-test-$$"
$SHELL -c "echo WRITTEN_FROM_INNER > $_TEST_FILE" 2>/dev/null || true
if [ -f "$_TEST_FILE" ]; then
  INNER_CONTENT=$(cat "$_TEST_FILE")
  assert "inner writes visible in outer" [ "$INNER_CONTENT" = "WRITTEN_FROM_INNER" ]
  rm -f "$_TEST_FILE"
else
  echo "  FAIL: inner sandbox write not visible in outer" >&2
  FAIL=$((FAIL + 1))
fi
echo ""

# ----- $SHELL --version compatibility -----
echo "--- \$SHELL compatibility ---"
SHELL_VERSION=$($SHELL --version 2>/dev/null | head -n1) || true
_IS_BASH=0
echo "$SHELL_VERSION" | grep -qi "bash" && _IS_BASH=1
assert "SHELL --version works" [ "$_IS_BASH" = "1" ]
echo ""

# ----- Layer 2: non -c invocations also isolated -----
echo "--- Layer 2: non -c invocation isolation ---"
# Script-style invocation should also be wrapped in inner bwrap
_SCRIPT_FILE="/workspace/.ocsb-test-script-$$"
echo 'echo $OCSB_DUAL_LAYER' > "$_SCRIPT_FILE"
SCRIPT_LAYER=$($SHELL "$_SCRIPT_FILE" 2>/dev/null) || true
rm -f "$_SCRIPT_FILE"
assert "script invocation is in inner layer" [ "$SCRIPT_LAYER" = "inner" ]

# Flag-style invocation (-l) should also be wrapped
FLAG_LAYER=$($SHELL -l -c 'echo $OCSB_DUAL_LAYER' 2>/dev/null) || true
assert "flag invocation (-l -c) is in inner layer" [ "$FLAG_LAYER" = "inner" ]

# -h is bash's hashall option (NOT help) — must be sandboxed, not passed through
H_FLAG_LAYER=$($SHELL -h -c 'echo $OCSB_DUAL_LAYER' 2>/dev/null) || true
assert "-h flag invocation is in inner layer (hashall, not help)" [ "$H_FLAG_LAYER" = "inner" ]

# Interactive-style (no network in inner) via script to avoid blocking
_NET_SCRIPT="/workspace/.ocsb-test-net-$$"
echo 'HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 https://httpbin.org/get 2>/dev/null) || true; echo "$HTTP_CODE"' > "$_NET_SCRIPT"
SCRIPT_NET=$($SHELL "$_NET_SCRIPT" 2>/dev/null) || true
rm -f "$_NET_SCRIPT"
assert "script invocation has no network (got ${SCRIPT_NET:-empty})" [ "${SCRIPT_NET:-000}" = "000" ]
echo ""

echo "=== Dual-Layer Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
