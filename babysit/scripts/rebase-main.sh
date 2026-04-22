#!/usr/bin/env bash
# Attempt to rebase the current branch onto origin/<base>. If the rebase
# succeeds, leave the working tree on the new HEAD and report success. If it
# conflicts, emit a structured report of the conflicted files and abort the
# rebase so the caller starts from a clean tree.
#
# Usage: rebase-main.sh [base-branch]   (defaults to "main")
#
# Emits JSON on stdout. Exit status is 0 in both clean and conflict cases —
# callers should parse `.result`.

set -euo pipefail

base="${1:-main}"

for tool in git jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "babysit/rebase-main: missing required tool: $tool" >&2
    exit 2
  fi
done

if ! git diff --quiet || ! git diff --cached --quiet; then
  jq -n '{result:"dirty_worktree", message:"Refusing to rebase with uncommitted changes."}'
  exit 0
fi

start_sha=$(git rev-parse HEAD)
git fetch origin "$base" --quiet

if git rebase "origin/$base" >/dev/null 2>&1; then
  end_sha=$(git rev-parse HEAD)
  jq -n --arg s "$start_sha" --arg e "$end_sha" --arg b "$base" \
    '{result:"ok", start_sha:$s, end_sha:$e, base:$b}'
  exit 0
fi

# Conflict path — collect info, then abort to restore the worktree.
conflicts=$(git diff --name-only --diff-filter=U || true)
git rebase --abort >/dev/null 2>&1 || true

jq -n --arg s "$start_sha" --arg b "$base" --arg c "$conflicts" \
  '{
     result: "conflict",
     start_sha: $s,
     base: $b,
     conflicted_files: ($c | split("\n") | map(select(length > 0)))
   }'
