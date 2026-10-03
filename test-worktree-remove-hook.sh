#!/usr/bin/env bash
# Tests worktree-remove.sh against a throwaway sandbox repo (under mktemp -d);
# never touches this repo's branches or worktrees.
# Requires git 2.32+ (GIT_CONFIG_GLOBAL) and jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/.claude/hooks/worktree-remove.sh"
CREATE="$HERE/.claude/hooks/worktree-create.sh"
SH="${BASH:-bash}"
REAL_GIT="$(command -v git)"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

SB="$(mktemp -d "${TMPDIR:-/tmp}/wt-remove-test.XXXXXX")"
SB="$(cd "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT

MAIN="$SB/main"
WTS="$MAIN/.claude/worktrees"
M="$MAIN/.git/modules/submodules/alpha"
MG="$M/modules/nested/gamma"

q() { "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Sandbox: upstreams alpha (with nested gamma) and beta; main with submodules
# ---------------------------------------------------------------------------
for n in alpha beta gamma; do
    q git init -q -b main "$SB/src-$n"
    echo "$n" > "$SB/src-$n/README.md"
    q git -C "$SB/src-$n" add README.md
    q git -C "$SB/src-$n" commit -qm init
    q git clone -q --bare "$SB/src-$n" "$SB/up/$n.git"
done
q git clone -q "$SB/up/alpha.git" "$SB/tmp-alpha"
q git -C "$SB/tmp-alpha" submodule add -q "$SB/up/gamma.git" nested/gamma
q git -C "$SB/tmp-alpha" commit -qm "add gamma"
q git -C "$SB/tmp-alpha" push -q

q git init -q -b main "$MAIN"
printf '.claude/worktrees/\n*.log\nsecrets/\n' > "$MAIN/.gitignore"
printf 'submodules/alpha\n' > "$MAIN/.worktreeinclude"
echo base > "$MAIN/f.txt"
echo other > "$MAIN/g.txt"
q git -C "$MAIN" add -A
q git -C "$MAIN" commit -qm init
q git -C "$MAIN" submodule add -q "$SB/up/alpha.git" submodules/alpha
q git -C "$MAIN" submodule add -q "$SB/up/beta.git" submodules/beta
q git -C "$MAIN" commit -qm submodules
q git -C "$MAIN" submodule update --init --recursive -q
q git -C "$MAIN" branch side
q git -C "$MAIN" checkout -q side
echo side >> "$MAIN/g.txt"
q git -C "$MAIN" commit -qam side
q git -C "$MAIN" checkout -q main
mkdir -p "$WTS"

if [[ ! -d $MG ]]; then
    echo "FAIL  sandbox setup (missing $MG)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
report() { # desc why
    if [[ -z $2 ]]; then
        printf "PASS  %s\n" "$1"
        PASS=$((PASS + 1))
    else
        printf "FAIL  %s  (%s)\n" "$1" "$2"
        sed 's/^/        stderr: /' "$SB/err" 2>/dev/null
        FAIL=$((FAIL + 1))
    fi
}

# mkwt <name> [cwd]: create via the create hook; sets WT, BR, TIP.
mkwt() {
    WT=$(jq -cn --arg c "${2:-$MAIN}" --arg n "$1" \
        '{session_id:"t",cwd:$c,hook_event_name:"WorktreeCreate",name:$n}' \
        | (cd "${2:-$MAIN}" && "$SH" "$CREATE" 2>/dev/null)) || WT=""
    rec
}

# mkwt_plain <name> [branch]: plain git worktree add (no submodules).
mkwt_plain() {
    WT="$WTS/$1"
    if [[ -n ${2:-} ]]; then
        q git -C "$MAIN" worktree add "$WT" "$2"
    else
        q git -C "$MAIN" worktree add -b "plain-$1" "$WT" HEAD
    fi
    rec
}

KN=0
mkk() { KN=$((KN + 1)); mkwt "k$KN"; }

rec() {
    BR=$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null) || BR=""
    TIP=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || TIP=""
}

