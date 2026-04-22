---
name: pr
description: Create a well-documented pull request from the current working state. Handles uncommitted changes, branch creation, quality checks with autofix, and PR description generation. Pass `automerge` to auto-invoke /merge once /babysit reports the PR fully green.
argument-hint: [--base <branch>] [automerge]
---

Create a pull request from the current working state. This skill handles everything from uncommitted changes on main to an already-committed feature branch.

## Phase 0 — Preflight

Inspect `$ARGUMENTS` for the bare token `automerge` (case-sensitive, may appear before or after `--base <branch>`). If present, set a mental flag `automerge=true` and remember it for **Phase 4**. You don't need to strip it before passing `$ARGUMENTS` to the preflight script — the script ignores unknown args.

Run the preflight script to detect the current git state:

```bash
"${CLAUDE_SKILL_DIR}/scripts/preflight.sh" $ARGUMENTS
```

Parse the JSON output. The `action_needed` field determines what to do next:

| `action_needed`            | Action                                                                          |
| -------------------------- | ------------------------------------------------------------------------------- |
| `create_branch_and_commit` | Go to Phase 1                                                                   |
| `commit`                   | Go to Phase 1                                                                   |
| `push`                     | Go to Phase 2                                                                   |
| `ready`                    | Go to Phase 2                                                                   |
| `already_has_pr`           | Print the existing PR URL from `existing_pr` and **stop**                       |
| `nothing_to_do`            | Tell the user there are no changes to create a PR for and **stop**              |
| `ask_user`                 | Use `AskUserQuestion` — there are commits on the default branch; ask what to do |

If `gh_authenticated` is `false`, stop and tell the user to run `gh auth login`.

## Phase 1 — Branch + Commit

Read the diff to understand the changes:

```bash
git diff && git diff --cached
```

Generate two things from the diff:

1. **Branch name** (only if `action_needed == create_branch_and_commit`): format `<type>/<short-kebab-description>` using conventional commit types (feat, fix, chore, refactor, docs, test, ci, perf).
2. **Commit message**: conventional commit format per `.claude/rules/commits.md`. Include `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>` footer.

Then commit via the script. **Always pass the commit message via `-F <file>`** — write the message to a file with the `Write` tool first, then reference it. Inline message strings break under nested shell eval whenever the message contains apostrophes, backticks, or `$`:

```bash
# 1. Write commit message to a file (use the Write tool, not heredoc)
#    Path convention: /tmp/pr-commit-msg.txt

# 2. Invoke the script with -F
"${CLAUDE_SKILL_DIR}/scripts/commit-changes.sh" [--branch <name>] -F /tmp/pr-commit-msg.txt
```

The script stages all tracked changes (skipping secret patterns like `.env*`, `*.key`, `*.pem`), creates the branch if `--branch` is provided, and commits. Parse the JSON output — if `committed` is `false`, report the `error` field verbatim (it contains the actual hook output) and stop.

## Phase 2 — Quick Checks + Autofix

Run the combined check-and-fix script:

```bash
"${CLAUDE_SKILL_DIR}/scripts/quickcheck-and-autofix.sh"
```

Parse the JSON output:

- If `passed` is `true`: continue to **Phase 3**. If `autofix_applied` is `true`, note that lint/format fixes were auto-committed.
- If `passed` is `false`: check `remaining_failures`.
  - If only `typecheck` failed: read the output. If errors are mechanical (missing import, wrong type annotation), fix them, commit as `fix(types): <description>`, and re-run `quickcheck-and-autofix.sh`. If errors are ambiguous or behavioral, use `AskUserQuestion` to escalate.
  - If lint/format still fail after autofix: report the issues and use `AskUserQuestion` to ask whether to proceed or stop.

**Important:** Never use `--no-verify` when committing fixes. Let husky hooks run.

## Phase 3 — Generate + Create PR

### 3a. Gather context

```bash
"${CLAUDE_SKILL_DIR}/scripts/prepare-pr-context.sh" "<base>"
```

Where `<base>` comes from the preflight JSON. Parse the JSON — it contains commits, diff stats, changed files, and a diff preview.

### 3b. Generate PR title

From the context, generate a conventional-commit-style title: `<type>(<scope>): <subject>`

This is critical — PR titles become the squash merge commit message on main (enforced by CI). Follow `.claude/rules/commits.md`:

- Keep under 70 characters
- No period at the end
- Use imperative mood

### 3c. Generate PR body

Write the PR body as a temp file. Include:

1. **Summary**: 2-4 bullet points explaining what changed and why
2. **Changes**: grouped list of meaningful changes with file paths
3. **Test Plan**: generate inline from the context. Map changed file paths to concrete test commands — infer the package manager (`$PM`) and the right turbo filter from the project's layout (`pnpm-workspace.yaml`, `turbo.json`, `package.json#workspaces`). General shape:
   - Source files under a workspace → `"$PM" exec turbo run test --filter=<package-name>`
   - Shared packages that everyone depends on → `"$PM" exec turbo run typecheck test`
   - Config/tooling changes → the project's full check command (typically `"$PM" run check` or `"$PM" exec turbo run typecheck lint test`)
   - Add any feature-specific manual test steps based on the actual changes
4. Watermark: `🤖 Generated with [Claude Code](https://claude.ai/claude-code)`

Write the body to `/tmp/pr-body.md` using the `Write` tool.

**Critical sequencing — do not get this wrong:**

- The `Write` call MUST complete successfully BEFORE you invoke `create-pr.sh` in section 3d. Never call them in parallel: if `Write` fails (e.g. because Claude's `Write` tool refuses to overwrite an existing file without a prior `Read`), `create-pr.sh` will silently use whatever stale content is on disk.
- If `/tmp/pr-body.md` already exists from a previous session, either `Read` it first (so `Write` can overwrite it) OR delete it with a `Bash` call to `rm -f /tmp/pr-body.md` before `Write`.
- After `Write` returns success, sanity-check it before invoking the script: confirm the tool's return message reports the file was written, and that it wasn't immediately followed by a stale-file warning from a hook.

`create-pr.sh` defends against this by rejecting body files that are empty or older than 5 minutes (mtime), but those guards are a safety net — the right pattern is to write fresh content every time.

### 3d. Push + Create PR

```bash
"${CLAUDE_SKILL_DIR}/scripts/create-pr.sh" --title "<title>" --body-file /tmp/pr-body.md --base "<base>"
```

Parse the JSON output. Print the PR URL.

If `create-pr.sh` rejects the body with a `stale` or `empty` error, that means step 3c above was skipped or failed silently. Re-write the body file (deleting it first if needed), then re-invoke the script. Do not retry without a fresh write — the stale file is still on disk.

## Phase 4 — Hand Off to Babysit

After PR creation, invoke `/loop 1m /babysit` to monitor CI and autofix mechanical failures.

**If `automerge` was set in Phase 0**, append it to the babysit invocation so the loop will auto-invoke `/merge` once the PR is green:

```
/loop 1m /babysit automerge
```

Use the `Skill` tool with `skill: "loop"` and `args: "1m /babysit automerge"`.

Tell the user:

> PR created at `<url>`. Monitoring CI via /babysit with automerge — I'll autofix mechanical failures, ask about anything that needs judgment, and squash-merge the PR once everything is green.

**Otherwise** (no automerge), invoke without the flag:

```
/loop 1m /babysit
```

Use the `Skill` tool with `skill: "loop"` and `args: "1m /babysit"`.

Tell the user:

> PR created at `<url>`. Monitoring CI via /babysit — I'll autofix mechanical failures and ask you about anything that needs judgment.
