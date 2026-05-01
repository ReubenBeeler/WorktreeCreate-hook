#!/usr/bin/env bash
# WorktreeCreate hook for Claude Code.
#
# Replicates the default git worktree creation behavior and adds support
# for a .worktreeinclude file (gitignore syntax) that copies selected
# gitignored files into the new worktree.
#
# .worktreeinclude semantics (only applies to gitignored files):
#   <pattern>   — copy matching files into the worktree
#   !<pattern>  — exclude matching files (cancels a prior include rule)
#
# Input:  JSON on stdin (fields: cwd, session_id, hook_event_name, name, ...)
# Output: absolute path of the created worktree on stdout

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Read input
# ---------------------------------------------------------------------------
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd')
worktree_name=$(printf '%s' "$input" | jq -r '.name // empty')

if [[ -z "$worktree_name" ]]; then
    echo "worktree-create: 'name' field is required in hook input" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Find git root
# ---------------------------------------------------------------------------
if ! git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
    echo "worktree-create: not a git repository" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Resolve worktree path and branch name
# ---------------------------------------------------------------------------
# Path:   .claude/worktrees/<name>      (no prefix)
# Branch: worktree-<name>
worktree_branch="worktree-${worktree_name}"
worktrees_dir="${git_root}/.claude/worktrees"
worktree_path="${worktrees_dir}/${worktree_name}"

mkdir -p "$worktrees_dir"

# ---------------------------------------------------------------------------
# 4. Create (or reuse) the worktree — four-case logic
# ---------------------------------------------------------------------------
if [[ -d "$worktree_path" ]]; then
    if git -C "$worktree_path" rev-parse --git-dir &>/dev/null; then
        # Path already is a git worktree — reuse as-is, skip setup
        printf '%s\n' "$worktree_path"
        exit 0
    else
        echo "worktree-create: '$worktree_path' exists but is not a git worktree" >&2
        exit 1
    fi
fi

# Path doesn't exist — check branch
if git -C "$git_root" show-ref --verify --quiet "refs/heads/$worktree_branch" 2>/dev/null; then
    echo "worktree-create: branch '$worktree_branch' already exists; delete it first or choose a different name" >&2
    exit 1
fi

# Neither path nor branch exists — create fresh branch from HEAD
git -C "$git_root" worktree add -b "$worktree_branch" "$worktree_path" HEAD >&2

# ---------------------------------------------------------------------------
# 5. Process .worktreeinclude files (gitignore-style traversal)
# ---------------------------------------------------------------------------
# Files that are gitignored by standard rules
mapfile -d '' standard_ignored < <(
    git -C "$git_root" ls-files --others --ignored --exclude-standard -z 2>/dev/null || true
)

# Files matched by .worktreeinclude patterns using git's own gitignore engine,
# traversing every directory (mirrors how .gitignore works):
#   --exclude-per-directory=.worktreeinclude  looks for .worktreeinclude in each
#   directory and applies its rules relative to that directory — identical to
#   how git handles .gitignore files.
# Semantics align perfectly:
#   pattern  → git "ignores" it → we include it in the worktree
#   !pattern → git un-ignores it → we exclude it from the worktree
# No standard excludes are applied, so only .worktreeinclude rules govern the set.
mapfile -d '' include_matched < <(
    git -C "$git_root" ls-files --others --ignored \
        --exclude-per-directory=.worktreeinclude -z 2>/dev/null || true
)

# Build a lookup set of include_matched paths using an associative array
declare -A in_include
for f in "${include_matched[@]}"; do
    [[ -n "$f" ]] && in_include["$f"]=1
done

# Copy files that appear in both sets (gitignored AND matched by .worktreeinclude)
for rel_path in "${standard_ignored[@]}"; do
    [[ -z "$rel_path" ]] && continue
    [[ -z "${in_include[$rel_path]+_}" ]] && continue

    src="${git_root}/${rel_path}"
    dst="${worktree_path}/${rel_path}"
    mkdir -p "$(dirname "$dst")"
    if [[ -f "$src" ]]; then
        cp -p "$src" "$dst"
    elif [[ -d "$src" ]]; then
        cp -rp "$src" "$dst"
    fi
done

# ---------------------------------------------------------------------------
# 6. Initialize submodules selected by .worktreeinclude
# ---------------------------------------------------------------------------
mapfile -t _sm_paths < <(
    git -C "$git_root" submodule status 2>/dev/null | awk '{print $2}' || true
)

if [[ ${#_sm_paths[@]} -gt 0 ]]; then
    # Build a temp git repo mapping .worktreeinclude → .gitignore so that
    # git check-ignore --no-index can match submodule paths using the same
    # gitignore engine (and nested-file traversal) as section 5.
    _tmp=$(mktemp -d)
    git init -q "$_tmp"

    while IFS= read -r -d '' _wti; do
        _rel="${_wti#${git_root}/}"
        _dir=$(dirname "$_rel")
        mkdir -p "$_tmp/$_dir"
        cp "$_wti" "$_tmp/$_dir/.gitignore"
    done < <(find "$git_root" -name '.worktreeinclude' \
                  -not -path "${git_root}/.git/*" \
                  -not -path "${git_root}/.claude/worktrees/*" \
                  -print0 2>/dev/null)

    for _sm in "${_sm_paths[@]}"; do
        [[ -z "$_sm" ]] && continue
        if git -C "$_tmp" check-ignore --no-index -q -- "$_sm" 2>/dev/null; then
            # Included submodule: check out at the exact commit the parent repo expects
            _sm_commit=$(git -C "$git_root" rev-parse "HEAD:${_sm}")
            _git_common_dir=$(git -C "$git_root" rev-parse --git-common-dir)
            _module_dir="${_git_common_dir}/modules/${_sm}"
            if [[ -d "$_module_dir" ]]; then
                # Reuse existing module cache — no remote URL needed
                git -C "$_module_dir" worktree add \
                    --detach "$worktree_path/$_sm" "$_sm_commit" >&2 || \
                    echo "worktree-create: warning: submodule worktree add failed for $_sm" >&2
            else
                git -c protocol.file.allow=always -C "$worktree_path" \
                    submodule update --init -- "$_sm" >&2 || \
                    echo "worktree-create: warning: submodule init failed for $_sm" >&2
            fi
        fi
        # Excluded submodule: create an empty placeholder directory.
        # An empty dir at a gitlink path (no .git file, not registered in
        # .git/config) is invisible to 'git status' — it does NOT appear as deleted.
        # We always mkdir here because 'git worktree add' does not create
        # directories for gitlink (submodule) entries.
        mkdir -p "${worktree_path}/${_sm}"
    done

    rm -rf "$_tmp"
fi

# ---------------------------------------------------------------------------
# 7. Output the worktree path (required by Claude Code)
# ---------------------------------------------------------------------------
printf '%s\n' "$worktree_path"