# run_hook <path> [cwd] [json]: run the remove hook; sets RC, FIRST.
run_hook() {
    local json="${3:-}"
    if [[ -z $json ]]; then
        json=$(jq -cn --arg p "$1" --arg c "${2:-$MAIN}" \
            '{session_id:"t",transcript_path:"/dev/null",cwd:$c,hook_event_name:"WorktreeRemove",worktree_path:$p}')
    fi
    (cd "${2:-$MAIN}" && printf '%s' "$json" | "$SH" "$HOOK") >"$SB/out" 2>"$SB/err"
    RC=$?
    FIRST=$(head -n 1 "$SB/err")
}

registered() { git -C "$MAIN" worktree list --porcelain | grep -Fqx "worktree $1"; }

stale() { # any module dir still lists a worktree under <path>
    local d
    for d in "$M" "$MG"; do
        git -C "$d" worktree list --porcelain 2>/dev/null | grep -Fq "worktree $1/" && return 0
    done
    return 1
}

branch_ok() { # branch tip
    [[ -z $1 ]] || [[ $(git -C "$MAIN" rev-parse -q --verify "refs/heads/$1") == "$2" ]]
}

expect_removed() { # desc [wt] [branch] [tip]
    local wt="${2:-$WT}" br="${3-$BR}" tip="${4-$TIP}" why=""
    [[ $RC -eq 0 ]] || why+="rc=$RC; "
    [[ ! -s $SB/out ]] || why+="stdout not empty; "
    [[ $FIRST == "worktree-remove: removed "* ]] || why+="first line: $FIRST; "
    [[ ! -e $wt ]] || why+="dir still exists; "
    ! registered "$wt" || why+="still registered; "
    ! stale "$wt" || why+="stale module registration; "
    branch_ok "$br" "$tip" || why+="branch $br changed; "
    report "$1" "$why"
}

expect_kept() { # desc class [wt]
    local wt="${3:-$WT}" why=""
    [[ $RC -ne 0 ]] || why+="rc=0; "
    [[ ! -s $SB/out ]] || why+="stdout not empty; "
    [[ $FIRST == "worktree-remove: kept: $2" ]] || why+="first line: $FIRST; "
    [[ -d $wt ]] || why+="dir gone; "
    registered "$wt" || why+="not registered; "
    branch_ok "$BR" "$TIP" || why+="branch $BR changed; "
    report "$1" "$why"
}

expect_refused() { # desc path class
    local why=""
    [[ $RC -ne 0 ]] || why+="rc=0; "
    [[ ! -s $SB/out ]] || why+="stdout not empty; "
    [[ $FIRST == "worktree-remove: kept: $3" ]] || why+="first line: $FIRST; "
    [[ -z $2 || -e $2 ]] || why+="path gone; "
    report "$1" "$why"
}

drop() { # force-remove a sandbox worktree
    q git -C "$MAIN" worktree unlock "$1"
    q git -C "$MAIN" worktree remove -f -f "$1" || rm -rf "$1"
    q git -C "$MAIN" worktree prune
    q git -C "$M" worktree prune
    q git -C "$MG" worktree prune
}

commit_up() { # <wt> <sub-path>...: commit gitlinks from innermost to top
    local wt=$1 p
    shift
    for p in "$@"; do
        q git -C "$wt/${p%/*}" add "${p##*/}"
        q git -C "$wt/${p%/*}" commit -qm "bump ${p##*/}"
    done
}

echo "─────────────────────────────────────────────────────────────────────────"
echo "REMOVED (clean)"
echo "─────────────────────────────────────────────────────────────────────────"

mkwt pristine
[[ -f $WT/submodules/alpha/nested/gamma/README.md && -d $WT/submodules/beta && ! -e $WT/submodules/beta/.git ]] \
    || echo "note: unexpected create-hook layout in $WT"
