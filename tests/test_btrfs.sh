#!/usr/bin/env bash
set -euo pipefail

OCSB_BIN="${1:?Usage: $0 <path-to-ocsb-binary>}"

if ! command -v btrfs &>/dev/null; then
  echo "SKIP: btrfs not available"
  exit 0
fi

TMPDIR="$(mktemp -d)"
cleanup() {
  find "$TMPDIR" -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT
export OCSB_STATE_BASE_DIR="$TMPDIR/state"

if ! btrfs subvolume show "$TMPDIR" &>/dev/null 2>&1; then
  BTRFS_VOL="$TMPDIR/subvol"
  if ! btrfs subvolume create "$BTRFS_VOL" &>/dev/null 2>&1; then
    echo "SKIP: cannot create btrfs subvolume (not on btrfs filesystem)"
    exit 0
  fi
  PROJECT_DIR="$BTRFS_VOL"
else
  PROJECT_DIR="$TMPDIR"
fi

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

echo "=== btrfs strategy test ==="

echo "test-content" > "$PROJECT_DIR/testfile.txt"

# SKIP if btrfs strategy unusable (e.g. plain btrfs without user_subvol_rm_allowed).
PROBE_OUT="$(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "btrfs-probe" --strategy btrfs --overwrite -- -c true 2>&1 || true)"
if echo "$PROBE_OUT" | grep -q "btrfs strategy unavailable"; then
  echo "SKIP: btrfs strategy unavailable in this environment"
  echo "  reason: $(echo "$PROBE_OUT" | grep "btrfs strategy unavailable" | head -1)"
  exit 0
fi
rm -rf "$PROJECT_DIR/.ocsb/btrfs-probe" 2>/dev/null || true

(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "btrfs-test" --strategy btrfs --overwrite -- -c true 2>/dev/null) || true

SNAP_DIR="$PROJECT_DIR/.ocsb/btrfs-test/snapshot"
assert "snapshot directory created" [ -d "$SNAP_DIR" ]
assert "snapshot contains project files" [ -f "$SNAP_DIR/testfile.txt" ]

(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "btrfs-test" --strategy btrfs --continue -- -c true 2>/dev/null) || true
assert "continue reuses existing snapshot" [ -d "$SNAP_DIR" ]

(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "btrfs-test" --strategy btrfs --overwrite -- -c true 2>/dev/null) || true
assert "overwrite recreates snapshot" [ -d "$SNAP_DIR" ]

SNAP_MOUNT_SRC="$TMPDIR/snap-mount-src"
if btrfs subvolume create "$SNAP_MOUNT_SRC" &>/dev/null; then
  echo "snap-mount-data" > "$SNAP_MOUNT_SRC/marker.txt"
  (cd "$PROJECT_DIR" && "$OCSB_BIN" -w "snap-mount-test" --strategy direct --overwrite \
    --snap-mount "$SNAP_MOUNT_SRC:/workspace/snap-data" -- \
    -c 'cat /workspace/snap-data/marker.txt >/dev/null') || true
  SNAP_HASH="$(echo -n "$SNAP_MOUNT_SRC" | sha256sum | cut -c1-12)"
  SNAP_STATE="$OCSB_STATE_BASE_DIR/snap-mount-test/snapshots/snap-$SNAP_HASH"
  assert "snap-mount state under snapshots" [ -d "$SNAP_STATE" ]
  assert "snap-mount snapshot contains source file" [ -f "$SNAP_STATE/marker.txt" ]
  assert "snap-mount has no legacy root snapshot state" [ ! -d "$OCSB_STATE_BASE_DIR/snap-mount-test/snap-$SNAP_HASH" ]
else
  echo "  SKIP: cannot create btrfs subvolume for snap-mount regression"
fi

btrfs subvolume delete "$SNAP_DIR" 2>/dev/null || rm -rf "$SNAP_DIR"
btrfs subvolume delete "$SNAP_MOUNT_SRC" 2>/dev/null || rm -rf "$SNAP_MOUNT_SRC"
rm -rf "$PROJECT_DIR/.ocsb/btrfs-test"

echo ""
echo "=== btrfs Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
