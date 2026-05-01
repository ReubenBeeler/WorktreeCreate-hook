# WorktreeCreate Hook with `.worktreeinclude`

A Claude Code `WorktreeCreate` hook that selectively copies gitignored files into new worktrees using `.worktreeinclude` pattern files.

## How it works

When Claude Code creates a worktree, the hook (`.claude/hooks/worktree-create.sh`) copies files that are **both** gitignored **and** matched by `.worktreeinclude` patterns into the new worktree. This lets you bring secrets, build caches, and other gitignored files into isolated worktrees automatically.

`.worktreeinclude` uses gitignore syntax — patterns include files, `!` negates. Nested `.worktreeinclude` files scope rules to their directory, just like `.gitignore`. Submodules listed in `.worktreeinclude` are selectively initialized.

## Running tests

```bash
bash run-tests.sh
```

This sets up all test fixtures (gitignored files, submodule upstreams, nested repos) and runs the test suite. Works on a fresh clone — no manual setup needed.