run_hook "$WT"
expect_removed "pristine Phase A worktree (alpha, gamma, beta placeholder)"

mkwt_plain phaseb
q git -C "$WT" submodule update --init --recursive
[[ $(git -C "$WT/submodules/alpha" rev-parse --absolute-git-dir 2>/dev/null) == "$MAIN/.git/worktrees/phaseb/"* ]] \
    || echo "note: unexpected Phase B layout"
run_hook "$WT"
expect_removed "pristine Phase B worktree"

mkwt ignored
echo x > "$WT/new.log"
mkdir -p "$WT/secrets" && echo s > "$WT/secrets/key"
run_hook "$WT"
expect_removed "only ignored changes"

mkwt topcommit
echo more >> "$WT/f.txt"
q git -C "$WT" commit -qam more
TIP=$(git -C "$WT" rev-parse HEAD)
run_hook "$WT"
expect_removed "commits on top branch (tip preserved)"

mkwt alphabranch
echo a >> "$WT/submodules/alpha/README.md"
q git -C "$WT/submodules/alpha" commit -qam a
q git -C "$M" branch keep-alpha "$(git -C "$WT/submodules/alpha" rev-parse HEAD)"
commit_up "$WT" submodules/alpha
TIP=$(git -C "$WT" rev-parse HEAD)
run_hook "$WT"
expect_removed "Phase A alpha commit also on an alpha module branch"

mkwt fromcwd
mkdir -p "$WT/sub"
run_hook "$WT" "$WT/submodules/alpha"
expect_removed "hook cwd inside the worktree"

mkwt feature/auth
run_hook "$WT"
expect_removed "slash name feature/auth"
if [[ -e $WTS/feature ]]; then report "empty feature/ removed" "feature/ still exists"; else report "empty feature/ removed" ""; fi

mkwt feat2/other
OTHER=$WT
mkwt feat2/auth
run_hook "$WT"
expect_removed "slash name with sibling"
if [[ -d $OTHER ]]; then report "feat2/ kept for sibling" ""; else report "feat2/ kept for sibling" "sibling gone"; fi
drop "$OTHER"
rmdir "$WTS/feat2" 2>/dev/null

mkwt agent-a7654321
run_hook "$WT"
expect_removed "scratch name agent-a7654321"

q git -C "$MAIN" branch pre-existing
mkwt_plain pre pre-existing
run_hook "$WT"
expect_removed "worktree on a pre-existing branch"

