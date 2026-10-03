#!/usr/bin/env bash
# WorktreeCreate hook for Claude Code.
#
# Replicates the default git worktree creation behavior and adds support
# for a .worktreeinclude file (gitignore syntax) that copies selected
# gitignored files from the current worktree into the new one. The new
# worktree's branch supplies the .gitignore and .worktreeinclude rules.
#
# .worktreeinclude semantics (only applies to gitignored files):
#   <pattern>   — copy matching files into the worktree
#   !<pattern>  — exclude matching files (cancels a prior include rule)
#
# Input:  JSON on stdin (fields: cwd, session_id, hook_event_name, name, ...)
# Output: absolute path of the created worktree on stdout
#
# Path:   .claude/worktrees/<name>
# Branch: <name>. A missing branch that exists on a remote is never guessed:
#         the hook prints ready-to-run commands and exits 1. Remotes are
#         fetched first, prompt-free and capped at FETCH_TIMEOUT seconds.
#
# Requirements (cross-platform: Linux + macOS):
#   bash  — 3.2+ (the version macOS ships as /bin/bash); no bash 4 features used
#   git   — 2.26+ (worktree, ls-files -z; check-ignore -z --stdin only reports
#           truly-ignored paths — not bare pattern matches — from 2.26 on)
#   jq    — NOT bundled with macOS before 15; install with `brew install jq`
#           (this script exits with an explicit error if it is missing)
# Only POSIX/BSD-compatible invocations of cp/find/awk/mktemp are used, so no
# GNU coreutils installation is needed.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Dependency checks — fail loudly rather than mid-way through setup
# ---------------------------------------------------------------------------
for _dep in git jq; do
    if ! command -v "$_dep" >/dev/null 2>&1; then
        echo "worktree-create: required command '$_dep' not found in PATH." >&2
        echo "worktree-create: install it first (macOS: brew install $_dep)." >&2
        exit 1
    fi
done

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
# 3. Validate name; resolve worktree path and branch name
# ---------------------------------------------------------------------------
# Path:   .claude/worktrees/<name>
# Branch: <name>
# check-ref-format rejects '-x', 'HEAD', '..', leading '/', leading-dot parts;
# output differing from input means an '@{-N}' expansion.
if ! _checked_name=$(git -C "$git_root" check-ref-format --branch "$worktree_name" 2>/dev/null) \
   || [[ "$_checked_name" != "$worktree_name" ]]; then
    echo "worktree-create: '$worktree_name' is not a valid branch name" >&2
    exit 1
fi

FETCH_TIMEOUT=10
worktree_branch="$worktree_name"
worktrees_dir="${git_root}/.claude/worktrees"
worktree_path="${worktrees_dir}/${worktree_name}"

mkdir -p "$worktrees_dir"

# ---------------------------------------------------------------------------
# 4. Create (or reuse) the worktree
# ---------------------------------------------------------------------------
# In order:
#   prune stale registrations, read registrations, refuse nesting;
#   case 1: path exists          -> reuse if registered, else exit 1
#           path registered but missing (locked or unprunable) -> exit 1
#   case 2: local branch exists  -> exit 1 if checked out elsewhere, else add
#   case 3: remote branch exists -> fetch, print commands to choose, exit 1
#   case 4: no branch anywhere   -> new branch from HEAD
# Limitations: fetch has no --prune, so a branch deleted upstream may still be
# offered; single-branch/custom-refspec clones never get
# refs/remotes/<remote>/<name> and fall through to case 4.

# Wraps values outside [A-Za-z0-9._/@+-] in single quotes for copy-paste.
_q() {
    local LC_ALL=C
    case "$1" in
        ''|*[!A-Za-z0-9._/@+-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *)  printf '%s' "$1" ;;
    esac
}

# Prints every descendant pid of $1.
_descendants() {
    local _c
    for _c in $(pgrep -P "$1" 2>/dev/null || true); do
        printf '%s\n' "$_c"
        _descendants "$_c"
    done
}

