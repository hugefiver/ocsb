#!/usr/bin/env bash
set -euo pipefail

cd /tmp/ocsb
OCSB="$(readlink -f result)/bin/ocsb"
echo "Binary: $OCSB"

echo ""
echo "=========================================="
echo "=== test_sandbox.sh (inside sandbox) ====="
echo "=========================================="
$OCSB -w test-r4 --strategy direct --overwrite -- /workspace/tests/test_sandbox.sh

echo ""
echo "=========================================="
echo "=== test_wrapper.sh ====================="
echo "=========================================="
bash tests/test_wrapper.sh "$OCSB"

echo ""
echo "=========================================="
echo "=== test_binpath.sh ====================="
echo "=========================================="
bash tests/test_binpath.sh /tmp/ocsb

echo ""
echo "=========================================="
echo "=== test_git_worktree.sh ================"
echo "=========================================="
bash tests/test_git_worktree.sh "$OCSB"

echo ""
echo "=========================================="
echo "=== test_btrfs.sh ======================="
echo "=========================================="
bash tests/test_btrfs.sh "$OCSB"

echo ""
echo "=== ALL TEST SUITES COMPLETE ==="
