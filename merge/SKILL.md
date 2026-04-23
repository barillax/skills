---
name: merge
description: Merge the current branch's PR (squash) after verifying CI is green, then clean up locally. Fails fast with clear blockers if not ready. Works in worktrees — uses worktrunk (`wt`) when available to switch to the main checkout and remove the feature worktree automatically.
---

Run the merge pipeline. Almost everything is handled by the scripts — you only need to intervene for worktree cleanup.

```bash
"${CLAUDE_SKILL_DIR}/scripts/preflight.sh" | "${CLAUDE_SKILL_DIR}/scripts/do-merge.sh"
```

Capture both stdout and the exit code.

**Exit 0** — merge and cleanup complete. Print the script output and stop.

**Exit 1** — blocked or failed. Print the script output and stop. Do not retry or attempt fixes.

**Exit 2** — merge succeeded but we're in a worktree that is not the main checkout, so local cleanup has to be done by the caller. The script's last line of stdout is a single-line JSON blob with the context you need: `branch`, `default_branch`, `main_worktree_path`, `current_worktree_path`, `has_worktrunk`, `pr_number`.

Handle exit 2 in this order:

1. **Try `ExitWorktree` first** (action: `"remove"`). This works when the current session was started with Claude Code `isolation: "worktree"`. If it succeeds, the session returns to the main checkout — then invoke `/git-cleanup --delete` and stop.

2. **If `ExitWorktree` reports no active worktree session** (i.e. a manually-created or worktrunk-managed worktree), and the JSON's `has_worktrunk` is `true`, run this command block in a single Bash call. Substitute `<main>`, `<branch>`, and `<current>` from the JSON:

   ```bash
   cd "<main_worktree_path>" \
     && git pull --ff-only \
     && wt remove "<branch>" --force --yes
   ```

   This switches the Bash session's cwd to the main checkout, fast-forwards main to the newly-merged commit, and removes the old worktree + local branch (worktrunk detects the squash-merge and deletes the branch since it's safe). Then invoke `/git-cleanup --delete` and stop.

3. **If `has_worktrunk` is `false`** (no worktrunk installed), run instead:

   ```bash
   cd "<main_worktree_path>" \
     && git pull --ff-only \
     && git worktree remove --force "<current_worktree_path>" \
     && git branch -D "<branch>"
   ```

   Then invoke `/git-cleanup --delete` and stop.

In all exit-2 paths, after `/git-cleanup` completes, print a concise summary: which PR merged, that the old worktree is removed, and that main is up to date.
