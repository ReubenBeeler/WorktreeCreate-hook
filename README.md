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

## Running tests

```bash
bash run-tests.sh
```

This sets up all test fixtures (gitignored files, submodule upstreams, nested repos) and runs both suites: `test-worktree-hook.sh` (file copying, submodules) and `test-branch-selection.sh` (branch selection, fetch bounds, name validation; offline sandbox). Works on a fresh clone — no manual setup needed.
