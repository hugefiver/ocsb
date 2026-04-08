#!/usr/bin/env bash
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
  if ! "$@" 2>/dev/null; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected failure but succeeded)" >&2
    FAIL=$((FAIL + 1))
  fi
}

OCSB_BIN="${1:?Usage: $0 <path-to-ocsb-binary>}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR/project"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "=== ocsb wrapper test suite ==="
echo "  binary: $OCSB_BIN"
echo "  project: $PROJECT_DIR"
echo ""

# --- Workspace name validation ---
echo "--- workspace name validation ---"

assert_fails "rejects empty name" \
  "$OCSB_BIN" -w "" --strategy direct -- -c true

assert_fails "rejects '..' name" \
  "$OCSB_BIN" -w ".." --strategy direct -- -c true

assert_fails "rejects '.' name" \
  "$OCSB_BIN" -w "." --strategy direct -- -c true

assert_fails "rejects name with '/'" \
  "$OCSB_BIN" -w "a/b" --strategy direct -- -c true

assert_fails "rejects name with '..'" \
  "$OCSB_BIN" -w "foo..bar" --strategy direct -- -c true

assert_fails "rejects name starting with '-'" \
  "$OCSB_BIN" -w "-bad" --strategy direct -- -c true

assert "accepts valid name 'my-workspace'" \
  "$OCSB_BIN" -w "my-workspace" --strategy direct --overwrite -- -c true

echo ""

# --- Tilde (~) mount mapping ---
echo "--- tilde mount mapping ---"

# The default template mounts ~/.config/opencode as RO.
# Create a marker file on the host, verify it appears at /home/sandbox/... inside sandbox.
MOUNT_TEST_DIR="$HOME/.config/opencode"
MOUNT_TEST_MARKER="$MOUNT_TEST_DIR/.ocsb_mount_test_marker"
mkdir -p "$MOUNT_TEST_DIR"
echo "ocsb-tilde-test-$$" > "$MOUNT_TEST_MARKER"

# Inside sandbox, the file should be at /home/sandbox/.config/opencode/...
SANDBOX_OUTPUT=$("$OCSB_BIN" -w "test-tilde" --strategy direct --overwrite -- \
  -c 'cat /home/sandbox/.config/opencode/.ocsb_mount_test_marker 2>/dev/null || echo MISSING')

assert "~ RO mount: host ~/... maps to /home/sandbox/..." [ "$SANDBOX_OUTPUT" = "ocsb-tilde-test-$$" ]

# Verify the mount is read-only (write should fail)
WRITE_OUTPUT=$("$OCSB_BIN" -w "test-tilde-ro" --strategy direct --overwrite -- \
  -c 'echo fail > /home/sandbox/.config/opencode/.ocsb_write_test 2>&1 && echo WRITABLE || echo READONLY')

assert "~ RO mount is read-only" [ "$WRITE_OUTPUT" = "READONLY" ]

rm -f "$MOUNT_TEST_MARKER"
rm -rf "$PROJECT_DIR/.ocsb/test-tilde" "$PROJECT_DIR/.ocsb/test-tilde-ro"
echo ""

# --- Symlink escape protection ---
echo "--- symlink escape protection ---"

ESCAPE_DIR="$(mktemp -d)"
rm -rf "$PROJECT_DIR/.ocsb"
ln -sfn "$ESCAPE_DIR" "$PROJECT_DIR/.ocsb"

assert_fails "rejects .ocsb symlink escaping project root" \
  "$OCSB_BIN" -w "escape-test" --strategy direct -- -c true

rm -rf "$PROJECT_DIR/.ocsb"
rm -rf "$ESCAPE_DIR"
echo ""

# --- Strategy marker (cross-strategy rejection) ---
echo "--- strategy marker ---"

# Create workspace with direct strategy
"$OCSB_BIN" -w "strat-test" --strategy direct --overwrite -- -c true 2>/dev/null || true

# --continue with different strategy should fail
assert_fails "rejects --continue with mismatched strategy" \
  "$OCSB_BIN" -w "strat-test" --strategy overlayfs --continue -- -c true

# --overwrite with different strategy should succeed (cleans by original)
assert "--overwrite with different strategy succeeds" \
  "$OCSB_BIN" -w "strat-test" --strategy overlayfs --overwrite -- -c true

# Verify strategy marker was updated (now stored in cache dir)
PROJ_HASH_STRAT="$(echo -n "$PROJECT_DIR" | sha256sum | cut -c1-16)"
STRAT_MARKER="$(cat "$HOME/.cache/ocsb/$PROJ_HASH_STRAT/strat-test/.strategy" 2>/dev/null || echo MISSING)"
assert "strategy marker updated after overwrite" [ "$STRAT_MARKER" = "overlayfs" ]

