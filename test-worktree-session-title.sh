#!/usr/bin/env bash
# Tests worktree-session-title.sh against a throwaway sandbox repo (under
# mktemp -d); never touches this repo's branches or worktrees.
# Requires git 2.32+ (GIT_CONFIG_GLOBAL) and jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/.claude/hooks/worktree-session-title.sh"
SH="${BASH:-bash}"
REAL_GIT="$(command -v git)"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

SB="$(mktemp -d "${TMPDIR:-/tmp}/wt-title-test.XXXXXX")"
SB="$(cd "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT

q() { "$@" >/dev/null 2>&1; }

MAIN="$SB/main"
WTS="$MAIN/.claude/worktrees"
q git init -q -b main "$SB/src-alpha"
echo alpha > "$SB/src-alpha/README.md"
q git -C "$SB/src-alpha" add README.md
q git -C "$SB/src-alpha" commit -qm init
q git clone -q --bare "$SB/src-alpha" "$SB/alpha.git"
q git init -q -b main "$MAIN"
printf '.claude/worktrees/\n' > "$MAIN/.gitignore"
mkdir -p "$MAIN/sub"
echo f > "$MAIN/sub/f.txt"
q git -C "$MAIN" add -A
q git -C "$MAIN" commit -qm init
q git -C "$MAIN" submodule add -q "$SB/alpha.git" submodules/alpha
q git -C "$MAIN" commit -qm alpha

q git -C "$MAIN" worktree add -q --detach "$WTS/t1" HEAD
q git -C "$MAIN" worktree add -q --detach "$WTS/feature/auth" HEAD
q git -C "$WTS/t1" worktree add -q --detach "$WTS/t1/.claude/worktrees/agent-a1b2c3d" HEAD
q git -C "$MAIN/.git/modules/submodules/alpha" worktree add -q --detach \
    "$WTS/t1/submodules/alpha" "$(git -C "$MAIN" rev-parse HEAD:submodules/alpha)"
if [[ ! -f $WTS/t1/submodules/alpha/README.md || ! -d $WTS/t1/.claude/worktrees/agent-a1b2c3d ]]; then
    echo "FAIL  sandbox setup"
    exit 1
fi

PASS=0
FAIL=0

# run <json> [PATH]: run the hook; sets RC.
run() {
    if [[ -n ${2:-} ]]; then
        printf '%s' "$1" | PATH="$2" "$SH" "$HOOK" >"$SB/out" 2>"$SB/err"
    else
        printf '%s' "$1" | "$SH" "$HOOK" >"$SB/out" 2>"$SB/err"
    fi
    RC=$?
}

input() { # event cwd [source] [session_title]
    jq -cn --arg e "$1" --arg c "$2" --arg s "${3:-}" --arg t "${4:-}" \
        '{session_id:"t",transcript_path:"/dev/null",hook_event_name:$e,cwd:$c}
         + (if $s == "" then {} else {source:$s} end)
         + (if $t == "" then {} else {session_title:$t} end)'
}

# expect <desc> <event> <title>: exit 0, no stderr, stdout empty or exactly
# the title JSON.
expect() {
    local why="" want got
    [[ $RC -eq 0 ]] || why+="rc=$RC; "
    [[ ! -s $SB/err ]] || why+="stderr: $(head -n 1 "$SB/err"); "
    if [[ -z $3 ]]; then
        [[ ! -s $SB/out ]] || why+="stdout: $(head -c 200 "$SB/out"); "
    else
        want=$(jq -cn --arg e "$2" --arg t "$3" '{hookSpecificOutput:{hookEventName:$e,sessionTitle:$t}}')
        got=$(cat "$SB/out")
        [[ $got == "$want" ]] || why+="stdout: $got; "
    fi
    if [[ -z $why ]]; then
        printf "PASS  %s\n" "$1"
        PASS=$((PASS + 1))
    else
        printf "FAIL  %s  (%s)\n" "$1" "$why"
        FAIL=$((FAIL + 1))
    fi
}

echo "─────────────────────────────────────────────────────────────────────────"
echo "TITLED"
echo "─────────────────────────────────────────────────────────────────────────"
for src in startup resume fork; do
    run "$(input SessionStart "$WTS/t1" "$src")"
    expect "SessionStart $src at worktree root" SessionStart t1
