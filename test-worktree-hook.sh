#!/usr/bin/env bash
# Verifies that worktree-create.sh correctly copies/skips files per
# .gitignore + .worktreeinclude intersection logic.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
HOOK="$REPO/.claude/hooks/worktree-create.sh"

cleanup() {
    if [[ -n "${worktree:-}" && -d "${worktree:-}" ]]; then
        local branch
        branch="worktree-$(basename "$worktree")"
        git -C "$REPO" worktree remove --force "$worktree" 2>/dev/null || true
        git -C "$REPO" branch -D "$branch" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "Running hook..."
worktree=$(echo '{"cwd":"'"$REPO"'","session_id":"test","hook_event_name":"WorktreeCreate","name":"test-wt"}' | bash "$HOOK")
echo "Worktree: $worktree"
echo ""

PASS=0
FAIL=0

check() {
    local desc="$1"
    local file="$2"
    local want="$3"   # "yes" or "no"
    local reason="$4"

    if [[ "$want" == "yes" ]]; then
        if [[ -e "$worktree/$file" ]]; then
            printf "PASS  %-60s  %s\n" "[$desc]" "$file"
            PASS=$((PASS+1))
        else
            printf "FAIL  %-60s  %s  (MISSING — expected present)\n" "[$desc]" "$file"
            FAIL=$((FAIL+1))
        fi
    else
        if [[ ! -e "$worktree/$file" ]]; then
            printf "PASS  %-60s  %s\n" "[$desc]" "absent: $file"
            PASS=$((PASS+1))
        else
            printf "FAIL  %-60s  %s  (PRESENT — expected absent)\n" "[$desc]" "$file"
            FAIL=$((FAIL+1))
        fi
    fi
}

echo "─────────────────────────────────────────────────────────────────────────"
echo "EXPECTED INCLUSIONS"
echo "─────────────────────────────────────────────────────────────────────────"
check "secrets/.env* pattern"                  "secrets/.env.local"          yes ""
check "build/[!c]* negated char-class"         "build/output.js"             yes ""
check "dist/** double-star"                    "dist/app.bundle.js"          yes ""
check "deep/**/cache double-star"              "deep/a/b/c/cache"            yes ""
check "*.log wildcard"                         "logs/app.log"                yes ""
check "*.log wildcard"                         "logs/2024-01.log"            yes ""
check "**/__pycache__/** double-star"          "src/__pycache__/module.pyc"  yes ""
check "[Tt]emp/** char-class capital T"        "Temp/scratch.txt"            yes ""
check "[Tt]emp/** char-class lowercase t"      "temp/scratch.txt"            yes ""
check "*.b[aA]k char-class lowercase a"        "api.bak"                     yes ""
check "*.b[aA]k char-class uppercase A"        "notes.bAk"                   yes ""
check "?.txt single-char wildcard"             "a.txt"                       yes ""

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "EXPECTED EXCLUSIONS"
echo "─────────────────────────────────────────────────────────────────────────"
check "!secrets/.env.production negation"      "secrets/.env.production"     no  ""
check "build/[!c]* excludes cache/"            "build/cache/data.json"       no  ""
check "node_modules/ not in .worktreeinclude"  "node_modules/lodash/get.js"  no  ""
check "tracked: logs/important.log"             "logs/important.log"          yes ""
check "tracked: bc.txt"                         "bc.txt"                      yes ""
check "submodule isolation: nested .git"       "libs/vendor/secret.key"      no  ""

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "NESTED .worktreeinclude (src/.worktreeinclude contains *.cache)"
echo "─────────────────────────────────────────────────────────────────────────"
check "nested .worktreeinclude: src/build.cache"   "src/build.cache"   yes ""
check "nested .worktreeinclude: src/nested.cache"  "src/nested.cache"  yes ""
check "nested .worktreeinclude: not in other/"     "other/build.cache" no  ""

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "SUBMODULE HANDLING (.worktreeinclude controls submodule checkout)"
echo "─────────────────────────────────────────────────────────────────────────"
check "included submodule checked out"     "submodules/alpha/README.md"  yes ""
check "excluded submodule not checked out" "submodules/beta/README.md"   no  ""

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "WORKTREE GIT STATUS (must be clean — no deleted submodule entries)"
echo "─────────────────────────────────────────────────────────────────────────"
status_output=$(git -C "$worktree" status --porcelain 2>&1)
if [[ -z "$status_output" ]]; then
    printf "PASS  %-60s  %s\n" "[git status clean]" "worktree has no uncommitted changes"
    PASS=$((PASS+1))
else
    printf "FAIL  %-60s\n" "[git status clean]"
    echo "  git status --porcelain output:"
    echo "$status_output" | sed 's/^/    /'
    FAIL=$((FAIL+1))
fi

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────────────────────────────────────"
if [[ $FAIL -eq 0 ]]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi

echo ""
echo "Cleaning up worktree..."
# Cleanup handled by EXIT trap
exit $((FAIL > 0 ? 1 : 0))
