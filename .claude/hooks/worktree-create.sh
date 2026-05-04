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
    # Skip if src is the worktree itself or an ancestor of it (would copy into itself).
    # Strip trailing slash from src — git ls-files appends '/' to directory entries.
    src_norm="${src%/}"
    if [[ "$src_norm" == "$worktree_path" ]] || [[ "$worktree_path" == "${src_norm}/"* ]]; then
        continue
    fi
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
            # Included submodule: check out the exact commit the parent records.
            _sm_commit=$(git -C "$git_root" rev-parse "HEAD:${_sm}")
            _sm_initialized=false

            # Phase A: reuse local git objects via 'git worktree add'.
            # This is the preferred path: it requires no network access and
            # correctly handles commits that exist locally but haven't been
            # pushed to the remote (local-only commits would cause Phase B to
            # fail with "upload-pack: not our ref").
            #
            # Two locations are checked for the local git object store:
            #   1. Standard:   .git/modules/<sm>        (modern git submodule setup)
            #   2. Old-style:  <sm>/.git (directory)    (embedded git dir, not separated)
            _module_dir="${git_root}/.git/modules/${_sm}"
            if [[ ! -d "$_module_dir" ]] && [[ -d "${git_root}/${_sm}/.git" ]]; then
                # Old-style submodule: git objects are stored in the submodule's
                # own embedded .git/ directory instead of .git/modules/.
                _module_dir="${git_root}/${_sm}/.git"
            fi

            if [[ -d "$_module_dir" ]]; then
                git -C "$_module_dir" worktree prune 2>/dev/null || true
                if git -C "$_module_dir" worktree add \
                       --detach "${worktree_path}/${_sm}" "$_sm_commit" >&2; then
                    _sm_initialized=true
                elif git -C "$_module_dir" cat-file -e "${_sm_commit}^{commit}" 2>/dev/null; then
                    # worktree add failed (e.g. locked registration) but the
                    # commit exists locally — clone directly from the local
                    # git dir, no network required.
                    if git clone --local --no-hardlinks \
                           "$_module_dir" "${worktree_path}/${_sm}" >&2; then
                        git -C "${worktree_path}/${_sm}" \
                            checkout --detach "$_sm_commit" >&2 || true
                        _sm_initialized=true
                    fi
                fi
            fi

            # Phase B: fallback — use git's submodule machinery (clones from
            # remote URL).  Only reached when Phase A found no usable local
            # git object store, or when the local clone itself failed.
            # On success, force the exact commit (submodule update checks out
            # remote HEAD, not necessarily the gitlink commit).
            # On failure, deinit to remove the stale URL registration that
            # 'git submodule init' wrote to .git/config — without this,
            # git status reports "modified content" for the empty directory.
            if [[ "$_sm_initialized" == false ]]; then
                if git -c protocol.file.allow=always -C "$worktree_path" \
                       submodule update --init -- "$_sm" >&2; then
                    git -C "$worktree_path/$_sm" checkout --detach "$_sm_commit" >&2 || \
                        echo "worktree-create: warning: submodule checkout failed for $_sm" >&2
                    _sm_initialized=true
                else
                    git -C "$worktree_path" submodule deinit -f -- "$_sm" \
                        >/dev/null 2>&1 || true
                    echo "worktree-create: warning: submodule init failed for $_sm" >&2
                fi
            fi

            # Nested submodules: initialize individually with deinit-on-failure.
            # Same Phase A → Phase B logic as above.
            # 'git submodule init' registers a nested submodule URL in git/config
            # BEFORE attempting the clone.  If the clone fails (e.g. SSH key
            # not available), that registration remains but no checkout exists —
            # 'git status' then reports "modified content" for the parent.
            # Calling 'git submodule deinit -f' removes the stale registration
            # so the empty placeholder dir is invisible to git status.
            if [[ "$_sm_initialized" == true ]] && [[ -e "$worktree_path/$_sm/.gitmodules" ]]; then
                _sm_common=$(git -C "$worktree_path/$_sm" rev-parse \
                    --git-common-dir 2>/dev/null || true)
                # --git-common-dir may return a relative path; make it absolute.
                [[ -n "$_sm_common" && "$_sm_common" != /* ]] && \
                    _sm_common="${worktree_path}/${_sm}/${_sm_common}"
                mapfile -t _nested_paths < <(
                    git config --file "$worktree_path/$_sm/.gitmodules" \
                        --get-regexp 'submodule\..*\.path' 2>/dev/null | awk '{print $2}' || true
                )
                for _nested in "${_nested_paths[@]}"; do
                    [[ -z "$_nested" ]] && continue
                    _nested_commit=$(git -C "$worktree_path/$_sm" rev-parse \
                        "HEAD:${_nested}" 2>/dev/null || true)
                    [[ -z "$_nested_commit" ]] && continue
                    _nested_initialized=false
                    # Phase C-A: reuse nested module cache
                    _nested_mod="${_sm_common}/modules/${_nested}"
                    if [[ -d "$_nested_mod" ]]; then
                        git -C "$_nested_mod" worktree prune 2>/dev/null || true
                        if git -C "$_nested_mod" worktree add \
                               --detach "${worktree_path}/${_sm}/${_nested}" \
                               "$_nested_commit" >&2; then
                            _nested_initialized=true
                        fi
                    fi
                    # Phase C-B: fallback clone with deinit-on-failure
                    if [[ "$_nested_initialized" == false ]]; then
                        if git -c protocol.file.allow=always -C "$worktree_path/$_sm" \
                               submodule update --init -- "$_nested" >&2; then
                            _nested_initialized=true
                        else
                            git -C "$worktree_path/$_sm" submodule deinit -f -- "$_nested" \
                                >/dev/null 2>&1 || true
                            echo "worktree-create: warning: nested submodule init failed for ${_sm}/${_nested}" >&2
                        fi
                    fi
                    mkdir -p "${worktree_path}/${_sm}/${_nested}"
                done
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
