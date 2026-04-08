#!/usr/bin/env bash
set -euo pipefail
cd /tmp/ocsb

cp /mnt/c/Users/hugefiver/source/ocsb/tests/test_wrapper.sh tests/test_wrapper.sh
cp /mnt/c/Users/hugefiver/source/ocsb/tests/test_git_worktree.sh tests/test_git_worktree.sh

OCSB="$(readlink -f result)/bin/ocsb"
echo "Binary: $OCSB"

echo ""
echo "=== test_sandbox.sh ==="
$OCSB -w test-r5 --strategy direct --overwrite -- /workspace/tests/test_sandbox.sh

echo ""
echo "=== test_wrapper.sh ==="
bash tests/test_wrapper.sh "$OCSB"

echo ""
echo "=== test_binpath.sh ==="
bash tests/test_binpath.sh /tmp/ocsb

echo ""
echo "=== test_git_worktree.sh ==="
bash tests/test_git_worktree.sh "$OCSB"

echo ""
echo "=== test_btrfs.sh ==="
bash tests/test_btrfs.sh "$OCSB"
