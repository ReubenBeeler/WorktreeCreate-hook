#!/usr/bin/env bash
# WorktreeRemove hook for Claude Code.
#
# Removes a worktree under .claude/worktrees/ only when nothing would be lost;
# otherwise keeps it. Kept if the worktree or any initialized submodule
# (recursively) has:
#   - modified, staged, or untracked files (gitignored files don't count)
#   - a merge/rebase/cherry-pick/revert/bisect in progress
#   - commits that no surviving repo can reach (a detached top-level HEAD, or
#     submodule commits whose repo is deleted along with the worktree)
# or the worktree is locked or contains other registered worktrees.
#
# One rule for every caller: worktree-session-title.sh titles worktree
# sessions, so Claude Code asks Keep/Remove on exit and this hook runs only
# after "Remove" (or for unprompted cleanup, e.g. a finished subagent, where
# Claude Code's own default is also "remove only if clean").
#
# Branches are never deleted or moved, and no branch naming is assumed.
#
# Input:  JSON on stdin (fields: worktree_path, cwd, session_id, ...)
# Output: nothing on stdout; diagnostics on stderr, first line = outcome
# Exit:   0 = removed (or already gone); non-zero = kept, Claude Code leaves
#         the directory in place
#
# Requirements: bash 3.2+, git 2.26+, jq. Verified against Claude Code 2.1.288.

set -Eeuo pipefail

P=worktree-remove
trap 'if [[ $BASH_SUBSHELL -eq 0 ]]; then echo "$P: kept: unexpected error (line $LINENO)" >&2; fi' ERR

# keep <class> [detail...]: report and exit non-zero.
keep() {
    local d
    echo "$P: kept: $1" >&2
    shift
    for d in "$@"; do echo "$P:   $d" >&2; done
    exit 1
}
unverifiable() { keep "could not verify" "$@"; }

# phys <dir>: REPLY = physical absolute path of an existing directory.
phys() { REPLY=$(cd "$1" 2>/dev/null && pwd -P); }

