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
# Input:  JSON on stdin (fields: cwd, session_id, hook_event_name, ...)
# Output: absolute path of the created worktree on stdout

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Read input
# ---------------------------------------------------------------------------
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd')

# ---------------------------------------------------------------------------
# 2. Find git root
# ---------------------------------------------------------------------------
if ! git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
    echo "worktree-create: not a git repository" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Default behavior: create a git worktree with a new branch based on HEAD
# ---------------------------------------------------------------------------
# Generate a unique name using /dev/urandom (portable, no python/openssl needed)
rand_hex=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
worktree_name="worktree-${rand_hex}"
worktrees_dir="${git_root}/.claude/worktrees"
worktree_path="${worktrees_dir}/${worktree_name}"

mkdir -p "$worktrees_dir"
git -C "$git_root" worktree add -b "$worktree_name" "$worktree_path" HEAD

# ---------------------------------------------------------------------------
# 4. Process .worktreeinclude (if present)
# ---------------------------------------------------------------------------
include_file="${git_root}/.worktreeinclude"

if [[ -f "$include_file" ]]; then
    # Files that are gitignored by standard rules
    mapfile -d '' standard_ignored < <(
        git -C "$git_root" ls-files --others --ignored --exclude-standard -z 2>/dev/null || true
    )

    # Files matched by .worktreeinclude patterns (using git's own gitignore engine).
    # Semantics align perfectly:
    #   pattern  → git "ignores" it → we include it in the worktree
    #   !pattern → git un-ignores it → we exclude it from the worktree
    mapfile -d '' include_matched < <(
        git -C "$git_root" \
            -c "core.excludesFile=${include_file}" \
            ls-files --others --ignored --no-exclude-standard -z 2>/dev/null || true
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
fi

# ---------------------------------------------------------------------------
# 5. Output the worktree path (required by Claude Code)
# ---------------------------------------------------------------------------
printf '%s\n' "$worktree_path"