if [[ $SB == /private/* && -d ${SB#/private} ]]; then
    mkwt symlinked
    run_hook "${WT#/private}"
    expect_removed "non-physical worktree_path"
fi

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "KEPT (dirty)"
echo "─────────────────────────────────────────────────────────────────────────"

mkk
echo dirty >> "$WT/f.txt"
run_hook "$WT"
expect_kept "tracked file modified" "uncommitted changes"
drop "$WT"

mkk
echo n > "$WT/new.txt"
q git -C "$WT" add new.txt
run_hook "$WT"
expect_kept "staged file" "uncommitted changes"
drop "$WT"

mkk
echo n > "$WT/new.txt"
run_hook "$WT"
expect_kept "untracked file" "untracked files"
[[ -f $WT/new.txt ]] || report "untracked file intact" "file gone"
drop "$WT"

mkk
echo m >> "$WT/submodules/alpha/README.md"
run_hook "$WT"
expect_kept "Phase A alpha modified" "submodule changes"
drop "$WT"

mkk
echo u > "$WT/submodules/alpha/u.txt"
run_hook "$WT"
expect_kept "alpha untracked" "submodule changes"
drop "$WT"

mkk
echo x > "$WT/submodules/alpha/a.log"
run_hook "$WT"
expect_kept "alpha file matching only the top-level .gitignore" "submodule changes"
drop "$WT"

mkk
echo m >> "$WT/submodules/alpha/nested/gamma/README.md"
run_hook "$WT"
expect_kept "nested gamma modified" "submodule changes"
drop "$WT"

mkk
echo u > "$WT/submodules/alpha/nested/gamma/u.txt"
run_hook "$WT"
expect_kept "nested gamma untracked" "submodule changes"

q git -C "$WT/submodules/alpha" config diff.ignoreSubmodules all
run_hook "$WT"
expect_kept "gamma untracked, alpha diff.ignoreSubmodules=all" "submodule changes"
q git -C "$WT/submodules/alpha" config --unset diff.ignoreSubmodules

q git -C "$WT/submodules/alpha" config submodule.nested/gamma.ignore all
run_hook "$WT"
expect_kept "gamma untracked, alpha submodule.nested/gamma.ignore=all" "submodule changes"
q git -C "$WT/submodules/alpha" config --unset submodule.nested/gamma.ignore

q git -C "$WT/submodules/alpha/nested/gamma" config status.showUntrackedFiles no
q git -C "$WT/submodules/alpha" config status.showUntrackedFiles no
q git -C "$MAIN" config status.showUntrackedFiles no
run_hook "$WT"
expect_kept "gamma untracked, status.showUntrackedFiles=no everywhere" "submodule changes"
q git -C "$WT/submodules/alpha/nested/gamma" config --unset status.showUntrackedFiles
q git -C "$WT/submodules/alpha" config --unset status.showUntrackedFiles
q git -C "$MAIN" config --unset status.showUntrackedFiles
drop "$WT"

mkk
echo c >> "$WT/submodules/alpha/README.md"
q git -C "$WT/submodules/alpha" commit -qam detached
commit_up "$WT" submodules/alpha
TIP=$(git -C "$WT" rev-parse HEAD)
AC=$(git -C "$WT/submodules/alpha" rev-parse HEAD)
run_hook "$WT"
expect_kept "Phase A detached alpha commit, gitlink committed" "unpushed submodule commits"
[[ $(git -C "$WT/submodules/alpha" rev-parse HEAD) == "$AC" ]] || report "alpha commit intact" "alpha HEAD moved"
drop "$WT"

mkk
echo c >> "$WT/submodules/alpha/nested/gamma/README.md"
q git -C "$WT/submodules/alpha/nested/gamma" commit -qam detached
commit_up "$WT" submodules/alpha/nested/gamma submodules/alpha
TIP=$(git -C "$WT" rev-parse HEAD)
run_hook "$WT"
expect_kept "Phase A detached gamma commit, gitlinks committed" "unpushed submodule commits"
drop "$WT"

mkwt_plain pbk
q git -C "$WT" submodule update --init --recursive
q git -C "$WT/submodules/alpha" checkout -q -b feat
echo c >> "$WT/submodules/alpha/README.md"
q git -C "$WT/submodules/alpha" commit -qam feat
commit_up "$WT" submodules/alpha
TIP=$(git -C "$WT" rev-parse HEAD)
run_hook "$WT"
expect_kept "Phase B commit on local alpha branch" "unpushed submodule commits"
drop "$WT"

mkwt_plain pbs
q git -C "$WT" submodule update --init --recursive
echo s >> "$WT/submodules/alpha/README.md"
q git -C "$WT/submodules/alpha" stash -q
run_hook "$WT"
expect_kept "Phase B stash only" "unpushed submodule commits"
drop "$WT"

mkwt_plain cl
AG=$(git -C "$MAIN" rev-parse HEAD:submodules/alpha)
rmdir "$WT/submodules/alpha" 2>/dev/null
q git clone -q --local "$M" "$WT/submodules/alpha"
q git -C "$WT/submodules/alpha" checkout -q --detach "$AG"
echo c >> "$WT/submodules/alpha/README.md"
q git -C "$WT/submodules/alpha" commit -qam clone-local
commit_up "$WT" submodules/alpha
TIP=$(git -C "$WT" rev-parse HEAD)
run_hook "$WT"
expect_kept "clone-local alpha new commit" "unpushed submodule commits"
drop "$WT"

mkk
q git -C "$WT" checkout -q --detach
echo d >> "$WT/f.txt"
q git -C "$WT" commit -qam detached
run_hook "$WT"
expect_kept "top-level detached unreachable commit" "unreachable detached commits"
drop "$WT"

mkk
q git -C "$WT" merge -q --no-commit --no-ff side
run_hook "$WT"
expect_kept "merge in progress" "git operation in progress"
drop "$WT"

mkk
q git -C "$MAIN" worktree lock --reason testing "$WT"
run_hook "$WT"
expect_kept "locked" "locked"
drop "$WT"

# A7: gamma cloned into Phase A alpha's per-worktree git dir dies with it.
WT="$WTS/a7"
q git -C "$MAIN" worktree add -q -b a7 "$WT" HEAD
q git -C "$M" worktree add -q --detach "$WT/submodules/alpha" "$(git -C "$MAIN" rev-parse HEAD:submodules/alpha)"
q git -C "$WT/submodules/alpha" submodule update --init -q -- nested/gamma
rec
case $(git -C "$WT/submodules/alpha/nested/gamma" rev-parse --absolute-git-dir 2>/dev/null) in
    "$M"/worktrees/*/modules/nested/gamma) ;;
    *) echo "note: unexpected A7 gamma layout" ;;
