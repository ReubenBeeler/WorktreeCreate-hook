#!/usr/bin/env bash
# Verifies worktree-create.sh branch selection, fetch bounds, name validation
# and worktree-content handling in an offline sandbox (bare origin/upstream
# remotes, local clones). Never touches this repository.
# GIT_CONFIG_GLOBAL=/dev/null only takes effect on git 2.32+; older git relies
# on HOME=<sandbox> + GIT_CONFIG_NOSYSTEM=1.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
HOOK="$REPO/.claude/hooks/worktree-create.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

PASS=0
FAIL=0
OUT=""
ERR=""
RC=0

pass() {
    printf 'PASS  %s\n' "$1"
    PASS=$((PASS+1))
}

fail() {
    printf 'FAIL  %s\n' "$1"
    printf '    rc=%s\n    stdout: %s\n' "$RC" "$OUT"
    printf '%s\n' "$ERR" | sed 's/^/    stderr: /'
    FAIL=$((FAIL+1))
}

# check <description> <command...>
check() {
    local desc=$1
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

contains() { [[ "$1" == *"$2"* ]]; }

# run_hook <repo dir> <name>: sets OUT, ERR, RC
run_hook() {
    local input
    input=$(jq -n --arg cwd "$1" --arg name "$2" \
        '{cwd:$cwd, session_id:"test", hook_event_name:"WorktreeCreate", name:$name}')
    RC=0
    OUT=$(printf '%s' "$input" | bash "$HOOK" 2>"$SANDBOX/stderr") || RC=$?
    ERR=$(cat "$SANDBOX/stderr")
}

git_cfg() {
    git -C "$1" config user.name "Test"
    git -C "$1" config user.email "test@example.com"
}

commit() {
    local dir=$1 file=$2 content=$3
    printf '%s\n' "$content" > "$dir/$file"
    git -C "$dir" add -- "$file"
    git -C "$dir" commit -qm "$file: $content"
}

# make_clone <dir>: clone of origin with an 'upstream' remote
make_clone() {
    git clone -q "$SANDBOX/origin.git" "$1"
    git -C "$1" remote add upstream "$SANDBOX/upstream.git"
    git -C "$1" fetch -q upstream
    git_cfg "$1"
}

toplevel() { git -C "$1" rev-parse --show-toplevel; }

snapshot() {
    git -C "$1" for-each-ref --format='%(refname)' refs/heads
    git -C "$1" worktree list --porcelain
    find "$(toplevel "$1")/.claude" | LC_ALL=C sort
}

# ── Sandbox ──────────────────────────────────────────────────────────────────
for r in origin upstream; do
    git init -q --bare "$SANDBOX/$r.git"
    git -C "$SANDBOX/$r.git" symbolic-ref HEAD refs/heads/main
done
SEED="$SANDBOX/seed"
git init -q "$SEED"
git -C "$SEED" symbolic-ref HEAD refs/heads/main
git_cfg "$SEED"
commit "$SEED" README.md "seed"
git -C "$SEED" push -q "$SANDBOX/origin.git" main
git -C "$SEED" push -q "$SANDBOX/upstream.git" main

CLONE="$SANDBOX/clone"
make_clone "$CLONE"
ROOT=$(toplevel "$CLONE")
WT="$ROOT/.claude/worktrees"
MAIN_HEAD=$(git -C "$CLONE" rev-parse HEAD)

is_path() { [[ $RC -eq 0 && "$OUT" == "$1" ]]; }
branch_of() { git -C "$1" symbolic-ref --short -q HEAD; }
head_of() { git -C "$1" rev-parse HEAD; }
no_branch() { ! git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }

echo "── Case 4: new name ──"
run_hook "$CLONE" new1
check "new name prints worktree path" is_path "$WT/new1"
check "new name is on branch new1" [ "$(branch_of "$WT/new1")" == new1 ]
check "new branch starts at main HEAD" [ "$(head_of "$WT/new1")" == "$MAIN_HEAD" ]

echo "── Case 1: reuse ──"
run_hook "$CLONE" new1
check "reuse prints same path" is_path "$WT/new1"
check "reuse names branch" contains "$ERR" "Reusing worktree new1 on branch new1"
run_hook "$CLONE" det
git -C "$WT/det" checkout -q --detach
det_short=$(git -C "$WT/det" rev-parse --short HEAD)
run_hook "$CLONE" det
check "reuse detached prints same path" is_path "$WT/det"
check "reuse detached names commit" contains "$ERR" "Reusing worktree det on branch detached HEAD at $det_short"

echo "── Junk dir ──"
mkdir -p "$WT/junk"
touch "$WT/junk/file"
run_hook "$CLONE" junk
check "junk dir fails" [ "$RC" -ne 0 ]
check "junk dir reports not a worktree" contains "$ERR" "not a git worktree"
check "junk dir creates no branch" no_branch "$CLONE" junk

echo "── Case 2: existing local branch ──"
git -C "$CLONE" checkout -q -b feat1
commit "$CLONE" feat.txt "feat1"
feat1_head=$(head_of "$CLONE")
git -C "$CLONE" checkout -q main
run_hook "$CLONE" feat1
check "existing branch prints path" is_path "$WT/feat1"
check "existing branch checked out" [ "$(branch_of "$WT/feat1")" == feat1 ]
check "existing branch commit kept" [ "$(head_of "$WT/feat1")" == "$feat1_head" ]

echo "── Attached branch ──"
git -C "$CLONE" worktree add -q -b busy "$SANDBOX/outside"
outside=$(toplevel "$SANDBOX/outside")
run_hook "$CLONE" busy
check "branch in outside worktree fails" [ "$RC" -ne 0 ]
check "names outside worktree" contains "$ERR" "already checked out in worktree '$outside'"
check "no dir for attached branch" [ ! -e "$WT/busy" ]
run_hook "$CLONE" main
check "main branch name fails" [ "$RC" -ne 0 ]
check "names main checkout" contains "$ERR" "already checked out in worktree '$ROOT'"
check "no dir for main" [ ! -e "$WT/main" ]

echo "── Stale registration ──"
run_hook "$CLONE" stale
rm -rf "$WT/stale"
run_hook "$CLONE" stale
check "stale registration recreated" is_path "$WT/stale"
check "stale registration keeps branch" [ "$(branch_of "$WT/stale")" == stale ]

echo "── Locked and missing ──"
git -C "$CLONE" worktree add -q -b lkother "$WT/lk"
git -C "$CLONE" worktree lock "$WT/lk"
rm -rf "$WT/lk"
run_hook "$CLONE" lk
check "locked missing fails" [ "$RC" -ne 0 ]
check "locked missing suggests unlock and prune" \
    contains "$ERR" "worktree unlock $WT/lk && git -C $ROOT worktree prune"
check "locked missing creates no branch" no_branch "$CLONE" lk
git -C "$CLONE" worktree unlock "$WT/lk"
git -C "$CLONE" worktree prune
run_hook "$CLONE" lk
check "after unlock and prune succeeds" is_path "$WT/lk"

echo "── Case 3: remote branch ask ──"
git -C "$SEED" checkout -q -b rb
commit "$SEED" rb.txt "origin"
rb_origin=$(head_of "$SEED")
git -C "$SEED" push -q "$SANDBOX/origin.git" rb
commit "$SEED" rb.txt "upstream"
git -C "$SEED" push -q "$SANDBOX/upstream.git" rb
git -C "$SEED" checkout -q main
run_hook "$CLONE" rb
check "remote branch asks (non-zero)" [ "$RC" -ne 0 ]
check "ask prints nothing on stdout" [ -z "$OUT" ]
check "ask creates no dir" [ ! -e "$WT/rb" ]
check "ask creates no local branch" no_branch "$CLONE" rb
check "ask names both remotes" contains "$ERR" "exists on remote(s): origin, upstream."
ln_head=$(printf '%s\n' "$ERR" | grep -n -- "branch rb HEAD" | cut -d: -f1 || true)
ln_origin=$(printf '%s\n' "$ERR" | grep -n -- "--track rb origin/rb" | cut -d: -f1 || true)
ln_upstream=$(printf '%s\n' "$ERR" | grep -n -- "--track rb upstream/rb" | cut -d: -f1 || true)
check "ask order HEAD, origin, upstream" \
    [ "${ln_head:-0}" -gt 0 -a "${ln_origin:-0}" -gt "${ln_head:-0}" -a "${ln_upstream:-0}" -gt "${ln_origin:-0}" ]
cmd=$(printf '%s\n' "$ERR" | grep -- "--track rb origin/rb" || true)
eval "$cmd" >/dev/null
run_hook "$CLONE" rb
check "after choosing origin succeeds" is_path "$WT/rb"
check "chosen branch at origin commit" [ "$(head_of "$WT/rb")" == "$rb_origin" ]
check "chosen branch tracks origin" \
    [ "$(git -C "$CLONE" config branch.rb.remote)" == origin ]

echo "── Fetch timeout ──"
SLOW="$SANDBOX/slow"
make_clone "$SLOW"
git -C "$SLOW" config protocol.ext.allow always
sleep_arg="3600.$$$RANDOM"
git -C "$SLOW" remote add slow "ext::sleep $sleep_arg"
start=$SECONDS
run_hook "$SLOW" t9
elapsed=$((SECONDS - start))
check "timed-out fetch still creates worktree" is_path "$(toplevel "$SLOW")/.claude/worktrees/t9"
check "fetch bounded (${elapsed}s <= 14s)" [ "$elapsed" -le 14 ]
check "no leftover fetch helper" eval "! pgrep -f 'sleep $sleep_arg' >/dev/null"
check "no Terminated noise" eval '! contains "$ERR" Terminated'
check "warns about slow and unstarted remotes" \
    contains "$ERR" "fetch failed or timed out for: slow, upstream; using existing remote-tracking refs"

echo "── Fetch failure ──"
BROKEN="$SANDBOX/broken"
make_clone "$BROKEN"
git -C "$BROKEN" remote add broken "$SANDBOX/does-not-exist.git"
git -C "$BROKEN" update-ref refs/remotes/broken/ff HEAD
start=$SECONDS
run_hook "$BROKEN" quick
elapsed=$((SECONDS - start))
check "failed fetch still creates worktree" is_path "$(toplevel "$BROKEN")/.claude/worktrees/quick"
check "failed fetch is quick (${elapsed}s)" [ "$elapsed" -le 5 ]
check "warns about broken remote" contains "$ERR" "fetch failed or timed out for: broken;"
run_hook "$BROKEN" ff
check "stale remote ref still offered" contains "$ERR" "--track ff broken/ff"
check "ask includes fetch warning" contains "$ERR" "fetch failed or timed out for: broken;"

echo "── Invalid names ──"
for bad in -x HEAD 'a..b' '../escape' /abs 'a/.b'; do
    before=$(snapshot "$CLONE")
    run_hook "$CLONE" "$bad"
    after=$(snapshot "$CLONE")
    check "invalid name '$bad' fails" [ "$RC" -ne 0 ]
    check "invalid name '$bad' message" contains "$ERR" "'$bad' is not a valid branch name"
    check "invalid name '$bad' creates nothing" [ "$before" == "$after" -a ! -e /abs ]
done

echo "── Nested name ──"
run_hook "$CLONE" p
run_hook "$CLONE" p/x
check "nested name fails" [ "$RC" -ne 0 ]
check "nested name message" contains "$ERR" "'p/x' would be nested inside worktree '$WT/p'"

echo "── Submodule commit from branch ──"
SUBSRC="$SANDBOX/subsrc"
git init -q "$SUBSRC"
git_cfg "$SUBSRC"
commit "$SUBSRC" s.txt c1
c1=$(head_of "$SUBSRC")
commit "$SUBSRC" s.txt c2
c2=$(head_of "$SUBSRC")
SM="$SANDBOX/smrepo"
make_clone "$SM"
commit "$SM" .worktreeinclude sm
git -C "$SM" -c protocol.file.allow=always submodule add -q "$SUBSRC" sm
git -C "$SM/sm" checkout -q "$c1"
git -C "$SM" add sm
git -C "$SM" commit -qm "sm at c1"
git -C "$SM" checkout -q -b sm-branch
git -C "$SM/sm" checkout -q "$c2"
git -C "$SM" add sm
git -C "$SM" commit -qm "sm at c2"
git -C "$SM" checkout -q main
git -C "$SM/sm" checkout -q "$c1"
run_hook "$SM" sm-branch
smwt="$(toplevel "$SM")/.claude/worktrees/sm-branch"
check "submodule worktree created" is_path "$smwt"
check "submodule at branch commit c2" [ "$(head_of "$smwt/sm" 2>/dev/null)" == "$c2" ]
check "submodule worktree status clean" [ -z "$(git -C "$smwt" status --porcelain 2>&1)" ]

echo "── Copying into branch content ──"
CP="$SANDBOX/cprepo"
make_clone "$CP"
commit "$CP" .worktreeinclude $'conf.txt\ncfg/secret'
mkdir -p "$SANDBOX/outside-dir"
git -C "$CP" checkout -q -b cp-a
commit "$CP" conf.txt "branch"
git -C "$CP" checkout -q main
git -C "$CP" checkout -q -b cp-b
ln -s "$SANDBOX/outside-dir" "$CP/cfg"
git -C "$CP" add cfg
git -C "$CP" commit -qm "cfg symlink"
git -C "$CP" checkout -q main
git -C "$CP" checkout -q -b cp-c
commit "$CP" cfg "regular file"
git -C "$CP" checkout -q main
printf 'conf.txt\ncfg/\n' >> "$CP/.git/info/exclude"
echo "main" > "$CP/conf.txt"
mkdir -p "$CP/cfg"
echo "secret" > "$CP/cfg/secret"
CPWT="$(toplevel "$CP")/.claude/worktrees"

run_hook "$CP" cp-a
check "tracked file: worktree created" is_path "$CPWT/cp-a"
check "tracked file: branch content kept" [ "$(cat "$CPWT/cp-a/conf.txt")" == branch ]
check "tracked file: status clean" [ -z "$(git -C "$CPWT/cp-a" status --porcelain 2>&1)" ]

run_hook "$CP" cp-b
check "symlink dir: worktree created" is_path "$CPWT/cp-b"
check "symlink dir: nothing written outside" [ -z "$(ls -A "$SANDBOX/outside-dir")" ]

run_hook "$CP" cp-c
check "file parent: worktree created" is_path "$CPWT/cp-c"
check "file parent: file intact" [ "$(cat "$CPWT/cp-c/cfg")" == "regular file" ]
check "file parent: status clean" [ -z "$(git -C "$CPWT/cp-c" status --porcelain 2>&1)" ]
run_hook "$CP" cp-c
check "file parent: rerun reuses" contains "$ERR" "Reusing worktree cp-c on branch cp-c"

echo "── Copy rules come from the branch ──"
RB="$SANDBOX/rbrepo"
make_clone "$RB"
commit "$RB" .gitignore $'*.secret\nnr/\nnr2/'
commit "$RB" .worktreeinclude $'a.secret\nc.secret\nnr/\nnr2/'
git -C "$RB" checkout -q -b rules-branch
commit "$RB" .gitignore $'*.secret\n!c.secret\nplain.txt\nnr/\nnr2/'
commit "$RB" .worktreeinclude $'b.secret\nc.secret\nplain.txt\nnr/\nnr2/**'
git -C "$RB" checkout -q main
for f in a.secret b.secret c.secret plain.txt; do echo main > "$RB/$f"; done
for d in nr nr2; do
    git init -q "$RB/$d"
    echo x > "$RB/$d/file"
done
RBWT="$(toplevel "$RB")/.claude/worktrees"
run_hook "$RB" rules-branch
check "branch rules: worktree created" is_path "$RBWT/rules-branch"
check "branch rules: branch-only include copied" [ -f "$RBWT/rules-branch/b.secret" ]
check "branch rules: main-only include not copied" [ ! -e "$RBWT/rules-branch/a.secret" ]
check "branch rules: un-ignored on branch not copied" [ ! -e "$RBWT/rules-branch/c.secret" ]
check "branch rules: ignored only on branch copied" [ -f "$RBWT/rules-branch/plain.txt" ]
check "branch rules: dir pattern selects nested repo" [ -f "$RBWT/rules-branch/nr/file" ]
check "branch rules: 'd/**' does not select nested repo d" [ ! -e "$RBWT/rules-branch/nr2" ]

echo "── Files come from the current worktree ──"
git -C "$RB" worktree add -q -b linked-src "$SANDBOX/rb-linked" rules-branch
echo linked > "$SANDBOX/rb-linked/b.secret"
LINKED="$(toplevel "$SANDBOX/rb-linked")"
run_hook "$LINKED" from-linked
check "linked source: worktree created" is_path "$LINKED/.claude/worktrees/from-linked"
check "linked source: file from current worktree" [ "$(cat "$LINKED/.claude/worktrees/from-linked/b.secret" 2>/dev/null)" == linked ]

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -eq 0 ]]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
exit $((FAIL > 0 ? 1 : 0))
