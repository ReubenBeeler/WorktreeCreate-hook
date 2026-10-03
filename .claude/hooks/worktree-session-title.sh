#!/usr/bin/env bash
# SessionStart / UserPromptSubmit hook for Claude Code.
#
# Titles a session running in a worktree under <repo>/.claude/worktrees/
# after the worktree (e.g. "feature/auth"). A titled session always gets
# Claude Code's Keep/Remove prompt on exit, so clean worktrees are never
# removed without asking. Never overwrites an existing custom title
# (--name, /rename, an earlier hook title).
#
# Input:  JSON on stdin (fields: hook_event_name, cwd, source, session_title)
# Output: nothing, or exactly one JSON object:
#         {"hookSpecificOutput":{"hookEventName":"<event>","sessionTitle":"<name>"}}
# Exit:   always 0; any failure (missing jq/git, bad input) prints nothing.
#
# Requirements: bash 3.2+, git 2.26+, jq.

exec 3>&1 >/dev/null 2>&1
trap 'exit 0' EXIT
set -euo pipefail

command -v jq && command -v git || exit 0

input=$(cat)
vars=$(printf '%s' "$input" | jq -r '
    if type != "object" then error("not an object") else . end
    | @sh "ev=\(.hook_event_name // "") cwd=\(.cwd // "") title=\(.session_title // "") src=\(.source // "")"')
eval "$vars"

[[ -z $title ]] || exit 0
case $ev in
    SessionStart) case $src in startup | resume | fork) ;; *) exit 0 ;; esac ;;
    UserPromptSubmit) ;;
    *) exit 0 ;;
esac

# phys <dir> [base]: physical absolute path, resolving relative to base.
phys() {
    local p=$1
    [[ $p == /* ]] || p=$2/$p
    (cd "$p" && pwd -P)
}

[[ $cwd == /* && -d $cwd ]] || exit 0
out=$(git -C "$cwd" rev-parse --show-toplevel --git-dir --git-common-dir)
{ IFS= read -r top; IFS= read -r gd; IFS= read -r common; } <<<"$out"
top=$(phys "$top" "$cwd")
gd=$(phys "$gd" "$cwd")
common=$(phys "$common" "$cwd")

[[ $gd != "$common" && ${common##*/} == .git ]] || exit 0
super=${common%/.git}
[[ $top == "$super/.claude/worktrees/"?* ]] || exit 0

name=${top##*/.claude/worktrees/}
[[ -n $name ]] || exit 0
json=$(jq -cn --arg e "$ev" --arg t "$name" \
    '{hookSpecificOutput: {hookEventName: $e, sessionTitle: $t}}')
printf '%s\n' "$json" >&3