esac
q git -C "$WT/submodules/alpha/nested/gamma" checkout -q -b gfeat
echo g >> "$WT/submodules/alpha/nested/gamma/README.md"
q git -C "$WT/submodules/alpha/nested/gamma" commit -qam gfeat
GF=$(git -C "$WT/submodules/alpha/nested/gamma" rev-parse HEAD)
commit_up "$WT" submodules/alpha/nested/gamma
q git -C "$M" branch keep-a7 "$(git -C "$WT/submodules/alpha" rev-parse HEAD)"
commit_up "$WT" submodules/alpha
TIP=$(git -C "$WT" rev-parse HEAD)
run_hook "$WT"
expect_kept "gamma in Phase A alpha's git dir, local branch commit" "unpushed submodule commits"
[[ $(git -C "$WT/submodules/alpha/nested/gamma" rev-parse HEAD) == "$GF" ]] || report "gamma commit intact" "gamma HEAD moved"
drop "$WT"

WT="$WTS/a7p"
q git -C "$MAIN" worktree add -q -b a7p "$WT" HEAD
q git -C "$M" worktree add -q --detach "$WT/submodules/alpha" "$(git -C "$MAIN" rev-parse HEAD:submodules/alpha)"
q git -C "$WT/submodules/alpha" submodule update --init -q -- nested/gamma
rec
run_hook "$WT"
expect_removed "gamma in Phase A alpha's git dir, pristine"

# A1: nested registered worktree inside the target.
mkwt x
X=$WT
XBR=$BR
XTIP=$TIP
mkwt agent-a1234567 "$X"
N=$WT
NBR=$BR
NTIP=$TIP
echo u > "$N/untracked.txt"
WT=$X BR=$XBR TIP=$XTIP
run_hook "$X"
expect_kept "contains a dirty nested worktree" "contains other worktrees"
[[ -f $N/untracked.txt ]] || report "nested file intact" "file gone"
rm -f "$N/untracked.txt"
run_hook "$X"
expect_kept "contains a pristine nested worktree" "contains other worktrees"
run_hook "$N"
expect_removed "nested worktree itself" "$N" "$NBR" "$NTIP"
WT=$X BR=$XBR TIP=$XTIP
run_hook "$X"
expect_removed "outer worktree after nested removed"

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "FAILURES (kept)"
echo "─────────────────────────────────────────────────────────────────────────"

