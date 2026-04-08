#!/usr/bin/env bash
# git-worktree strategy host-side regression test
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

OCSB_BIN="${1:?Usage: $0 <path-to-ocsb-binary>}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR/project"
mkdir -p "$PROJECT_DIR"
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" -c user.name="test" -c user.email="test@test" commit --allow-empty -m "init" -q

echo "=== git-worktree regression test ==="

WS_NAME="gwt-test"

(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "$WS_NAME" --strategy git-worktree --overwrite -- -c true 2>/dev/null) || true

GWT_COUNT=$(git -C "$PROJECT_DIR" worktree list --porcelain | grep -c "^worktree " || true)
assert "after create: exactly 2 worktrees (main + ws)" [ "$GWT_COUNT" -eq 2 ]

(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "$WS_NAME" --strategy git-worktree --continue -- -c true 2>/dev/null) || true

GWT_COUNT=$(git -C "$PROJECT_DIR" worktree list --porcelain | grep -c "^worktree " || true)
assert "after continue: still 2 worktrees" [ "$GWT_COUNT" -eq 2 ]

(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "$WS_NAME" --strategy git-worktree --overwrite -- -c true 2>/dev/null) || true

GWT_COUNT=$(git -C "$PROJECT_DIR" worktree list --porcelain | grep -c "^worktree " || true)
assert "after overwrite: still 2 worktrees" [ "$GWT_COUNT" -eq 2 ]

# --- Inside-sandbox Git operations ---
GIT_REV=$(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "$WS_NAME" --strategy git-worktree --continue -- \
  -c 'git rev-parse --is-inside-work-tree 2>/dev/null || echo FAIL' 2>/dev/null)
assert "git rev-parse works inside sandbox" [ "$GIT_REV" = "true" ]

GIT_STATUS_EXIT=0
(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "$WS_NAME" --strategy git-worktree --continue -- \
  -c 'git status --porcelain' 2>/dev/null) || GIT_STATUS_EXIT=$?
assert "git status works inside sandbox" [ "$GIT_STATUS_EXIT" -eq 0 ]

# Cleanup workspace
(cd "$PROJECT_DIR" && "$OCSB_BIN" -w "$WS_NAME" --strategy git-worktree --overwrite -- -c true 2>/dev/null) || true
GWT_DIR="$PROJECT_DIR/.ocsb/$WS_NAME/worktree"
if [ -d "$GWT_DIR" ]; then
  git -C "$PROJECT_DIR" worktree remove --force "$GWT_DIR" 2>/dev/null || true
fi

GWT_COUNT=$(git -C "$PROJECT_DIR" worktree list --porcelain | grep -c "^worktree " || true)
assert "after cleanup: back to 1 worktree" [ "$GWT_COUNT" -eq 1 ]

echo ""
echo "=== Git-worktree Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