rm -rf "$PROJECT_DIR/.ocsb/strat-test"
rm -rf "$HOME/.cache/ocsb/$PROJ_HASH_STRAT/strat-test"
echo ""

# --- Overlay state directory location ---
echo "--- overlay state location ---"

"$OCSB_BIN" -w "test-overlay-loc" --strategy overlayfs --overwrite -- -c true 2>/dev/null || true

PROJ_HASH="$(echo -n "$PROJECT_DIR" | sha256sum | cut -c1-16)"
EXPECTED_STATE="$HOME/.cache/ocsb/$PROJ_HASH/test-overlay-loc"

assert "overlay state dir at ~/.cache/ocsb" [ -d "$EXPECTED_STATE" ]
assert "overlay upper dir exists" [ -d "$EXPECTED_STATE/upper" ]
assert "overlay work dir exists" [ -d "$EXPECTED_STATE/work" ]
assert_not "no upper inside .ocsb" [ -d "$PROJECT_DIR/.ocsb/test-overlay-loc/upper" ]

rm -rf "$EXPECTED_STATE"
rm -rf "$PROJECT_DIR/.ocsb/test-overlay-loc"
echo ""

# --- Store closure strictness ---
echo "--- store closure ---"

STORE_COUNT=$("$OCSB_BIN" -w "test-closure" --strategy direct --overwrite -- \
  -c 'ls -1d /nix/store/*/ 2>/dev/null | wc -l')

assert "store paths < 500 (got $STORE_COUNT)" [ "$STORE_COUNT" -lt 500 ]
echo ""

# --- Missing argument handling ---
echo "--- missing argument handling ---"

assert_fails "rejects --workspace without value" \
  "$OCSB_BIN" --workspace

assert_fails "rejects --strategy without value" \
  "$OCSB_BIN" --strategy

echo ""

# --- Invalid strategy handling ---
echo "--- invalid strategy handling ---"

assert_fails "rejects unknown strategy at runtime" \
  "$OCSB_BIN" -w "bad-strat" --strategy "fakestrategy" -- -c true

assert_not "no workspace stub for invalid strategy" [ -d "$PROJECT_DIR/.ocsb/bad-strat" ]

echo ""

# --- Malformed .git file protection ---
echo "--- malformed .git protection ---"

GITFAKE_PROJECT="$(mktemp -d)"
GITFAKE_TARGET="$(mktemp -d)"
echo "canary-$$" > "$GITFAKE_TARGET/marker"
echo "gitdir: $GITFAKE_TARGET" > "$GITFAKE_PROJECT/.git"

OUTPUT=$(cd "$GITFAKE_PROJECT" && "$OCSB_BIN" -w "gitfake" --strategy direct --overwrite -- \
  -c "cat $GITFAKE_TARGET/marker 2>/dev/null || echo BLOCKED" 2>/dev/null)

assert "malformed .git does not mount arbitrary dirs" [ "$OUTPUT" = "BLOCKED" ]

rm -rf "$GITFAKE_PROJECT" "$GITFAKE_TARGET"
echo ""

# --- CLI args passthrough ---
echo "--- CLI args passthrough ---"

# When app.package=null (bash mode), args after -- become the command
ECHO_OUTPUT=$("$OCSB_BIN" -w "test-passthrough" --strategy direct --overwrite -- echo hello-ocsb)
assert "passthrough: -- echo hello-ocsb outputs hello-ocsb" [ "$ECHO_OUTPUT" = "hello-ocsb" ]

# Multiple args passthrough
MULTI_OUTPUT=$("$OCSB_BIN" -w "test-passthrough2" --strategy direct --overwrite -- echo "arg1 arg2")
assert "passthrough: multiple args forwarded" [ "$MULTI_OUTPUT" = "arg1 arg2" ]

# No args after -- → drops to bash; test with -c flag
BASH_OUTPUT=$("$OCSB_BIN" -w "test-passthrough3" --strategy direct --overwrite -- -c 'echo from-bash')
assert "passthrough: -c flag works in bash mode" [ "$BASH_OUTPUT" = "from-bash" ]

echo ""

# --- Runtime mounts (--ro / --rw) ---
echo "--- runtime mounts ---"

# Create temp dirs for mount testing
MOUNT_SRC_RO="$(mktemp -d)"
MOUNT_SRC_RW="$(mktemp -d)"
echo "ro-marker-$$" > "$MOUNT_SRC_RO/marker.txt"
echo "rw-marker-$$" > "$MOUNT_SRC_RW/marker.txt"

