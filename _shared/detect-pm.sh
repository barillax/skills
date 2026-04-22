#!/usr/bin/env bash
# Print the project's package manager: pnpm|yarn|bun|npm
# Resolution order:
#   1. lockfile present at repo root → pnpm-lock.yaml | yarn.lock | bun.lockb
#   2. "packageManager" field in package.json
#   3. default: npm
set -euo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

if [[ -f "$root/pnpm-lock.yaml" ]]; then echo pnpm; exit 0; fi
if [[ -f "$root/yarn.lock"      ]]; then echo yarn; exit 0; fi
if [[ -f "$root/bun.lockb"      ]]; then echo bun;  exit 0; fi

pm=""
if command -v jq >/dev/null 2>&1 && [[ -f "$root/package.json" ]]; then
  pm=$(jq -r '.packageManager // empty' "$root/package.json" 2>/dev/null | sed 's/@.*//')
fi
if [[ -n "$pm" ]]; then
  echo "$pm"
  exit 0
fi

echo npm
