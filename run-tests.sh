#!/usr/bin/env bash
# Runs every test suite; exits non-zero if any failed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="${BASH:-bash}"
failed=()

suite() { # name script
    echo ""
    echo "=== $1 ==="
    "$SH" "$SCRIPT_DIR/$2" || failed+=("$1")
}

suite "Setting up test fixtures" setup-test-fixtures.sh
suite "WorktreeCreate hook tests" test-worktree-hook.sh
suite "Branch selection tests" test-branch-selection.sh
suite "WorktreeRemove hook tests" test-worktree-remove-hook.sh
suite "Session title hook tests" test-worktree-session-title.sh

echo ""
if [[ ${#failed[@]} -eq 0 ]]; then
    echo "ALL SUITES PASSED"
else
    printf 'FAILED: %s\n' "${failed[@]}"
    exit 1
fi