# --ro mount: host dir → sandbox path (relative resolves to /workspace/...)
RO_OUTPUT=$("$OCSB_BIN" -w "test-mount-ro" --strategy direct --overwrite \
  --ro "$MOUNT_SRC_RO:./ro-data" \
  -- cat /workspace/ro-data/marker.txt)
assert "--ro mount: file accessible at /workspace/ro-data" [ "$RO_OUTPUT" = "ro-marker-$$" ]

# --ro mount is read-only
RO_WRITE=$("$OCSB_BIN" -w "test-mount-ro2" --strategy direct --overwrite \
  --ro "$MOUNT_SRC_RO:./ro-test" \
  -- -c 'echo fail > /workspace/ro-test/write_test 2>&1 && echo WRITABLE || echo READONLY')
assert "--ro mount is read-only" [ "$RO_WRITE" = "READONLY" ]

# --rw mount: writable
RW_OUTPUT=$("$OCSB_BIN" -w "test-mount-rw" --strategy direct --overwrite \
  --rw "$MOUNT_SRC_RW:./rw-data" \
  -- -c 'echo "written-$$" > /workspace/rw-data/new_file.txt && cat /workspace/rw-data/new_file.txt')
assert "--rw mount: write works" test -n "$RW_OUTPUT"

# --ro with absolute sandbox path
ABS_OUTPUT=$("$OCSB_BIN" -w "test-mount-abs" --strategy direct --overwrite \
  --ro "$MOUNT_SRC_RO:/data/ro-abs" \
  -- cat /data/ro-abs/marker.txt)
assert "--ro mount: absolute sandbox path works" [ "$ABS_OUTPUT" = "ro-marker-$$" ]

# Validation: reject relative host path
assert_fails "--ro rejects relative host path" \
  "$OCSB_BIN" -w "test-mount-bad" --strategy direct --overwrite \
  --ro "relative/path:./dest" -- -c true

# Validation: reject '..' in sandbox path
assert_fails "--ro rejects '..' in sandbox path" \
  "$OCSB_BIN" -w "test-mount-bad2" --strategy direct --overwrite \
  --ro "$MOUNT_SRC_RO:../escape" -- -c true

# Validation: reject non-existent host path
assert_fails "--ro rejects non-existent host path" \
  "$OCSB_BIN" -w "test-mount-bad3" --strategy direct --overwrite \
  --ro "/nonexistent/path:./dest" -- -c true

# Validation: reject missing colon separator
assert_fails "--ro rejects missing colon separator" \
  "$OCSB_BIN" -w "test-mount-bad4" --strategy direct --overwrite \
  --ro "$MOUNT_SRC_RO" -- -c true

rm -rf "$MOUNT_SRC_RO" "$MOUNT_SRC_RW"
echo ""

# --- OpenCode db rw mount ---
echo "--- opencode db rw mount ---"

# The template mounts ~/.local/share/opencode as rw (bind-try).
# Create marker on host, verify writable inside sandbox.
OC_DB_DIR="$HOME/.local/share/opencode"
mkdir -p "$OC_DB_DIR"
echo "oc-db-test-$$" > "$OC_DB_DIR/.ocsb_db_test"

DB_OUTPUT=$("$OCSB_BIN" -w "test-ocdb" --strategy direct --overwrite -- \
  -c 'cat /home/sandbox/.local/share/opencode/.ocsb_db_test 2>/dev/null || echo MISSING')
assert "opencode db: marker readable" [ "$DB_OUTPUT" = "oc-db-test-$$" ]

# Verify writability
DB_WRITE=$("$OCSB_BIN" -w "test-ocdb-w" --strategy direct --overwrite -- \
  -c 'echo write-test > /home/sandbox/.local/share/opencode/.ocsb_write_test 2>/dev/null && echo OK || echo READONLY')
assert "opencode db: path is writable" [ "$DB_WRITE" = "OK" ]

rm -f "$OC_DB_DIR/.ocsb_db_test" "$OC_DB_DIR/.ocsb_write_test"
echo ""

# --- OCSB_NETWORK env var ---
echo "--- OCSB_NETWORK env var ---"

NET_OUTPUT=$("$OCSB_BIN" -w "test-netenv" --strategy direct --overwrite -- \
  -c 'echo $OCSB_NETWORK')
assert "OCSB_NETWORK set to 'host' by default" [ "$NET_OUTPUT" = "host" ]

echo ""

echo "=== Wrapper Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
