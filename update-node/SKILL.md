---
name: update-node
description: Update the project's Node.js version across all config files (`.nvmrc`, `.mise.toml` / `mise.toml`, root + per-workspace `package.json#engines`, CI) and verify compatibility.
disable-model-invocation: true
argument-hint: <version>
---

# Update Node.js Version

Update the pinned Node.js version across all config files in this project. Target version: `$ARGUMENTS`.

## Files to update (survey first — don't assume)

1. Find all config files that pin a Node version. Run:
   ```bash
   find . -maxdepth 6 -type f \( -name .nvmrc -o -name .mise.toml -o -name mise.toml -o -name package.json -o -name "*.yml" -path "*.github/*" -o -name "*.yaml" -path "*.github/*" \) -not -path "./node_modules/*" -not -path "./.turbo/*" 2>/dev/null
   ```
2. From that list, the ones to edit are:
   - **`.nvmrc`** — exact version (e.g. `22.16.0`). Used by GitHub Actions `setup-node`.
   - **`.mise.toml` / `mise.toml`** — exact version under `[tools]`. Used by mise for local dev.
   - **Every `package.json`** in the repo (root + workspaces) that has an `engines.node` field — update the range (e.g. `>=22.13.0 <23.0.0`).
   - **GitHub Actions workflows** under `.github/workflows/*.yml` — any `node-version:` keys that pin a major/minor (skip ones that read from `.nvmrc`).

## Steps

1. **Validate the target version** — confirm it is an even-numbered LTS release (not odd/Current). Warn if it is not LTS.
2. **Check dependency compatibility** — inspect each workspace's key runtime deps and verify they support the target Node. Use web search for recent changelogs as needed.
3. **Update all files** identified in the survey. For `engines.node`, use `>=<major>.<minimum-minor>.0 <<major+1>.0.0` where `<minimum-minor>` is the lowest minor all deps support. Keep ranges consistent across workspaces.
4. **Install dependencies** — detect the package manager from the lockfile:
   ```bash
   PM=pnpm; [ -f yarn.lock ] && PM=yarn; [ -f bun.lockb ] && PM=bun; { [ -f package-lock.json ] && [ ! -f pnpm-lock.yaml ]; } && PM=npm
   case "$PM" in
     pnpm) pnpm install --frozen-lockfile ;;
     yarn) yarn install --immutable ;;
     bun)  bun install --frozen-lockfile ;;
     npm)  npm ci ;;
   esac
   ```
   Peer-dep warnings are acceptable; hard errors are not.
5. **Run full checks**:
   ```bash
   # Prefer a `check` script if defined; otherwise run typecheck + lint + test.
   if jq -e '.scripts.check' package.json >/dev/null 2>&1; then
     "$PM" run check
   elif [ -f turbo.json ] || [ -f turbo.jsonc ]; then
     "$PM" exec turbo run typecheck lint test
   else
     "$PM" run typecheck && "$PM" run lint && "$PM" run test
   fi
   ```
6. **Report** — summarize: files changed, any warnings, whether all checks passed.

## Important

- Do NOT push or commit — just make the file changes and verify. The user will review before committing.
- If any dependency does not support the target Node version, stop and report the incompatibility before making changes.
- Keep all `engines.node` ranges in the monorepo consistent unless a workspace has a documented exception.
