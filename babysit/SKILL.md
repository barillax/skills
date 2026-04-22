---
name: babysit
description: One pass of PR babysitting for the current branch — gather status, aggressively autofix mechanical issues (rebase, lint/format, typecheck, build, tests), escalate judgment calls via AskUserQuestion, and cancel the wrapping /loop when the PR is fully green. Designed to be wrapped in /loop (e.g. `/loop 5m /babysit`); handles all recurrence itself. Pass `automerge` to invoke /merge once the PR is green.
argument-hint: [automerge]
---

Babysit the PR attached to the current branch for exactly one pass. Do not poll — the user wraps this skill in `/loop` (built-in) when they want recurrence. Your job is to make one full pass deterministic, idempotent, and safe.

## Arguments

Inspect `$ARGUMENTS` for the bare token `automerge` (case-sensitive). If present, set a mental flag `automerge=true` for use in **Phase 5**. No other arguments are recognized.

## How /loop integrates

The built-in `/loop` skill schedules the given prompt via `CronCreate` with `recurring: true` and executes the prompt immediately on the first call. Each subsequent cron fire runs the same prompt again in the same session. This means:

1. When `/babysit` is invoked from inside a loop, calling `CronList` will show a cron job whose `prompt` field contains `babysit`. Cancel it with `CronDelete <id>` to stop the loop.
2. When `/babysit` is invoked standalone, `CronList` will show no babysit job — just report completion and exit.

## Phase 0 — Preconditions

### PM detection (prerequisite)

Every shell-level step below uses `$PM` — the project's package manager. Resolve it once at the start of the pass:

```bash
PM=pnpm
[ -f yarn.lock ] && PM=yarn
[ -f bun.lockb ] && PM=bun
{ [ -f package-lock.json ] && [ ! -f pnpm-lock.yaml ]; } && PM=npm
export PM
```

Use `"$PM" run <script>` / `"$PM" exec <binary>` everywhere below. If a script isn't defined in `package.json`, skip that step — don't invent a different invocation.

Run the status script. Everything downstream reads from its output.

```bash
${CLAUDE_SKILL_DIR}/scripts/status.sh
```

Parse the JSON. If `pr_number` is `null` (error `no_pr_for_branch`), stop and tell the user there is no PR attached to the current branch. Do NOT attempt to create one.

Draft PRs are handled the same as ready PRs — the field `pr_draft` is informational only.

## Phase 1 — Understand the state

The JSON schema is:

- `branch`, `repo`, `pr_number`, `pr_url`, `pr_state`, `pr_draft`, `base_ref`
- `mergeable`: `MERGEABLE` | `CONFLICTING` | `UNKNOWN`
- `merge_state_status`: `CLEAN`, `BEHIND`, `DIRTY`, `BLOCKED`, etc.
- `review_decision`: `APPROVED` | `CHANGES_REQUESTED` | `REVIEW_REQUIRED` | `""`
- `checks[]`: every status check with `{name, status, conclusion, details_url, workflow}`
- `failing_checks[]`: subset where `conclusion ∈ {FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED}`
- `pending_checks[]`: subset where `status ∈ {QUEUED, IN_PROGRESS, PENDING, WAITING, REQUESTED}` (CI is still running — wait, don't declare victory)
- `unresolved_threads[]`: active review threads with `{id, path, line, author, body, url}`
- `all_green`: `true` iff mergeable, no failing checks, **no pending checks**, no unresolved threads, and review decision is not `CHANGES_REQUESTED`

If `all_green` is `true`, jump to **Phase 5**.

## Phase 2 — Classify

For each failing check, call the classifier:

```bash
${CLAUDE_SKILL_DIR}/scripts/classify-check.sh "<check name>"
```

It echoes `autofix` or `escalate`. Everything in `unresolved_threads` always escalates (threads carry human intent; don't guess at them). `review_decision == CHANGES_REQUESTED` always escalates. Merge conflicts enter the autofix path first — if the conflict turns out to be non-trivial, they escalate in Phase 3.

## Phase 3 — Autofix (aggressive, mechanical)

Run these steps in order. After each successful fix, re-run `status.sh` and re-classify before continuing — state can change between checks. Commit with conventional-commit messages (`fix(ci):`, `chore(ci):`, `fix(types):`, `fix(test):`, `refactor(chat):`, etc.). **Never use `--no-verify`**: the repo's git hooks (husky / lefthook / simple-git-hooks) enforce lint+typecheck on commit and the full suite on push. Run `"$PM" run lint:fix`, `"$PM" run format`, and `"$PM" run typecheck` yourself before committing so failures surface in-band rather than as hook rejections.

### 3a. Rebase on base

Only if `mergeable == CONFLICTING` or `merge_state_status == BEHIND`. Run:

```bash
${CLAUDE_SKILL_DIR}/scripts/rebase-main.sh "<base_ref>"
```

Parse `.result`:

- `ok` → `git push --force-with-lease` and continue.
- `conflict` → inspect `conflicted_files`. If every conflict is in a lockfile (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`) or a known generated directory (the project's `AGENTS.md` / `CLAUDE.md` lists these — e.g. `convex/_generated/*`, `worker-configuration.d.ts`, `drizzle/meta/*`, `uniwind-types.d.ts`, `*.gen.ts`) or is whitespace-only, re-run `git rebase origin/<base>` manually, resolve each file (regenerate lockfiles with `"$PM" install`; prefer main's side for generated files), `git rebase --continue`, then `git push --force-with-lease`. Any conflict touching real source code (non-generated `.ts`, `.tsx`, `.md`, `.yml`) **escalates** via Phase 4 with the list of conflicted files and a short summary of both sides.
- `dirty_worktree` → this is a bug in babysit's state; stop and report to the user.

### 3b. Lint + format

If any failing check is classified `autofix` and matches `lint`/`format`/`prettier`:

```bash
"$PM" run lint:fix
"$PM" run format
```

If `git status --porcelain` is non-empty, commit as `chore(ci): apply lint and format fixes` and `git push`.

### 3c. Typecheck

If a `typecheck` / `tsc` check is failing:

```bash
"$PM" run typecheck
```

Read the errors. If they are mechanical (missing import after a rename, outdated generated type, one wrong type annotation), fix them, commit as `fix(types): …`, and push. If the error reflects a real behavioral change or an ambiguous typing decision, **escalate**.

### 3d. Test repair (aggressive, capped at one attempt per test)

For each failing test check, download the failing output:

```bash
gh run view --log-failed <run-id-from-details_url>
```

Parse the failing test names. Determine the runner from the path convention in this repo:

- `__tests__/**`, `components/**/*.test.*`, `lib/**/*.test.*` → Jest (`npx jest -t "<name>"`)
- Vitest tests (backend / Workers / Node) → `"$PM" exec vitest run -t "<name>"`

Read the tested code and the test. Make a best-effort repair (the same way you'd repair a lint error — confidently, but read the code first). Re-run the test locally. If it passes, commit as `fix(test): …` (test was wrong) or `fix(<scope>): …` (code was wrong) depending on which side you changed, then push.

**Do not enter a grind loop.** If a single repair attempt still fails the test, or if the correct behavior is ambiguous, stop and **escalate that specific test** via Phase 4 — include the failing assertion, the file you looked at, and 2-3 candidate fixes.

### 3e. Build failures

If a `build` check is failing and the cause is mechanical (missing dep after a merge, stale generated file, resource path typo), fix and commit as `fix(build): …`. Otherwise escalate.

## Phase 4 — Escalate judgment calls

For every item in the escalate bucket, use `AskUserQuestion`. One question per item (or one batched question if they're genuinely the same decision). Each question must include:

- **Where** the problem is: check name + `details_url`, or thread `path:line` + `url`.
- **What** the problem is: a 1-3 sentence summary of the failure message or thread body. Do not paraphrase away the specifics.
- **Options**: 2-4 concrete choices, each describing a real action you would take (e.g. "Accept the suggestion and change `foo.ts:42` to use `bar()`", "Reply on the thread disagreeing because `bar()` loses type safety", "Skip this thread for now"). Never offer an "investigate more" option — if you need to investigate, do it _before_ asking.

Apply the user's answers sequentially. After each applied answer, re-run `status.sh` and re-classify. Never silently pick an option on the user's behalf, and never bundle multiple unrelated decisions into one question.

## Phase 5 — Completion and loop termination

Re-run `status.sh` one final time. If `all_green == true`:

1. Print a one-paragraph summary: PR number + URL, count of passing checks, review decision, "no unresolved threads".
2. Cancel the wrapping loop:
   - Call `CronList`.
   - Find any job whose `prompt` contains `babysit` (case-insensitive substring match). The built-in `/loop` skill puts the user's prompt into the `prompt` field verbatim — `/loop 5m /babysit` produces a job with `prompt: "/babysit"`. The `automerge` argument does not affect this match (`/babysit automerge` still contains `babysit`).
   - For each match, call `CronDelete` with its `id`.
   - If no match, print: "No wrapping loop detected (running standalone). Nothing to cancel."
3. **If `automerge` was set in the Arguments section**, invoke the `/merge` skill via the `Skill` tool (`skill: "merge"`, no args). `/merge` is fully self-contained — it re-verifies green status, squash-merges, and handles worktree cleanup. It is safe to call here because we just confirmed `all_green == true`. If `/merge` fails (e.g. branch protection unexpectedly blocks it), surface its output and stop — do not re-arm the loop, since the failure needs human attention.
4. Exit.

If `all_green == false`, print the remaining blockers (failing checks that need user input, unresolved threads, rebase conflicts that escalated) and exit. The wrapping `/loop` will call `/babysit` again at the next cron fire — _do not_ self-reschedule or sleep.

## Guarantees and non-goals

- **Idempotent**: running `/babysit` twice on the same state produces the same result. Nothing mutates external state unless a concrete fix was found.
- **Single pass**: never loops internally, never sleeps, never calls itself.
- **Never bypasses hooks**: no `--no-verify`, no skipping CI.
- **Merges only with `automerge`**: by default babysit only pushes fixes and leaves merging to the user. The opt-in `automerge` argument delegates the squash-merge to `/merge` once the PR is fully green.
- **Never creates a PR**: if there is no PR for the branch, stop.
