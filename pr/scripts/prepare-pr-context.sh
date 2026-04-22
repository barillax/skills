#!/usr/bin/env bash
# Gather all context needed for PR title + body generation in one shot.
# Outputs compact JSON so the LLM makes one read instead of multiple git calls.
#
# Usage: prepare-pr-context.sh <base>
#
# Requires: git, jq.
# Exit status: always 0.
# Output: JSON {
#   "base": str,
#   "branch": str,
#   "commits": [{ "sha": str, "message": str }],
#   "diff_stat": str,
#   "changed_files": [{ "path": str, "status": str, "additions": int, "deletions": int }],
#   "total_additions": int,
#   "total_deletions": int,
#   "diff_preview": str   (first 300 lines of full diff, for semantic understanding)
# }

set -euo pipefail

base="${1:-main}"
branch=$(git branch --show-current)

# --- Commits ---
commits_json="[]"
if git rev-parse --verify "origin/$base" >/dev/null 2>&1; then
  commits_json=$(git log "origin/$base..HEAD" --format='{"sha":"%h","message":"%s"}' 2>/dev/null \
    | jq -s '.' 2>/dev/null || echo "[]")
fi

# --- Diff stat ---
diff_stat=""
if git rev-parse --verify "origin/$base" >/dev/null 2>&1; then
  diff_stat=$(git diff --stat "origin/$base...HEAD" 2>/dev/null || echo "")
fi

# --- Changed files with additions/deletions ---
changed_files_json="[]"
total_add=0
total_del=0
if git rev-parse --verify "origin/$base" >/dev/null 2>&1; then
  changed_files_json=$(git diff --numstat "origin/$base...HEAD" 2>/dev/null | while IFS=$'\t' read -r add del path; do
    # Handle binary files (shown as -)
    [[ "$add" == "-" ]] && add=0
    [[ "$del" == "-" ]] && del=0
    # Determine status
    status="M"
    if ! git cat-file -e "origin/$base:$path" 2>/dev/null; then
      status="A"
    fi
    printf '{"path":"%s","status":"%s","additions":%d,"deletions":%d}\n' "$path" "$status" "$add" "$del"
  done | jq -s '.' 2>/dev/null || echo "[]")

  # Also check for deleted files
  deleted=$(git diff --diff-filter=D --name-only "origin/$base...HEAD" 2>/dev/null || true)
  if [[ -n "$deleted" ]]; then
    deleted_json=$(echo "$deleted" | while read -r path; do
      printf '{"path":"%s","status":"D","additions":0,"deletions":0}\n' "$path"
    done | jq -s '.')
    changed_files_json=$(echo "$changed_files_json $deleted_json" | jq -s 'add')
  fi

  total_add=$(echo "$changed_files_json" | jq '[.[].additions] | add // 0')
  total_del=$(echo "$changed_files_json" | jq '[.[].deletions] | add // 0')
fi

# --- Diff preview (first 300 lines for semantic context) ---
diff_preview=""
if git rev-parse --verify "origin/$base" >/dev/null 2>&1; then
  diff_preview=$(git diff "origin/$base...HEAD" 2>/dev/null | head -300 || echo "")
  line_count=$(git diff "origin/$base...HEAD" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$line_count" -gt 300 ]]; then
    diff_preview="$diff_preview
... (truncated, $line_count total lines — showing first 300)"
  fi
fi

# --- Build JSON output ---
jq -n \
  --arg base "$base" \
  --arg branch "$branch" \
  --argjson commits "$commits_json" \
  --arg diff_stat "$diff_stat" \
  --argjson changed_files "$changed_files_json" \
  --argjson total_additions "$total_add" \
  --argjson total_deletions "$total_del" \
  --arg diff_preview "$diff_preview" \
  '{
    base: $base,
    branch: $branch,
    commits: $commits,
    diff_stat: $diff_stat,
    changed_files: $changed_files,
    total_additions: $total_additions,
    total_deletions: $total_deletions,
    diff_preview: $diff_preview
  }'
