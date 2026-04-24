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

The goal of exit-2 cleanup is always the same: **switch back to the main checkout, fast-forward local main to the merged commit, remove the feature worktree + branch, then run `/git-cleanup`.** Pick the first path below that applies to the current environment.

> **Heads-up — foreground Bash gets stuck after worktree removal.** Once `wt remove` (or `git worktree remove`) deletes the feature worktree, the Bash tool's persistent shell has its internal cwd pinned to that now-missing path, and every subsequent *foreground* Bash call errors with `Path "<feature-worktree-path>" does not exist`. The `/git-cleanup` step described at the end of each path must therefore be invoked with `run_in_background: true` (background mode spawns a fresh subshell and bypasses the stale-cwd state). See the "Final step" section below.

### Path A — worktrunk (`wt remove`, primary path)

Use this when the JSON's `has_worktrunk` is `true`. `wt` owns the worktree lifecycle in this project, so it's the only path that runs the `.config/wt.toml` post-remove hooks and cleanly handles the squash-merged branch.

Run this as a single Bash call — substitute `<main_worktree_path>` and `<branch>` from the JSON:

```bash
cd "<main_worktree_path>" \
  && git fetch origin \
  && if [[ "$(git symbolic-ref --short HEAD 2>/dev/null)" == "main" ]]; then \
       git merge --ff-only origin/main; \
     else \
       git fetch origin main:main; \
     fi \
  && wt remove "<branch>" --force --yes
```

This switches the Bash session's cwd to the main checkout, fast-forwards **the local `main` ref** to the newly-merged commit, and removes the old worktree + local feature branch (worktrunk detects the squash-merge and deletes the branch since it's safe).

The `if/else` is important: the main worktree may currently have *any* branch checked out (a hotfix, another worktree's base), not necessarily `main`. A plain `git pull --ff-only` would pull whatever branch happens to be there and leave local `main` stale, which then breaks future `wt switch --create` branches that expect a fresh `main` baseline. The branch-aware fetch updates `refs/heads/main` correctly either way.

Then proceed to the "Final step" section below.

### Path B — Claude Code isolation without worktrunk

Use this when `has_worktrunk` is `false` **and** the current session was launched with Claude Code `isolation: "worktree"` (i.e. the worktree was created via `EnterWorktree`).

Call `ExitWorktree` with `action: "remove"`. If it reports that no worktree session is active, skip to Path C. On success, it returns the session to the pre-worktree cwd and removes the worktree + branch.

Then proceed to the "Final step" section below.

### Path C — raw git fallback

Use this when neither `wt` nor an active `EnterWorktree` session is available.

```bash
cd "<main_worktree_path>" \
  && git fetch origin \
  && if [[ "$(git symbolic-ref --short HEAD 2>/dev/null)" == "main" ]]; then \
       git merge --ff-only origin/main; \
     else \
       git fetch origin main:main; \
     fi \
  && git worktree remove --force "<current_worktree_path>" \
  && git branch -D "<branch>"
```

Same rationale as Path A for the `if/else` — don't assume the main worktree is checked out on `main`.

Then proceed to the "Final step" section below.

### Final step — `/git-cleanup` via background Bash

In every path above, once the feature worktree has been removed the foreground Bash shell is pinned to the now-missing path. Invoke `cleanup.sh` directly via `Bash` with `run_in_background: true` — **not** through the `Skill` tool, whose script invocation can get caught by the same stale-cwd error:

```bash
${HOME}/.claude/skills/git-cleanup/scripts/cleanup.sh --delete
```

Read the output file once the background task completes, surface its result to the user, and print a concise summary: which PR merged, that the old worktree is removed, and that local `main` is up to date.
