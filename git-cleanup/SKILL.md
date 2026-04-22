---
name: git-cleanup
description: Clean up local git branches whose remote tracking branch has been deleted. Safe by default — previews classification (merged, squash-merged, unmerged) before deleting.
---

Clean up stale local branches after PRs are merged, squash-merged, or closed.

1. Preview branches that would be deleted. Each branch is labeled `[merged]`, `[squash-merged]`, or `[unmerged]` so you can spot anything unexpected:

```bash
"${CLAUDE_SKILL_DIR}/scripts/cleanup.sh"
```

2. If the list looks right and the user confirms, delete them:

```bash
"${CLAUDE_SKILL_DIR}/scripts/cleanup.sh" --delete
```

`--delete` removes every gone branch — merged, squash-merged, and closed-unmerged alike — because a deleted upstream already signals intent. If any `[unmerged]` branches are present, the command prints a warning before deleting so the user can abort.

Always preview first. If the user sees an `[unmerged]` entry they want to keep, they should `git switch <branch>` or cherry-pick it somewhere before re-running `--delete`.

## Notes

- Runs from any worktree (operates on the main checkout's branch list).
- Requires: `git` + `gh` (squash-merge detection uses `gh pr list`).
- No dependency on project tooling — works in any repo.