# absdir <base> <path>: phys of <path>, resolved against <base> if relative.
absdir() {
    if [[ $2 == /* ]]; then phys "$2"; else phys "$1/$2"; fi
}

# inside <path> <dir>: <path> is <dir> or below it.
inside() { [[ $1 == "$2" || $1 == "$2/"* ]]; }

# scan_worktrees <git-dir>: parse its worktree list relative to $target.
# Sets LISTED (target registered and not the main worktree), NESTED (worktrees
# strictly inside target) and HEADS (HEADs of other existing worktrees, plus
# the repo's own HEAD). Fails if the list can't be read or parsed.
scan_worktrees() {
    local out line i p paths=() heads=()
    LISTED=0 NESTED=() HEADS=()
    out=$(git -C "$1" worktree list --porcelain 2>/dev/null) || return 1
    while IFS= read -r line; do
        case $line in
            "worktree "*) paths+=("${line#worktree }"); heads+=("") ;;
            "HEAD "*)
                [[ ${#paths[@]} -gt 0 ]] || return 1
                heads[${#heads[@]} - 1]=${line#HEAD }
                ;;
        esac
    done <<<"$out"
    [[ ${#paths[@]} -gt 0 ]] || return 1
    for ((i = 0; i < ${#paths[@]}; i++)); do
        phys "${paths[i]}" || continue
        p=$REPLY
        if [[ $p == "$target" ]]; then
            if [[ $i -gt 0 ]]; then LISTED=1; fi
        elif inside "$p" "$target"; then
            NESTED+=("$p")
        elif [[ -n ${heads[i]} ]]; then
            HEADS+=("${heads[i]}")
        fi
    done
    if p=$(git --git-dir="$1" rev-parse -q --verify HEAD 2>/dev/null); then
        HEADS+=("$p")
    fi
}

# module_for <parent-dir> <path-in-parent> <parent-module>: REPLY = the
# surviving module dir that may hold this submodule's objects, or "".
module_for() {
    local line name=""
    REPLY=""
    [[ -n $3 ]] || return 0
    while IFS= read -r line; do
        if [[ ${line#* } == "$2" ]]; then
            name=${line%% *}
            name=${name#submodule.}
            name=${name%.path}
            break
        fi
    done <<<"$(git config -f "$1/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)"
    if [[ -n $name && -d $3/modules/$name ]]; then
        REPLY=$3/modules/$name
    elif [[ -d $3/modules/$2 ]]; then
        REPLY=$3/modules/$2
    fi
}

# check_status <repo> <label>: keep if git status shows anything.
check_status() {
    local out line t xy sub a b c d e f g path cls kinds="" details=()
    out=$(git --no-optional-locks -c status.showUntrackedFiles=normal \
        -c diff.ignoreSubmodules=none -C "$1" status --porcelain=v2 \
        --untracked-files=normal --ignore-submodules=none 2>/dev/null) \
        || unverifiable "$2: git status failed"
    [[ -n $out ]] || return 0
    while IFS= read -r line; do
        sub=N
        case $line in
            "? "*) t=untracked path=${line#? } ;;
            "1 "*) read -r t xy sub a b c d e path <<<"$line"; t=changed ;;
            "2 "*) read -r t xy sub a b c d e f path <<<"$line"; t=changed; path=${path%%$'\t'*} ;;
            "u "*) read -r t xy sub a b c d e f g path <<<"$line"; t=changed ;;
            *) t=changed path=$line ;;
        esac
        if [[ $sub == S* ]]; then t=submodule; fi
        kinds="$kinds $t"
        if [[ ${#details[@]} -lt 10 ]]; then
            if [[ $2 == . ]]; then details+=("$t: $path"); else details+=("$t: $2/$path"); fi
        fi
    done <<<"$out"
    if [[ $2 != . ]]; then
        cls="submodule changes"
    elif [[ $kinds == *changed* ]]; then
        cls="uncommitted changes"
    elif [[ $kinds == *untracked* ]]; then
        cls="untracked files"
    else
        cls="submodule changes"
    fi
    keep "$cls" ${details[@]+"${details[@]}"}
}

# check_ops <git-dir> <label>: keep if a git operation is in progress.
check_ops() {
    local f
    for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
        if [[ -e $1/$f ]]; then keep "git operation in progress" "$2: $f"; fi
    done
}

# Verify everything; sets COMMON, SUPER and PRUNE on success.
verify() {
    local out top gd common i r rel pm m gd_r cd_r head tip res line p dying
    local q_path=() q_rel=() q_pm=() q_parent=() q_sub=() dying_dirs=() tips=() excl=()

    out=$(git -C "$target" rev-parse --show-toplevel --git-dir --git-common-dir 2>/dev/null) \
        || keep "not a removable worktree" "not a git worktree: $target"
    { IFS= read -r top; IFS= read -r gd; IFS= read -r common; } <<<"$out"
    absdir "$target" "$top" && top=$REPLY || unverifiable "cannot resolve $top"
    absdir "$target" "$gd" && gd=$REPLY || unverifiable "cannot resolve $gd"
    absdir "$target" "$common" && common=$REPLY || unverifiable "cannot resolve $common"
    [[ $top == "$target" ]] || keep "not a removable worktree" "not a worktree root: $target"
    [[ $gd != "$common" ]] || keep "not a removable worktree" "not a linked worktree: $target"
    [[ ${common##*/} == .git ]] || keep "not a removable worktree" "not a worktree of a main checkout: $target"
    SUPER=${common%/.git}
    [[ $target == "$SUPER/.claude/worktrees/"?* ]] \
        || keep "not a removable worktree" "not under $SUPER/.claude/worktrees/"

    scan_worktrees "$common" || unverifiable "cannot read worktree list of $common"
    [[ $LISTED == 1 ]] || keep "not a removable worktree" "not a registered worktree: $target"
    if [[ ${#NESTED[@]} -gt 0 ]]; then keep "contains other worktrees" "${NESTED[@]}"; fi
    if [[ -e $gd/locked ]]; then
        line=$(cat "$gd/locked" 2>/dev/null) || line=""
        keep "locked" ${line:+"$line"}
    fi

    COMMON=$common PRUNE=()
    dying_dirs=("$gd")
    q_path=("$target") q_rel=(.) q_pm=("") q_parent=("") q_sub=("")

    # Walk the worktree and its initialized submodules, parents first.
    for ((i = 0; i < ${#q_path[@]}; i++)); do
        r=${q_path[i]} rel=${q_rel[i]} pm=${q_pm[i]}
        if [[ $i -eq 0 ]]; then
            gd_r=$gd cd_r=$common
        else
            out=$(git -C "$r" rev-parse --git-dir --git-common-dir 2>/dev/null) \
                || unverifiable "$rel: cannot read git dir"
            { IFS= read -r gd_r; IFS= read -r cd_r; } <<<"$out"
            absdir "$r" "$gd_r" && gd_r=$REPLY || unverifiable "$rel: cannot resolve $gd_r"
            absdir "$r" "$cd_r" && cd_r=$REPLY || unverifiable "$rel: cannot resolve $cd_r"
        fi

        check_ops "$gd_r" "$rel"
        check_status "$r" "$rel"

        # A repo dies if its common dir is inside the target or inside a git
        # dir that removing the target destroys.
        dying=0
        if inside "$cd_r" "$target"; then dying=1; fi
        for p in "${dying_dirs[@]}"; do
            if inside "$cd_r" "$p"; then dying=1; fi
        done
        if [[ $gd_r != "$cd_r" ]]; then dying_dirs+=("$gd_r"); fi

        if [[ $dying -eq 0 ]]; then
            # HEAD must stay reachable in the surviving repo.
            m=$cd_r
            if [[ $m != "$common" ]]; then PRUNE+=("$m"); fi
            scan_worktrees "$m" || unverifiable "$rel: cannot read worktree list of $m"
            res=$(git -C "$r" rev-list -n1 HEAD --not --branches --tags --remotes \
                ${HEADS[@]+"${HEADS[@]}"} 2>/dev/null) || unverifiable "$rel: git rev-list failed"
            if [[ -n $res ]]; then
                if [[ $i -eq 0 ]]; then
                    keep "unreachable detached commits" "$res is on no branch, tag, or other worktree"
                fi
                keep "unpushed submodule commits" "$rel: $res is on no branch, tag, or other worktree"
            fi
        else
            # Every HEAD/branch/tag tip must be on the repo's own remotes or
            # in a surviving module dir.
            if git -C "$r" rev-parse -q --verify refs/stash >/dev/null 2>&1; then
                keep "unpushed submodule commits" "$rel: has stashed changes"
            fi
            module_for "${q_parent[i]}" "${q_sub[i]}" "$pm"
            m=$REPLY
            tips=()
            if head=$(git -C "$r" rev-parse -q --verify HEAD 2>/dev/null); then tips+=("$head"); fi
            out=$(git -C "$r" for-each-ref \
                --format='%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)' \
                refs/heads refs/tags 2>/dev/null) \
                || unverifiable "$rel: cannot list refs"
            while IFS= read -r line; do
                if [[ -n $line ]]; then tips+=("$line"); fi
            done <<<"$out"
            excl=()
            if [[ -n $m ]]; then
                scan_worktrees "$m" || unverifiable "$rel: cannot read worktree list of $m"
                excl=(${HEADS[@]+"${HEADS[@]}"})
            fi
            for tip in ${tips[@]+"${tips[@]}"}; do
                res=$(git -C "$r" rev-list -n1 "$tip" --not --remotes 2>/dev/null) \
                    || unverifiable "$rel: git rev-list failed"
                [[ -n $res ]] || continue
                if [[ -n $m ]] && git --git-dir="$m" cat-file -e "$tip^{commit}" 2>/dev/null; then
                    res=$(git --git-dir="$m" rev-list -n1 "$tip" --not --branches --tags --remotes \
                        ${excl[@]+"${excl[@]}"} 2>/dev/null) || unverifiable "$rel: git rev-list failed in $m"
                    [[ -n $res ]] || continue
                fi
                keep "unpushed submodule commits" "$rel: $tip would be lost (not on its remotes or in a surviving module dir)"
            done
        fi

        # Queue initialized submodules.
        out=$(git -C "$r" -c core.quotepath=off ls-files -s 2>/dev/null) \
            || unverifiable "$rel: git ls-files failed"
        while IFS= read -r line; do
            [[ $line == "160000 "* ]] || continue
            p=${line#*$'\t'}
            [[ $p != \"* ]] || unverifiable "$rel: unsupported submodule path $p"
            [[ -e $r/$p/.git ]] || continue
            res=$(git -C "$r/$p" rev-parse --show-toplevel 2>/dev/null) \
                || unverifiable "$rel/$p: broken submodule git dir"
            absdir "$r/$p" "$res" || unverifiable "$rel/$p: cannot resolve $res"
            res=$REPLY
            phys "$r/$p" || unverifiable "$rel/$p: cannot resolve"
            [[ $res == "$REPLY" ]] || continue
            q_path+=("$REPLY") q_parent+=("$r") q_sub+=("$p")
            if [[ $rel == . ]]; then q_rel+=("$p"); else q_rel+=("$rel/$p"); fi
            if [[ $dying -eq 0 ]]; then q_pm+=("$cd_r"); else q_pm+=("$m"); fi
        done <<<"$out"
    done
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
for _dep in git jq; do
    command -v "$_dep" >/dev/null 2>&1 || unverifiable "required command '$_dep' not found in PATH"
done

input=$(cat)
wt=$(printf '%s' "$input" \
    | jq -r '.worktree_path | if type == "string" then . else empty end' 2>/dev/null) \
    || keep "not a removable worktree" "invalid hook input"
[[ -n $wt ]] || keep "not a removable worktree" "missing worktree_path"
[[ $wt == /* ]] || keep "not a removable worktree" "worktree_path is not absolute: $wt"
if [[ ! -e $wt && ! -L $wt ]]; then
    echo "$P: already removed: $wt" >&2
    exit 0
fi
phys "$wt" || keep "not a removable worktree" "not a directory: $wt"
target=$REPLY

# ---------------------------------------------------------------------------
# Verify, then remove
# ---------------------------------------------------------------------------
cd /
verify
cd "$SUPER" 2>/dev/null || true
branch=$(git -C "$target" symbolic-ref -q --short HEAD 2>/dev/null) || branch=""

trap 'if [[ $BASH_SUBSHELL -eq 0 ]]; then echo "$P: removal failed; unexpected error (line $LINENO)" >&2; fi' ERR
err=""
err=$(git -C "$COMMON" worktree remove --force "$target" 2>&1 >/dev/null) || true

for _m in ${PRUNE[@]+"${PRUNE[@]}"}; do
    git -C "$_m" worktree prune >/dev/null 2>&1 || true
done

if [[ -e $target ]]; then
    echo "$P: removal failed; directory may be partially deleted: $target" >&2
    while IFS= read -r _line; do
        if [[ -n $_line ]]; then echo "$P:   $_line" >&2; fi
    done <<<"$err"
    exit 1
fi

# Drop empty parents of slash names (feature/auth), up to .claude/worktrees.
_d=${target%/*}
while [[ $_d == "$SUPER/.claude/worktrees/"?* ]]; do
    rmdir "$_d" 2>/dev/null || break
    _d=${_d%/*}
done

if [[ -n $branch ]]; then
    echo "$P: removed $target; branch $branch kept" >&2
else
    echo "$P: removed $target; detached HEAD" >&2
fi
exit 0
