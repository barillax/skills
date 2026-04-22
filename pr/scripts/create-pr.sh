#!/usr/bin/env bash
# Push the current branch and create a GitHub PR in one shot.
#
# Usage: create-pr.sh --title <title> --body-file <path> --base <branch>
#
# Requires: git, gh.
# Exit status: 0 on success, 1 on failure.
# Output: JSON { "pr_url": str, "pr_number": int } or { "error": str }

set -euo pipefail

for tool in git gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "create-pr: missing required tool: $tool" >&2
    exit 2
  fi
done

# --- Parse arguments ---
title=""
body_file=""
base=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)    title="$2"; shift 2 ;;
    --title=*)  title="${1#--title=}"; shift ;;
    --body-file)   body_file="$2"; shift 2 ;;
    --body-file=*) body_file="${1#--body-file=}"; shift ;;
    --base)     base="$2"; shift 2 ;;
    --base=*)   base="${1#--base=}"; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$title" ]]; then
  jq -n '{ error: "Missing --title" }'
  exit 1
fi

if [[ -z "$body_file" || ! -f "$body_file" ]]; then
  jq -n --arg f "$body_file" '{ error: ("Missing or invalid --body-file: " + $f) }'
  exit 1
fi

# Reject empty body files. Caller almost certainly meant to write content first
# but skipped the Write step (or it failed silently while running in parallel).
if [[ ! -s "$body_file" ]]; then
  jq -n --arg f "$body_file" '{ error: ("--body-file is empty: " + $f + ". Write the PR body to this file before invoking create-pr.sh.") }'
  exit 1
fi

# Reject stale body files. Defends against the "Claude wrote a different file
# in a previous session and forgot to update this one" footgun. PR bodies are
# generated within seconds of running this script — anything older than 5
# minutes is almost certainly stale content from a prior run. Cross-platform
# mtime: try BSD stat first (macOS), fall back to GNU stat (Linux). If neither
# works, fail open since this is a sanity check, not a security boundary.
body_mtime=$(stat -f %m "$body_file" 2>/dev/null || stat -c %Y "$body_file" 2>/dev/null || echo "")
if [[ -n "$body_mtime" ]]; then
  body_age=$(( $(date +%s) - body_mtime ))
  if [[ $body_age -gt 300 ]]; then
    jq -n \
      --arg f "$body_file" \
      --arg age "$body_age" \
      '{ error: ("--body-file is stale (" + $age + "s old, max 300s): " + $f + ". This usually means a previous session left this file behind and the current session forgot to overwrite it. Delete it (rm -f " + $f + ") and write a fresh body.") }'
    exit 1
  fi
fi

base="${base:-main}"
branch=$(git branch --show-current)

# --- Push ---
# Capture stderr so the JSON error surfaces the actual reason (auth failure,
# protected branch, network error) instead of a generic "git push failed".
if ! push_err=$(git push -u origin "$branch" 2>&1 >/dev/null); then
  jq -n --arg err "$push_err" '{ error: ("git push failed: " + $err) }'
  exit 1
fi

# --- Create PR ---
# Use `if !` to capture both stdout (PR URL on success) and stderr (error
# message on failure) into a single variable. The previous pattern of
# `pr_url=$(...); if [[ $? -ne 0 ]]` was broken under `set -e` — the script
# would exit on the failed assignment before the if-test ran, so PR creation
# errors were never reported.
if ! pr_output=$(gh pr create --title "$title" --body-file "$body_file" --base "$base" 2>&1); then
  jq -n --arg err "$pr_output" '{ error: ("gh pr create failed: " + $err) }'
  exit 1
fi

pr_url="$pr_output"
# Extract PR number from URL (format: https://github.com/owner/repo/pull/N)
pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "0")
if [[ -z "$pr_number" ]]; then
  pr_number=0
fi

jq -n \
  --arg pr_url "$pr_url" \
  --argjson pr_number "$pr_number" \
  '{ pr_url: $pr_url, pr_number: $pr_number }'
