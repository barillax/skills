# barillax/skills

Personal Claude Code skills, published in the `npx skills` layout.

## Install

```bash
npx skills@latest add barillax/skills                      # install the whole bundle
npx skills@latest add barillax/skills/pr                   # install one skill
npx skills@latest update barillax/skills                   # pull the latest
npx skills@latest remove <skill>                           # uninstall
```

Skills land in `~/.claude/skills/<skill>/`.

## What's here

| Skill | Description |
|---|---|
| [`pr`](./pr) | Create a well-documented PR from the current working state. Handles uncommitted changes, quickcheck autofix, PR body generation. |
| [`merge`](./merge) | Squash-merge the current branch's PR after verifying CI is green, then clean up locally. Worktree-aware. |
| [`babysit`](./babysit) | One pass of PR babysitting — gather status, aggressively autofix (rebase, lint, typecheck, build, tests), escalate judgment calls. Wrap in `/loop` for recurring passes. |
| [`git-cleanup`](./git-cleanup) | Delete local branches whose remote tracking branch is gone. Safe: previews before deleting. |
| [`update-node`](./update-node) | Bump the pinned Node version across `.nvmrc`, `.mise.toml`, `package.json#engines`, CI configs, and verify compatibility. |
| [`review`](./review) | Run the project's full quality check + summarize the current diff. |
| [`test-plan`](./test-plan) | Generate a testing plan for the current branch's changes. |
| [`weekly-recap`](./weekly-recap) | Draft a Slack-ready weekly recap for exec leadership from your GitHub org activity, Claude Code sessions, Calendar, and Gmail. Interactive sensitivity + clarification pass. |

All skills are package-manager-agnostic — they detect `pnpm` / `yarn` / `bun` / `npm` from the project's lockfile and `packageManager` field via `_shared/detect-pm.sh`.

## Credits

Adapted from [@farthershore/mobile-agent-chat-template](https://github.com/farthershore/mobile-agent-chat-template), extracted into a standalone collection and made package-manager-agnostic.