done
run "$(input SessionStart "$WTS/t1/sub" startup)"
expect "SessionStart in subdir" SessionStart t1
run "$(input SessionStart "$WTS/feature/auth" startup)"
expect "SessionStart slash name" SessionStart feature/auth
run "$(input SessionStart "$WTS/t1/.claude/worktrees/agent-a1b2c3d" startup)"
expect "SessionStart nested worktree" SessionStart agent-a1b2c3d
if [[ $SB == /private/* && -d ${SB#/private} ]]; then
    run "$(input SessionStart "${SB#/private}/main/.claude/worktrees/t1" startup)"
    expect "SessionStart non-physical cwd" SessionStart t1
fi
run "$(input UserPromptSubmit "$WTS/t1")"
expect "UserPromptSubmit at worktree root" UserPromptSubmit t1
run "$(input UserPromptSubmit "$WTS/t1/sub")"
expect "UserPromptSubmit in subdir" UserPromptSubmit t1
run "$(input UserPromptSubmit "$WTS/feature/auth")"
expect "UserPromptSubmit slash name" UserPromptSubmit feature/auth

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "NOT TITLED"
echo "─────────────────────────────────────────────────────────────────────────"
run "$(input SessionStart "$WTS/t1" startup "my name")"
expect "SessionStart with session_title" SessionStart ""
run "$(input UserPromptSubmit "$WTS/t1" "" "my name")"
expect "UserPromptSubmit with session_title" UserPromptSubmit ""
for src in clear compact; do
    run "$(input SessionStart "$WTS/t1" "$src")"
    expect "SessionStart $src" SessionStart ""
done
run "$(input SessionStart "$MAIN" startup)"
expect "main checkout" SessionStart ""
run "$(input UserPromptSubmit "$MAIN/sub")"
expect "main checkout subdir (UserPromptSubmit)" UserPromptSubmit ""
mkdir -p "$SB/plain"
run "$(input SessionStart "$SB/plain" startup)"
expect "non-git cwd" SessionStart ""
run "$(input SessionStart "$SB/nope" startup)"
expect "nonexistent cwd" SessionStart ""
run "$(input SessionStart "$WTS/t1/submodules/alpha" startup)"
expect "cwd in submodule" SessionStart ""
mkdir -p "$WTS/loose"
run "$(input SessionStart "$WTS/loose" startup)"
expect "unregistered dir under .claude/worktrees" SessionStart ""
run "$(input Stop "$WTS/t1")"
expect "other event" Stop ""

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "FAILURES (silent, exit 0)"
echo "─────────────────────────────────────────────────────────────────────────"
run '{"hook_event_name": "SessionStart", '
expect "malformed JSON" SessionStart ""
run ''
expect "empty stdin" SessionStart ""
run '"SessionStart"'
expect "non-object JSON" SessionStart ""

mkdir -p "$SB/stub-jq" "$SB/stub-git" "$SB/junk-git" "$SB/junk-fail-git" "$SB/nojq"
printf '#!/bin/sh\necho junk; echo junk >&2; exit 3\n' > "$SB/stub-jq/jq"
printf '#!/bin/sh\nexit 1\n' > "$SB/stub-git/git"
printf '#!/bin/sh\necho junk; echo junk >&2\nexec "%s" "$@"\n' "$REAL_GIT" > "$SB/junk-git/git"
printf '#!/bin/sh\necho junk; echo junk >&2; exit 1\n' > "$SB/junk-fail-git/git"
chmod +x "$SB"/stub-jq/jq "$SB"/stub-git/git "$SB"/junk-git/git "$SB"/junk-fail-git/git
for b in git cat; do ln -s "$(command -v "$b")" "$SB/nojq/$b"; done

IN=$(input SessionStart "$WTS/t1" startup)
run "$IN" "$SB/stub-jq:$PATH"
expect "jq fails" SessionStart ""
run "$IN" "$SB/stub-git:$PATH"
expect "git fails" SessionStart ""
run "$IN" "$SB/junk-fail-git:$PATH"
expect "git prints junk and fails" SessionStart ""
run "$IN" "$SB/nojq"
expect "jq missing" SessionStart ""
run "$IN" "$SB/junk-git:$PATH"
if [[ -s $SB/out ]]; then
    expect "git prints junk (stdout is only JSON)" SessionStart t1
else
    expect "git prints junk (stdout is only JSON)" SessionStart ""
fi

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────────────────────────────────────"
exit $((FAIL > 0 ? 1 : 0))