git -C "$git_root" worktree prune >/dev/null 2>&1 || true

_wt_paths=()
_wt_heads=()
_wt_branches=()
_wt_locked=()
_porcelain=$(git -C "$git_root" worktree list --porcelain)
while IFS= read -r _line; do
    case "$_line" in
        "worktree "*)
            _wt_paths+=("${_line#worktree }")
            _wt_heads+=("")
            _wt_branches+=("")
            _wt_locked+=(false) ;;
        "HEAD "*)        _wt_heads[${#_wt_paths[@]}-1]="${_line#HEAD }" ;;
        "branch "*)      _wt_branches[${#_wt_paths[@]}-1]="${_line#branch }" ;;
        locked|"locked "*) _wt_locked[${#_wt_paths[@]}-1]=true ;;
    esac
done <<< "$_porcelain"

_rest="${worktree_name%/*}"
while [[ "$_rest" != "$worktree_name" && -n "$_rest" ]]; do
    for _i in ${_wt_paths[@]+"${!_wt_paths[@]}"}; do
        if [[ "${_wt_paths[_i]}" == "${worktrees_dir}/${_rest}" ]]; then
            echo "worktree-create: '$worktree_name' would be nested inside worktree '${_wt_paths[_i]}'" >&2
            exit 1
        fi
    done
    [[ "$_rest" == */* ]] || break
    _rest="${_rest%/*}"
done

# Case 1: path exists
if [[ -e "$worktree_path" || -L "$worktree_path" ]]; then
    _phys=""
    [[ -d "$worktree_path" ]] && _phys=$(cd -P "$worktree_path" 2>/dev/null && pwd -P || true)
    if [[ -n "$_phys" ]]; then
        for _i in ${_wt_paths[@]+"${!_wt_paths[@]}"}; do
            _reg=$(cd -P "${_wt_paths[_i]}" 2>/dev/null && pwd -P || true)
            [[ -n "$_reg" && "$_reg" == "$_phys" ]] || continue
            if [[ -n "${_wt_branches[_i]}" ]]; then
                _on="${_wt_branches[_i]#refs/heads/}"
            else
                _on="detached HEAD at $(git -C "$git_root" rev-parse --short "${_wt_heads[_i]}")"
            fi
            echo "worktree-create: Reusing worktree $worktree_name on branch $_on" >&2
            printf '%s\n' "$worktree_path"
            exit 0
        done
    fi
    echo "worktree-create: '$worktree_path' exists but is not a git worktree" >&2
    exit 1
fi

# Path registered but missing
for _i in ${_wt_paths[@]+"${!_wt_paths[@]}"}; do
    [[ "${_wt_paths[_i]}" == "$worktree_path" ]] || continue
    if [[ "${_wt_locked[_i]}" == true ]]; then
        echo "worktree-create: '$worktree_path' is still registered as a worktree (locked) but its directory is missing; run: git -C $(_q "$git_root") worktree unlock $(_q "$worktree_path") && git -C $(_q "$git_root") worktree prune, then retry" >&2
    else
        echo "worktree-create: '$worktree_path' is still registered as a worktree but its directory is missing; run: git -C $(_q "$git_root") worktree prune, then retry; if the registration remains, run git -C $(_q "$git_root") worktree unlock $(_q "$worktree_path") first" >&2
    fi
    exit 1
done

# Case 2: local branch exists
if git -C "$git_root" show-ref --verify --quiet "refs/heads/$worktree_branch" 2>/dev/null; then
    for _i in ${_wt_paths[@]+"${!_wt_paths[@]}"}; do
        [[ "${_wt_branches[_i]}" == "refs/heads/$worktree_branch" ]] || continue
        _lk=""
        [[ "${_wt_locked[_i]}" == true ]] && _lk=" (locked)"
        echo "worktree-create: branch '$worktree_branch' is already checked out in worktree '${_wt_paths[_i]}'$_lk" >&2
        echo "A branch can be checked out in only one worktree; switch or remove that worktree, or use a different name, then retry." >&2
        exit 1
    done
    git -C "$git_root" worktree add "$worktree_path" "$worktree_branch" >&2
else
    # Case 3: bounded, prompt-free fetch, then look for remote branches
    _remotes=()
    while IFS= read -r _r; do
        [[ -n "$_r" ]] && _remotes+=("$_r")
    done < <(git -C "$git_root" remote 2>/dev/null | LC_ALL=C sort || true)

    _fetch_failed=()
    if [[ ${#_remotes[@]} -gt 0 ]]; then
        _ssh_cmd=""
        if [[ -z "${GIT_SSH_COMMAND:-}" && -z "${GIT_SSH:-}" ]] \
           && ! git -C "$git_root" config core.sshCommand >/dev/null 2>&1; then
            _ssh_cmd="ssh -o BatchMode=yes -o ConnectTimeout=5"
        fi
        _false=$(type -P false || true)
        _deadline=$((SECONDS + FETCH_TIMEOUT))
        {
            for _r in "${_remotes[@]}"; do
                if (( SECONDS >= _deadline )); then
                    _fetch_failed+=("$_r")
                    continue
                fi
                (
                    export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= GCM_INTERACTIVE=never
                    export SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$_false"
                    [[ -n "$_ssh_cmd" ]] && export GIT_SSH_COMMAND="$_ssh_cmd"
                    exec git -C "$git_root" -c gc.auto=0 -c maintenance.auto=false \
                        fetch --quiet --no-recurse-submodules "$_r"
                ) </dev/null >/dev/null 2>&1 &
                _pid=$!
                while kill -0 "$_pid" 2>/dev/null && (( SECONDS < _deadline )); do
                    sleep 0.2
                done
                if kill -0 "$_pid" 2>/dev/null; then
                    _tree="$_pid $(_descendants "$_pid" | tr '\n' ' ')"
                    kill -TERM $_tree 2>/dev/null || true
                    kill -CONT $_tree 2>/dev/null || true
                    sleep 1
                    kill -KILL $_tree 2>/dev/null || true
                    wait "$_pid" 2>/dev/null || true
                    _fetch_failed+=("$_r")
                elif ! wait "$_pid" 2>/dev/null; then
                    _fetch_failed+=("$_r")
                fi
            done
        } 2>/dev/null
    fi
    _fetch_msg=""
    if [[ ${#_fetch_failed[@]} -gt 0 ]]; then
        _list=$(printf '%s, ' "${_fetch_failed[@]}")
        _fetch_msg="worktree-create: fetch failed or timed out for: ${_list%, }; using existing remote-tracking refs"
    fi

    _matches=()
    for _r in ${_remotes[@]+"${_remotes[@]}"}; do
        if git -C "$git_root" show-ref --verify --quiet "refs/remotes/$_r/$worktree_branch" 2>/dev/null; then
            _matches+=("$_r")
        fi
    done

    if [[ ${#_matches[@]} -gt 0 ]]; then
        _list=$(printf '%s, ' "${_matches[@]}")
        _head_desc=$(git -C "$git_root" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)
        _head_short=$(git -C "$git_root" rev-parse --short HEAD 2>/dev/null || echo unborn)
        {
            echo "worktree-create: branch '$worktree_branch' does not exist locally but exists on remote(s): ${_list%, }."
            echo "Run ONE of these to choose what '$worktree_branch' starts from, then retry:"
            echo "  git -C $(_q "$git_root") branch $(_q "$worktree_branch") HEAD  # current HEAD ($_head_desc @ $_head_short)"
            for _r in "${_matches[@]}"; do
                echo "  git -C $(_q "$git_root") branch --track $(_q "$worktree_branch") $(_q "$_r/$worktree_branch")"
            done
            [[ -z "$_fetch_msg" ]] || echo "$_fetch_msg"
        } >&2
        exit 1
    fi
    [[ -z "$_fetch_msg" ]] || echo "$_fetch_msg" >&2

    # Case 4: new branch from HEAD; explicit -b/HEAD disables remote guessing
    _head_sha=$(git -C "$git_root" rev-parse -q --verify HEAD 2>/dev/null || true)
    if ! git -C "$git_root" worktree add -b "$worktree_branch" "$worktree_path" HEAD >&2; then
        _new_sha=$(git -C "$git_root" rev-parse -q --verify "refs/heads/$worktree_branch" 2>/dev/null || true)
        _porcelain=$(git -C "$git_root" worktree list --porcelain 2>/dev/null || true)
        if [[ -n "$_head_sha" && "$_new_sha" == "$_head_sha" ]] \
           && ! printf '%s\n' "$_porcelain" | grep -qxF "branch refs/heads/$worktree_branch"; then
            git -C "$git_root" branch -D "$worktree_branch" >/dev/null 2>&1 || true
        fi
        echo "worktree-create: could not create worktree '$worktree_path'" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 5. Copy files selected by the branch's .worktreeinclude
# ---------------------------------------------------------------------------
# Rules come from the new worktree (the checked-out branch); files come from
# the current worktree. A file is copied when it is all of:
#   a) untracked in the current worktree;
#   b) matched by the branch's .worktreeinclude files;
#   c) ignored by the branch's .gitignore files (plus info/exclude and
#      core.excludesFile).
# b) and c) each mirror the branch's rule files into a temp repo as .gitignore
# files, so `check-ignore --no-index` applies them with gitignore semantics
# (pattern -> match, !pattern -> unmatch, nested files scope to their
# directory). Streaming a) through b) and c) computes the intersection with git
# itself — NUL-safe and free of bash 4 constructs, which macOS's bash 3.2 lacks.
_inc_repo=$(mktemp -d)
_ign_repo=$(mktemp -d)
trap 'rm -rf "$_inc_repo" "$_ign_repo"' EXIT
git init -q "$_inc_repo"
git init -q "$_ign_repo"
_has_wti=false
while IFS= read -r -d '' _f; do
    _rule_src="${worktree_path}/${_f}"
    [[ -f "$_rule_src" && ! -L "$_rule_src" ]] || continue
    case "$_f" in
        .worktreeinclude|*/.worktreeinclude) _repo="$_inc_repo"; _has_wti=true ;;
        .gitignore|*/.gitignore)             _repo="$_ign_repo" ;;
        *) continue ;;
    esac
    _dir=$(dirname "$_f")
    mkdir -p "$_repo/$_dir"
    cp "$_rule_src" "$_repo/$_dir/.gitignore"
done < <(git -C "$worktree_path" ls-files -z 2>/dev/null || true)

_common=$(git -C "$git_root" rev-parse --git-common-dir)
[[ "$_common" == /* ]] || _common="${git_root}/${_common}"
[[ -f "$_common/info/exclude" ]] && cp "$_common/info/exclude" "$_ign_repo/.git/info/exclude"
_ign_git=(git -C "$_ign_repo")
_xf=$(git -C "$worktree_path" config --path core.excludesFile 2>/dev/null || true)
[[ -n "$_xf" ]] && _ign_git+=(-c "core.excludesFile=$_xf")

# check-ignore matches a trailing '/' loosely ('d/**' matches 'd/'), so
# directory entries (nested repos) are re-tested bare against real temp dirs.
_dir_selected() {
    mkdir -p "$_inc_repo/$1" "$_ign_repo/$1"
    git -C "$_inc_repo" check-ignore --no-index -q -- "$1" 2>/dev/null \
        && "${_ign_git[@]}" check-ignore --no-index -q -- "$1" 2>/dev/null
}

# `git check-ignore` exits 1 when it reports nothing; the trailing `|| true`
# keeps that from tripping `set -o pipefail`.
while IFS= read -r -d '' rel_path; do
    [[ -z "$rel_path" ]] && continue
    if [[ "$rel_path" == */ ]]; then
        _dir_selected "${rel_path%/}" || continue
    fi

    src="${git_root}/${rel_path}"
    dst="${worktree_path}/${rel_path}"
    # Skip if src is the worktree itself or an ancestor of it (would copy into itself).
    # Strip trailing slash from src — git ls-files appends '/' to directory entries.
    src_norm="${src%/}"
    if [[ "$src_norm" == "$worktree_path" ]] || [[ "$worktree_path" == "${src_norm}/"* ]]; then
        continue
    fi
    # Never write through a symlink or over existing content.
    [[ -e "${dst%/}" || -L "${dst%/}" ]] && continue
    _parent_rel=$(dirname "${rel_path%/}")
    _cur="$worktree_path"
    _safe=true
    if [[ "$_parent_rel" != "." ]]; then
        _rest="$_parent_rel/"
        while [[ -n "$_rest" ]]; do
            _cur="${_cur}/${_rest%%/*}"
            _rest="${_rest#*/}"
            if [[ -L "$_cur" ]] || { [[ -e "$_cur" ]] && [[ ! -d "$_cur" ]]; }; then
                _safe=false
                break
            fi
        done
    fi
    [[ "$_safe" == true ]] || continue
    _copied=true
    if ! mkdir -p "$(dirname "$dst")"; then
        _copied=false
    elif [[ -f "$src" ]]; then
        cp -p "$src" "$dst" || _copied=false
    elif [[ -d "$src" ]]; then
        cp -Rp "$src" "$dst" || _copied=false
    fi
    [[ "$_copied" == true ]] || echo "worktree-create: warning: could not copy $rel_path" >&2
done < <(
    [[ "$_has_wti" == true ]] || exit 0
    git -C "$git_root" ls-files --others -z 2>/dev/null \
        | git -C "$_inc_repo" check-ignore --no-index -z --stdin 2>/dev/null \
        | "${_ign_git[@]}" check-ignore --no-index -z --stdin 2>/dev/null || true
)

# ---------------------------------------------------------------------------
# 6. Initialize submodules selected by the branch's .worktreeinclude
# ---------------------------------------------------------------------------
# Matched against section 5's .worktreeinclude temp repo.
# Submodule paths and commits come from the worktree's index (gitlinks, mode
# 160000), so they match the checked-out branch. Collected into arrays (rather
# than looped over directly) so the loop body's git commands cannot consume the
# reader's stdin.
_sm_paths=()
_sm_commits=()
while IFS= read -r -d '' _entry; do
    case "$_entry" in
        "160000 "*)
            _meta="${_entry%%$'\t'*}"
            _meta="${_meta#160000 }"
            _sm_commits+=("${_meta%% *}")
            _sm_paths+=("${_entry#*$'\t'}") ;;
    esac
done < <(git -C "$worktree_path" ls-files -s -z 2>/dev/null || true)

if [[ ${#_sm_paths[@]} -gt 0 ]]; then
    for _i in "${!_sm_paths[@]}"; do
        _sm="${_sm_paths[_i]}"
        [[ -z "$_sm" ]] && continue
        mkdir -p "$_inc_repo/$_sm"
        if git -C "$_inc_repo" check-ignore --no-index -q -- "$_sm" 2>/dev/null; then
            # Included submodule: check out the exact commit the worktree records.
            _sm_commit="${_sm_commits[_i]}"
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
                _nested_paths=()
                while IFS= read -r _line; do
                    [[ -n "$_line" ]] && _nested_paths+=("$_line")
                done < <(
                    git config --file "$worktree_path/$_sm/.gitmodules" \
                        --get-regexp 'submodule\..*\.path' 2>/dev/null | awk '{print $2}' || true
                )
                for _nested in ${_nested_paths[@]+"${_nested_paths[@]}"}; do
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
fi

# ---------------------------------------------------------------------------
# 7. Output the worktree path (required by Claude Code)
# ---------------------------------------------------------------------------
printf '%s\n' "$worktree_path"
