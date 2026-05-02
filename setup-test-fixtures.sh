#!/usr/bin/env bash
# Generates all untracked/gitignored test fixtures needed by the test suite.
# Idempotent — safe to run multiple times.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
cd "$REPO"

echo "Setting up test fixtures in $REPO ..."

# ── Prune stale worktrees ────────────────────────────────────────────────────
git worktree prune 2>/dev/null || true

# ── Gitignored fixture files ─────────────────────────────────────────────────
mkdir -p secrets build/cache dist deep/a/b/c logs src/__pycache__ \
         node_modules/lodash Temp temp other

echo "LOCAL_DB_URL=postgres://localhost/dev"  > secrets/.env.local
echo "PROD_DB_URL=postgres://prod-host/mydb"  > secrets/.env.production
echo "console.log('hello');"                  > build/output.js
echo '{"key":"cached_value"}'                 > build/cache/data.json
echo "var app={};"                            > dist/app.bundle.js
echo "deep cache"                             > deep/a/b/c/cache
echo "app started"                            > logs/app.log
echo "2024-01 events"                         > logs/2024-01.log
printf '\x00\x01\x02\x03 pyc stub'           > src/__pycache__/module.pyc
echo "src build cache"                        > src/build.cache
echo "src nested cache"                       > src/nested.cache
echo "other build cache"                      > other/build.cache
echo "function get(){}"                       > node_modules/lodash/get.js
echo "scratch content"                        > Temp/scratch.txt
echo "more scratch"                           > temp/scratch.txt
echo "old api backup"                         > api.bak
echo "notes backup caps"                      > notes.bAk
echo "one char prefix"                        > a.txt
echo "two char prefix"                        > bc.txt
echo "this file is un-ignored by .gitignore"  > logs/important.log

# ── Nested .worktreeinclude ──────────────────────────────────────────────────
echo "*.cache" > src/.worktreeinclude

# ── Nested git repo (libs/vendor/) ───────────────────────────────────────────
mkdir -p libs/vendor
if [[ ! -d libs/vendor/.git ]]; then
    git init libs/vendor
fi
echo "secret.key"              > libs/vendor/.gitignore
echo "public content"          > libs/vendor/README.md
echo "SUPER_SECRET_API_KEY=abc123" > libs/vendor/secret.key
git -C libs/vendor add -A
git -C libs/vendor diff --cached --quiet || \
    git -C libs/vendor commit -m "init nested repo"

# ── Submodule bare upstreams ─────────────────────────────────────────────────
upstreams="$REPO/.claude/test-upstreams"
mkdir -p "$upstreams"

for name in alpha beta gamma; do
    bare="$upstreams/$name.git"
    if [[ ! -d "$bare" ]]; then
        tmp=$(mktemp -d)
        git init "$tmp"
        echo "$name content" > "$tmp/README.md"
        git -C "$tmp" add README.md
        git -C "$tmp" commit -m "init"
        git clone --bare "$tmp" "$bare"
        rm -rf "$tmp"
    fi
done

# Wire gamma as a nested submodule inside alpha (push the change to alpha's bare upstream).
alpha_tmp=$(mktemp -d)
git clone "$upstreams/alpha.git" "$alpha_tmp"
if [[ ! -f "$alpha_tmp/.gitmodules" ]]; then
    git -C "$alpha_tmp" -c protocol.file.allow=always \
        submodule add "$upstreams/gamma.git" nested/gamma
    git -C "$alpha_tmp" commit -m "add nested gamma submodule"
    git -C "$alpha_tmp" push
fi
rm -rf "$alpha_tmp"

# Fully deinit submodules (clears .git/modules/* with stale cached URLs)
git submodule deinit --all --force 2>/dev/null || true
rm -rf .git/modules/submodules 2>/dev/null || true

# Set URLs in .git/config and initialize submodules.
# .gitmodules holds a portable placeholder; .git/config overrides it at runtime.
git config submodule.submodules/alpha.url "$upstreams/alpha.git"
git config submodule.submodules/beta.url "$upstreams/beta.git"
git -c protocol.file.allow=always submodule update --init --remote

# Update recorded submodule refs so worktrees (created from HEAD) see the correct hashes
git add submodules/alpha submodules/beta
if ! git diff --cached --quiet; then
    git commit -m "Update submodule refs for current test upstreams"
fi

echo "Test fixtures ready."
