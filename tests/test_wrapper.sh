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
cleanup() {
  find "$TMPDIR" -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT
export OCSB_STATE_BASE_DIR="$TMPDIR/state"

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
STRAT_MARKER="$(cat "$OCSB_STATE_BASE_DIR/strat-test/.strategy" 2>/dev/null || echo MISSING)"
assert "strategy marker updated after overwrite" [ "$STRAT_MARKER" = "overlayfs" ]

rm -rf "$PROJECT_DIR/.ocsb/strat-test"
echo ""

# --- Overlay state directory location ---
echo "--- overlay state location ---"

"$OCSB_BIN" -w "test-overlay-loc" --strategy overlayfs --overwrite -- -c true 2>/dev/null || true

EXPECTED_STATE="$OCSB_STATE_BASE_DIR/test-overlay-loc"

assert "overlay state dir at custom state base" [ -d "$EXPECTED_STATE" ]
assert "overlay upper dir exists" [ -d "$EXPECTED_STATE/overlay/workspace/upper" ]
assert "overlay work dir exists" [ -d "$EXPECTED_STATE/overlay/workspace/work" ]
assert_not "no upper inside .ocsb" [ -d "$PROJECT_DIR/.ocsb/test-overlay-loc/upper" ]

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
"$OCSB_BIN" -w "test-overlay-loc" --strategy overlayfs --continue -- \
  -c 'echo uid-test > /workspace/.ocsb_uid_test'
UID_TEST_FILE="$(find "$EXPECTED_STATE/overlay/workspace/upper" -name .ocsb_uid_test -type f -print -quit)"
assert "overlay write lands in upper" [ -n "$UID_TEST_FILE" ]
assert "overlay upper file owned by host uid" [ "$(stat -c %u "$UID_TEST_FILE")" = "$HOST_UID" ]
assert "overlay upper file owned by host gid" [ "$(stat -c %g "$UID_TEST_FILE")" = "$HOST_GID" ]

find "$EXPECTED_STATE" -type d -exec chmod u+w {} + 2>/dev/null || true
rm -rf "$EXPECTED_STATE"
rm -rf "$PROJECT_DIR/.ocsb/test-overlay-loc"
echo ""

# --- Custom state base directory ---
echo "--- custom state base ---"

CUSTOM_STATE_BASE="$(mktemp -d)"
CUSTOM_STATE_OUTPUT=$(OCSB_STATE_BASE_DIR="$CUSTOM_STATE_BASE" \
  "$OCSB_BIN" -w "stable-state" --strategy overlayfs --overwrite -- -c 'printf %s "$OCSB_STATE_DIR"')

assert "custom state base exports exact OCSB_STATE_DIR" [ "$CUSTOM_STATE_OUTPUT" = "$CUSTOM_STATE_BASE/stable-state" ]
OCSB_STATE_BASE_DIR="$CUSTOM_STATE_BASE" \
  "$OCSB_BIN" -w "stable-state" --strategy overlayfs --overwrite -- -c 'test -n "$OCSB_STATE_DIR"'

assert "custom state base creates workspace state" [ -d "$CUSTOM_STATE_BASE/stable-state" ]
assert "custom state base stores overlay separately" [ -d "$CUSTOM_STATE_BASE/stable-state/overlay/workspace/upper" ]
assert_not "custom state base avoids default test state" [ -d "$OCSB_STATE_BASE_DIR/stable-state" ]
assert_fails "rejects relative custom state base" \
  env OCSB_STATE_BASE_DIR="relative-state" "$OCSB_BIN" -w "relative-state" --strategy direct -- -c true

find "$CUSTOM_STATE_BASE" -type d -exec chmod u+w {} + 2>/dev/null || true
rm -rf "$CUSTOM_STATE_BASE" "$PROJECT_DIR/.ocsb/stable-state"
echo ""

# --- Legacy chroot layout migration ---
echo "--- legacy chroot migration ---"

LEGACY_STATE="$OCSB_STATE_BASE_DIR/legacy-chroot"
mkdir -p "$LEGACY_STATE/chroot/nix/store" "$LEGACY_STATE/chroot/nix/var/nix"
touch "$LEGACY_STATE/chroot/.chroot-source"

"$OCSB_BIN" -w "legacy-chroot" --strategy direct --overwrite -- -c true

assert "legacy chroot migrated to merged layout" [ -d "$LEGACY_STATE/chroot/merged/nix/store" ]
assert_not "legacy chroot nix directory removed" [ -e "$LEGACY_STATE/chroot/nix" ]
assert_not "legacy chroot marker removed" [ -e "$LEGACY_STATE/chroot/.chroot-source" ]

find "$LEGACY_STATE" -type d -exec chmod u+w {} + 2>/dev/null || true
rm -rf "$LEGACY_STATE" "$PROJECT_DIR/.ocsb/legacy-chroot"
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

# --- Auto strategy ---
echo "--- auto strategy ---"

# On non-btrfs, auto should resolve to overlayfs
AUTO_STRAT=$("$OCSB_BIN" -w "test-auto" --strategy auto --overwrite -- \
  -c 'echo $OCSB_STRATEGY' 2>/dev/null)
# Accept both btrfs and overlayfs depending on filesystem
assert "auto strategy resolves to overlayfs or btrfs" \
  [ "$AUTO_STRAT" = "overlayfs" ] || [ "$AUTO_STRAT" = "btrfs" ]

# Default strategy (no --strategy flag) should also be auto
DEFAULT_STRAT=$("$OCSB_BIN" -w "test-default-strat" --overwrite -- \
  -c 'echo $OCSB_STRATEGY' 2>/dev/null)
assert "default strategy resolves (auto)" \
  [ "$DEFAULT_STRAT" = "overlayfs" ] || [ "$DEFAULT_STRAT" = "btrfs" ]

echo ""

# --- Per-directory overlay mount ---
echo "--- per-directory overlay mount ---"

OVL_SRC="$(mktemp -d)"
echo "overlay-test-data" > "$OVL_SRC/marker.txt"

OVL_OUTPUT=$("$OCSB_BIN" -w "test-ovl-mount" --strategy direct --overwrite \
  --overlay-mount "$OVL_SRC:/workspace/ovl-test" -- \
  -c 'cat /workspace/ovl-test/marker.txt 2>/dev/null || echo MISSING')
assert "overlay-mount: source data readable" [ "$OVL_OUTPUT" = "overlay-test-data" ]

# Writes to overlay should not modify source
"$OCSB_BIN" -w "test-ovl-mount" --strategy direct --continue \
  --overlay-mount "$OVL_SRC:/workspace/ovl-test" -- \
  -c 'echo modified > /workspace/ovl-test/marker.txt' 2>/dev/null || true
OVL_ORIG="$(cat "$OVL_SRC/marker.txt")"
OVL_HASH="$(echo -n "$OVL_SRC" | sha256sum | cut -c1-12)"
OVL_STATE="$OCSB_STATE_BASE_DIR/test-ovl-mount/overlay/mounts/ovl-$OVL_HASH"
assert "overlay-mount: source not modified by writes" [ "$OVL_ORIG" = "overlay-test-data" ]
assert "overlay-mount: state under overlay/mounts" [ -d "$OVL_STATE/upper" ]
assert_not "overlay-mount: no legacy root ovl state" [ -d "$OCSB_STATE_BASE_DIR/test-ovl-mount/ovl-$OVL_HASH" ]

# Validation: relative host path rejected
assert_fails "overlay-mount rejects relative host path" \
  "$OCSB_BIN" -w "test-ovl-bad" --strategy direct --overwrite \
  --overlay-mount "relative/path:/workspace/test" -- -c true

# Validation: missing host path rejected
assert_fails "overlay-mount rejects nonexistent host path" \
  "$OCSB_BIN" -w "test-ovl-bad2" --strategy direct --overwrite \
  --overlay-mount "/nonexistent/dir123:/workspace/test" -- -c true

rm -rf "$OVL_SRC"
echo ""

# --- OCSB_FORWARD_ENV host env forwarding ---
echo "--- OCSB_FORWARD_ENV forwarding ---"

FORWARD_ONE_VAL="forward-one-$$"
FORWARD_TWO_VAL="forward-two-$$ with spaces"
FORWARD_OUTPUT=$(OCSB_FORWARD_ENV="FORWARD_ONE, FORWARD_TWO, UNSET_FORWARD, BAD-NAME,FORWARD_ONE" \
  FORWARD_ONE="$FORWARD_ONE_VAL" FORWARD_TWO="$FORWARD_TWO_VAL" \
  "$OCSB_BIN" -w "test-forward-env" --strategy direct --overwrite -- \
  -c 'printf "%s\n%s\n%s\n" "${FORWARD_ONE:-MISSING}" "${FORWARD_TWO:-MISSING}" "${UNSET_FORWARD:-UNSET}"')

FORWARD_LINE1=$(printf '%s\n' "$FORWARD_OUTPUT" | sed -n '1p')
FORWARD_LINE2=$(printf '%s\n' "$FORWARD_OUTPUT" | sed -n '2p')
FORWARD_LINE3=$(printf '%s\n' "$FORWARD_OUTPUT" | sed -n '3p')

assert "OCSB_FORWARD_ENV forwards first host var" [ "$FORWARD_LINE1" = "$FORWARD_ONE_VAL" ]
assert "OCSB_FORWARD_ENV forwards second host var" [ "$FORWARD_LINE2" = "$FORWARD_TWO_VAL" ]
assert "OCSB_FORWARD_ENV skips unset vars" [ "$FORWARD_LINE3" = "UNSET" ]

CLI_ENV_ONE_VAL="cli-env-one-$$"
CLI_ENV_TWO_VAL="cli env two $$"
CLI_ENV_OUTPUT=$(CLI_ENV_TWO="$CLI_ENV_TWO_VAL" \
  "$OCSB_BIN" -w "test-cli-env" --strategy direct --overwrite \
  --env "CLI_ENV_ONE=$CLI_ENV_ONE_VAL" --env CLI_ENV_TWO -- \
  -c 'printf "%s\n%s\n" "${CLI_ENV_ONE:-MISSING}" "${CLI_ENV_TWO:-MISSING}"')
CLI_ENV_LINE1=$(printf '%s\n' "$CLI_ENV_OUTPUT" | sed -n '1p')
CLI_ENV_LINE2=$(printf '%s\n' "$CLI_ENV_OUTPUT" | sed -n '2p')

assert "--env NAME=VALUE passes explicit value" [ "$CLI_ENV_LINE1" = "$CLI_ENV_ONE_VAL" ]
assert "--env NAME forwards host value" [ "$CLI_ENV_LINE2" = "$CLI_ENV_TWO_VAL" ]
assert_fails "--env rejects invalid names" \
  "$OCSB_BIN" -w "test-cli-env-bad" --strategy direct --overwrite --env "BAD-NAME=value" -- -c true
assert_fails "--env NAME rejects unset host variable" \
  "$OCSB_BIN" -w "test-cli-env-unset" --strategy direct --overwrite --env "UNSET_CLI_ENV_$$" -- -c true

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
