#!/usr/bin/env bash
set -euo pipefail
cd /tmp/ocsb
OCSB="$(readlink -f result)/bin/ocsb"

echo "=== test_git_worktree.sh ==="
bash tests/test_git_worktree.sh "$OCSB"

echo ""
echo "=== test_btrfs.sh ==="
bash tests/test_btrfs.sh "$OCSB"
