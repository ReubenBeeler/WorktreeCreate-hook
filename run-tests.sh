#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "=== Setting up test fixtures ==="
bash "$SCRIPT_DIR/setup-test-fixtures.sh"
echo ""
rc=0
echo "=== Running worktree hook tests ==="
bash "$SCRIPT_DIR/test-worktree-hook.sh" || rc=1
echo ""
echo "=== Running branch selection tests ==="
bash "$SCRIPT_DIR/test-branch-selection.sh" || rc=1
exit $rc
