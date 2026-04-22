---
name: review
description: Run full quality checks and review the current diff. Auto-detects package manager (pnpm/yarn/bun/npm) from the project's lockfile and invokes the project's `check` script (or `turbo run typecheck lint test` if a `turbo.json` is present and there's no `check` script).
context: fork
---

Review current changes by running all quality checks and analyzing the diff:

1. Show the current diff:

```bash
git diff
```

2. Run the full check suite. Detect the project's package manager first:

```bash
# Detect pnpm / yarn / bun / npm from the project lockfile and packageManager field.
PM=pnpm
[ -f yarn.lock ] && PM=yarn
[ -f bun.lockb ] && PM=bun
[ -f package-lock.json ] && [ ! -f pnpm-lock.yaml ] && PM=npm
# Prefer an explicit project `check` script if one exists, else fall back to turbo.
if jq -e '.scripts.check' package.json >/dev/null 2>&1; then
  "$PM" run check
elif [ -f turbo.json ] || [ -f turbo.jsonc ]; then
  "$PM" exec turbo run typecheck lint test
else
  "$PM" run typecheck || true
  "$PM" run lint      || true
  "$PM" run test      || true
fi
```

3. Review the changes for:
   - Correctness and potential bugs
   - Type safety
   - Adherence to project conventions (as stated in CLAUDE.md / AGENTS.md)
   - Security concerns (no secrets, no injection vectors)
   - Test coverage for new functionality

Provide a concise review summary with any issues found.
