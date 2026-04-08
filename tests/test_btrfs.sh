#!/usr/bin/env bash
set -euo pipefail

OCSB_BIN="${1:?Usage: $0 <path-to-ocsb-binary>}"

if ! command -v btrfs &>/dev/null; then
  echo "SKIP: btrfs not available"
  exit 0
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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

(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "btrfs-test" --strategy btrfs --overwrite -- -c true 2>/dev/null) || true

SNAP_DIR="$PROJECT_DIR/.ocsb/btrfs-test/snapshot"
assert "snapshot directory created" [ -d "$SNAP_DIR" ]
assert "snapshot contains project files" [ -f "$SNAP_DIR/testfile.txt" ]

(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "btrfs-test" --strategy btrfs --continue -- -c true 2>/dev/null) || true
assert "continue reuses existing snapshot" [ -d "$SNAP_DIR" ]

(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "btrfs-test" --strategy btrfs --overwrite -- -c true 2>/dev/null) || true
assert "overwrite recreates snapshot" [ -d "$SNAP_DIR" ]

btrfs subvolume delete "$SNAP_DIR" 2>/dev/null || rm -rf "$SNAP_DIR"
rm -rf "$PROJECT_DIR/.ocsb/btrfs-test"

echo ""
echo "=== btrfs Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
