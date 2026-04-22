#!/usr/bin/env bash
# Detect git state and determine what action is needed before creating a PR.
# Outputs a single JSON document that the /pr SKILL.md consumes.
#
# Usage: preflight.sh [--base <branch>]
#
# Requires: git, gh (authenticated), jq.
# Exit status: 0 on success. Non-zero only for missing deps or auth failure.

set -euo pipefail

for tool in git gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "pr/preflight: missing required tool: $tool" >&2
    exit 2
  fi
done

# --- Parse arguments ---
base=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      base="$2"
      shift 2
      ;;
    --base=*)
      base="${1#--base=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# --- Check gh auth ---
gh_authenticated=true
if ! gh auth status >/dev/null 2>&1; then
  gh_authenticated=false
fi

# --- Current branch ---
branch=$(git branch --show-current)

# --- Default branch detection ---
if [[ -z "$base" ]]; then
  if "$gh_authenticated"; then
    base=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")
  else
    base="main"
  fi
fi

is_default_branch=false
if [[ "$branch" == "$base" ]]; then
  is_default_branch=true
fi

# --- Uncommitted changes ---
uncommitted_files=()
staged_files=()
untracked_files=()

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  index="${line:0:1}"
  worktree="${line:1:1}"
  file="${line:3}"

  if [[ "$index" == "?" ]]; then
    untracked_files+=("$file")
  else
    if [[ "$index" != " " && "$index" != "?" ]]; then
      staged_files+=("$file")
    fi
    if [[ "$worktree" != " " && "$worktree" != "?" ]]; then
      uncommitted_files+=("$file")
    fi
  fi
done < <(git status --porcelain)

has_uncommitted=false
if [[ ${#uncommitted_files[@]} -gt 0 || ${#staged_files[@]} -gt 0 || ${#untracked_files[@]} -gt 0 ]]; then
  has_uncommitted=true
fi

# --- Commits ahead of base ---
# Fetch base to ensure we have up-to-date refs
git fetch origin "$base" --quiet 2>/dev/null || true

commits_ahead=0
if ! "$is_default_branch"; then
  commits_ahead=$(git rev-list --count "origin/$base..HEAD" 2>/dev/null || echo "0")
elif "$is_default_branch"; then
  commits_ahead=$(git rev-list --count "origin/$base..HEAD" 2>/dev/null || echo "0")
fi

# --- Diff stats ---
diff_stat=""
if ! "$is_default_branch" && [[ "$commits_ahead" -gt 0 ]]; then
  diff_stat=$(git diff --stat "origin/$base..HEAD" 2>/dev/null || echo "")
elif "$has_uncommitted"; then
  diff_stat=$(git diff --stat 2>/dev/null || echo "")
fi

# --- Remote tracking ---
remote_tracking=""
remote_tracking=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "")

# --- Existing PR check ---
existing_pr="null"
if "$gh_authenticated" && ! "$is_default_branch"; then
  pr_json=$(gh pr list --head "$branch" --json number,url --limit 1 2>/dev/null || echo "[]")
  pr_count=$(echo "$pr_json" | jq 'length')
  if [[ "$pr_count" -gt 0 ]]; then
    existing_pr=$(echo "$pr_json" | jq '.[0]')
  fi
fi

# --- Determine action_needed ---
action_needed=""

if "$is_default_branch"; then
  if "$has_uncommitted"; then
    action_needed="create_branch_and_commit"
  elif [[ "$commits_ahead" -gt 0 ]]; then
    action_needed="ask_user"
  else
    action_needed="nothing_to_do"
  fi
else
  if [[ "$existing_pr" != "null" ]]; then
    action_needed="already_has_pr"
  elif "$has_uncommitted"; then
    action_needed="commit"
  elif [[ -z "$remote_tracking" ]] || [[ "$commits_ahead" -gt 0 ]]; then
    # Not pushed, or has new commits to push
    ahead_of_remote=0
    if [[ -n "$remote_tracking" ]]; then
      ahead_of_remote=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo "0")
    fi
    if [[ -z "$remote_tracking" ]] || [[ "$ahead_of_remote" -gt 0 ]]; then
      action_needed="push"
    else
      action_needed="ready"
    fi
  else
    action_needed="ready"
  fi
fi

# --- Helper: bash array → JSON array (handles empty arrays) ---
to_json_array() {
  if [[ $# -eq 0 ]]; then
    echo "[]"
  else
    printf '%s\n' "$@" | jq -R . | jq -s .
  fi
}

# --- Build JSON output ---
jq -n \
  --arg branch "$branch" \
  --argjson is_default_branch "$is_default_branch" \
  --arg base "$base" \
  --argjson has_uncommitted "$has_uncommitted" \
  --argjson uncommitted_files "$(to_json_array "${uncommitted_files[@]+"${uncommitted_files[@]}"}")" \
  --argjson staged_files "$(to_json_array "${staged_files[@]+"${staged_files[@]}"}")" \
  --argjson untracked_files "$(to_json_array "${untracked_files[@]+"${untracked_files[@]}"}")" \
  --argjson commits_ahead_of_base "$commits_ahead" \
  --arg diff_stat "$diff_stat" \
  --arg remote_tracking "$remote_tracking" \
  --argjson gh_authenticated "$gh_authenticated" \
  --argjson existing_pr "$existing_pr" \
  --arg action_needed "$action_needed" \
  '{
    branch: $branch,
    is_default_branch: $is_default_branch,
    base: $base,
    has_uncommitted: $has_uncommitted,
    uncommitted_files: $uncommitted_files,
    staged_files: $staged_files,
    untracked_files: $untracked_files,
    commits_ahead_of_base: $commits_ahead_of_base,
    diff_stat: $diff_stat,
    remote_tracking: $remote_tracking,
    gh_authenticated: $gh_authenticated,
    existing_pr: $existing_pr,
    action_needed: $action_needed
  }'