mkdir -p "$SB/stub-status" "$SB/stub-jq" "$SB/nojq"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = status ] && exit 1; done\nexec "%s" "$@"\n' "$REAL_GIT" > "$SB/stub-status/git"
printf '#!/bin/sh\nexit 3\n' > "$SB/stub-jq/jq"
chmod +x "$SB/stub-status/git" "$SB/stub-jq/jq"
for b in git cat rmdir head; do ln -s "$(command -v "$b")" "$SB/nojq/$b"; done

mkk
JSON=$(jq -cn --arg p "$WT" '{hook_event_name:"WorktreeRemove",worktree_path:$p}')
PATH="$SB/stub-status:$PATH" run_hook "$WT" "$MAIN" "$JSON"
expect_kept "git status fails" "could not verify"
PATH="$SB/stub-jq:$PATH" run_hook "$WT" "$MAIN" "$JSON"
expect_kept "jq fails" "not a removable worktree"
PATH="$SB/nojq" run_hook "$WT" "$MAIN" "$JSON"
expect_kept "jq missing" "could not verify"
drop "$WT"

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "REFUSED (not a removable worktree)"
echo "─────────────────────────────────────────────────────────────────────────"

run_hook "$MAIN"
expect_refused "main checkout" "$MAIN" "not a removable worktree"

mkk
run_hook "$WT/submodules/alpha"
expect_refused "Phase A submodule worktree path" "$WT/submodules/alpha" "not a removable worktree"
drop "$WT"

mkdir -p "$WTS/plain-dir"
run_hook "$WTS/plain-dir"
expect_refused "unregistered plain dir" "$WTS/plain-dir" "not a removable worktree"
rmdir "$WTS/plain-dir"

q git init -q "$WTS/repo"
run_hook "$WTS/repo"
expect_refused "unregistered repo" "$WTS/repo" "not a removable worktree"
rm -rf "$WTS/repo"

mkwt feat3/auth
run_hook "$WTS/feat3"
expect_refused "intermediate dir feat3/" "$WTS/feat3" "not a removable worktree"
drop "$WT"
rmdir "$WTS/feat3" 2>/dev/null

q git -C "$MAIN" worktree add -q -b outside "$SB/outside" HEAD
run_hook "$SB/outside"
expect_refused "registered worktree outside .claude/worktrees" "$SB/outside" "not a removable worktree"
drop "$SB/outside"

run_hook "" "$MAIN" '{"hook_event_name":"WorktreeRemove"}'
expect_refused "missing worktree_path" "" "not a removable worktree"

run_hook "" "$MAIN" '{"worktree_path": '
expect_refused "malformed JSON" "" "not a removable worktree"

run_hook "$WTS/does-not-exist"
if [[ $RC -eq 0 && ! -s $SB/out ]]; then report "nonexistent path exits 0" ""; else report "nonexistent path exits 0" "rc=$RC"; fi

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "LOCAL-ONLY SUBMODULE COMMITS (A2)"
echo "─────────────────────────────────────────────────────────────────────────"

# Detached, unpushed commit in main's alpha, recorded in main's gitlink.
q git -C "$MAIN/submodules/alpha" checkout -q --detach
echo local >> "$MAIN/submodules/alpha/README.md"
q git -C "$MAIN/submodules/alpha" commit -qam local-only
q git -C "$MAIN" add submodules/alpha
q git -C "$MAIN" commit -qm "local-only alpha"

mkwt localonly
run_hook "$WT"
expect_removed "Phase A at a local-only gitlink commit, pristine"

mkwt_plain clreach
rmdir "$WT/submodules/alpha" 2>/dev/null
q git clone -q --local "$M" "$WT/submodules/alpha"
q git -C "$WT/submodules/alpha" checkout -q --detach "$(git -C "$MAIN" rev-parse HEAD:submodules/alpha)"
run_hook "$WT"
expect_removed "clone-local HEAD reachable only via module dir HEAD"

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────────────────────────────────────"
exit $((FAIL > 0 ? 1 : 0))
