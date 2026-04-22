---
name: merge
description: Merge the current branch's PR (squash) after verifying CI is green, then clean up locally. Fails fast with clear blockers if not ready. Works in worktrees.
---

Run the merge pipeline. Almost everything is handled by the scripts — you only need to intervene for worktree cleanup.

```bash
"${CLAUDE_SKILL_DIR}/scripts/preflight.sh" | "${CLAUDE_SKILL_DIR}/scripts/do-merge.sh"
```

Capture both stdout and the exit code.

**Exit 0** — merge and cleanup complete. Print the script output and stop.

**Exit 1** — blocked or failed. Print the script output and stop. Do not retry or attempt fixes.

**Exit 2** — merge succeeded but we're in a worktree. The script already printed the merge confirmation. Now handle worktree cleanup:

1. Call `ExitWorktree` with `action: "remove"`.
2. If ExitWorktree succeeds (session returns to main checkout), invoke `/git-cleanup --delete` and print the summary.
3. If ExitWorktree reports no active worktree session (agent-spawned or manual worktree), print: "Run `/git-cleanup` from the main checkout to clean up branches."
