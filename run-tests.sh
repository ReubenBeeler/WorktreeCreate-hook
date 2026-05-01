#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "=== Setting up test fixtures ==="
bash "$SCRIPT_DIR/setup-test-fixtures.sh"
echo ""
echo "=== Running worktree hook tests ==="
bash "$SCRIPT_DIR/test-worktree-hook.sh"
