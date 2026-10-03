# WorktreeCreate Hook with `.worktreeinclude`

[![CI](https://github.com/ReubenBeeler/WorktreeCreate-hook/actions/workflows/ci.yaml/badge.svg)](https://github.com/ReubenBeeler/WorktreeCreate-hook/actions/workflows/ci.yaml)

A Claude Code `WorktreeCreate` hook that selectively copies gitignored files into new worktrees using `.worktreeinclude` pattern files.

## How it works

When Claude Code creates a worktree, the hook (`.claude/hooks/worktree-create.sh`) copies untracked files from the current worktree that are **both** gitignored **and** matched by `.worktreeinclude` patterns into the new worktree. Both rule sets (`.gitignore` and `.worktreeinclude`) come from the new worktree's branch. This lets you bring secrets, build caches, and other gitignored files into isolated worktrees automatically.

`.worktreeinclude` uses gitignore syntax — patterns include files, `!` negates. Nested `.worktreeinclude` files scope rules to their directory, just like `.gitignore`. Submodules listed in `.worktreeinclude` are selectively initialized.

## Branch selection

The worktree for name `<name>` lives at `.claude/worktrees/<name>` on branch `<name>`:

1. **Worktree exists** — reused as-is, on whatever branch it has.
2. **Local branch exists** — checked out in a new worktree (fails if another worktree already has it).
3. **Branch exists only on a remote** — nothing is created; the hook prints ready-to-run `git branch` commands (current HEAD or each remote's branch). Run one, then retry.
4. **No branch anywhere** — new branch from the current HEAD.

Before cases 3 and 4 the hook fetches each remote without prompting, capped at 10s in total; on failure or timeout it warns and uses the existing remote-tracking refs.

Limitations: fetch does not prune, so a branch deleted upstream may still be offered; single-branch or custom-refspec clones never get `refs/remotes/<remote>/<name>` and fall through to case 4.

## Removing worktrees

Two more hooks make removal safe:

- **`worktree-session-title.sh`** (SessionStart + UserPromptSubmit) titles every session running in `.claude/worktrees/<name>` after the worktree, e.g. `feature/auth` (slashes kept). A titled session always gets Claude Code's Keep/Remove prompt on exit, so a clean worktree is never removed without asking. It never overwrites an existing title (`--name`, `/rename`). Side effect: worktree sessions show the worktree name instead of an AI-generated title; this includes sessions you start manually inside `.claude/worktrees/<name>`.
- **`worktree-remove.sh`** (WorktreeRemove) removes the worktree only if nothing would be lost; otherwise it keeps it and Claude Code reports the worktree as kept. Kept when the worktree or any initialized submodule (recursively) has modified, staged or untracked files, a merge/rebase/etc. in progress, or commits no surviving repo can reach (a detached HEAD, or submodule commits whose repo is deleted with the worktree); also when it is locked or contains other worktrees. Gitignored files don't count. Branches are always kept.

Clean worktrees can still be removed without the prompt when the session has no custom title: the title hook failed or timed out (e.g. `jq` missing), you exited before SessionStart hooks finished, Claude entered the worktree with EnterWorktree and the session ended before your next prompt, agent-team teammate sessions (which ignore hook titles), or a rare title collision. Also unprompted: a subagent with `isolation: "worktree"` finishing, deleting a background session, and Claude choosing to remove the worktree via `ExitWorktree`. `claude -p --worktree` never cleans up. In every case the remove hook still keeps anything dirty.

> **Warning:** deleting a background session a second time (agent view Ctrl+X twice) or `claude rm --force-remove-worktree` bypasses the hook; untracked files are lost.

## Running tests

```bash
bash run-tests.sh
```

This sets up all test fixtures (gitignored files, submodule upstreams, nested repos) and runs every suite: the create hook against this repo (file copying, submodules), branch selection (fetch bounds, name validation; offline sandbox), and the remove and session-title hooks against throwaway sandbox repos. Works on a fresh clone — no manual setup needed.
