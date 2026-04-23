#!/usr/bin/env bash
# Emit a single JSON document describing whether the current branch's PR is
# ready to merge. Combines local git state checks with babysit's status.sh
# for PR/CI state. This is the single source of truth for /merge readiness.
#
# Requires: git, gh (authenticated), jq.
# Exit status: always 0 — readiness is communicated via JSON `ready_to_merge`.

set -euo pipefail

for tool in git gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "merge/preflight: missing required tool: $tool" >&2
    exit 2
  fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUS_SCRIPT="$SCRIPT_DIR/../../babysit/scripts/status.sh"

if [[ ! -x "$STATUS_SCRIPT" ]]; then
  echo "merge/preflight: babysit status script not found at $STATUS_SCRIPT" >&2
  exit 2
fi

blockers='[]'
add_blocker() {
  local code="$1" detail="$2"
  blockers=$(jq -c --arg c "$code" --arg d "$detail" '. + [{"code":$c,"detail":$d}]' <<<"$blockers")
}

# ---------------------------------------------------------------------------
# Worktree detection
# ---------------------------------------------------------------------------
git_dir=$(cd "$(git rev-parse --git-dir)" && pwd)
git_common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd)
current_worktree_path=$(git rev-parse --show-toplevel)

is_worktree=false
main_worktree_path=""
if [[ "$git_dir" != "$git_common_dir" ]]; then
  is_worktree=true
  main_worktree_path="$(cd "$git_common_dir/.." && pwd)"
fi

# Detect worktrunk — used by the caller to choose between ExitWorktree
# (Claude Code isolation) and `wt remove` (manual / worktrunk-managed).
has_worktrunk=false
if command -v wt >/dev/null 2>&1; then
  has_worktrunk=true
fi

# ---------------------------------------------------------------------------
# Branch + default branch
# ---------------------------------------------------------------------------
branch=$(git branch --show-current)
default_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")

if [[ "$branch" == "$default_branch" ]]; then
  add_blocker "on_default_branch" "Currently on $default_branch — switch to a feature branch first."
fi

# ---------------------------------------------------------------------------
# Local state checks
# ---------------------------------------------------------------------------
porcelain=$(git status --porcelain)
if [[ -n "$porcelain" ]]; then
  file_count=$(echo "$porcelain" | wc -l | tr -d ' ')
  add_blocker "dirty_worktree" "$file_count uncommitted/untracked file(s). Commit or stash before merging."
fi

if remote_tracking=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null); then
  unpushed=$(git rev-list '@{u}..HEAD' --count 2>/dev/null || echo "0")
  if [[ "$unpushed" -gt 0 ]]; then
    add_blocker "unpushed_commits" "$unpushed commit(s) not pushed to remote. Push first — CI hasn't verified them."
  fi
else
  add_blocker "no_remote_tracking" "Branch has no remote tracking branch. Push to origin first."
fi

# ---------------------------------------------------------------------------
# PR / CI state (delegate to babysit's status.sh)
# ---------------------------------------------------------------------------
pr_number="null"
pr_url=""

# Only call status.sh if we're on a feature branch (skip if already blocked on default branch)
if [[ "$branch" != "$default_branch" ]]; then
  status_json=$("$STATUS_SCRIPT" 2>/dev/null) || {
    add_blocker "status_error" "Failed to fetch PR status from GitHub."
    status_json='{}'
  }

  pr_number=$(jq -r '.pr_number // "null"' <<<"$status_json")

  if [[ "$pr_number" == "null" ]]; then
    add_blocker "no_pr" "No PR found for branch $branch."
  else
    pr_url=$(jq -r '.pr_url // ""' <<<"$status_json")
    pr_state=$(jq -r '.pr_state // ""' <<<"$status_json")
    mergeable=$(jq -r '.mergeable // ""' <<<"$status_json")
    merge_state_status=$(jq -r '.merge_state_status // ""' <<<"$status_json")
    review_decision=$(jq -r '.review_decision // ""' <<<"$status_json")

    if [[ "$pr_state" != "OPEN" ]]; then
      add_blocker "pr_not_open" "PR #$pr_number is $pr_state, not OPEN."
    fi

    if [[ "$mergeable" != "MERGEABLE" ]]; then
      add_blocker "not_mergeable" "PR is $mergeable (merge state: $merge_state_status). Resolve conflicts or unblock first."
    fi

    failing_names=$(jq -r '[.failing_checks[]?.name] | join(", ")' <<<"$status_json")
    failing_count=$(jq -r '.failing_checks | length' <<<"$status_json")
    if [[ "$failing_count" -gt 0 ]]; then
      add_blocker "failing_checks" "$failing_count failing check(s): $failing_names"
    fi

    pending_names=$(jq -r '[.pending_checks[]?.name] | join(", ")' <<<"$status_json")
    pending_count=$(jq -r '.pending_checks | length' <<<"$status_json")
    if [[ "$pending_count" -gt 0 ]]; then
      add_blocker "pending_checks" "$pending_count pending check(s): $pending_names. Wait for CI to finish."
    fi

    thread_count=$(jq -r '.unresolved_threads | length' <<<"$status_json")
    if [[ "$thread_count" -gt 0 ]]; then
      add_blocker "unresolved_threads" "$thread_count unresolved review thread(s). Resolve them before merging."
    fi

    if [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
      add_blocker "changes_requested" "Review changes have been requested. Address feedback and get re-approval."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Assemble output
# ---------------------------------------------------------------------------
blocker_count=$(jq 'length' <<<"$blockers")
ready_to_merge=true
if [[ "$blocker_count" -gt 0 ]]; then
  ready_to_merge=false
fi

jq -n \
  --argjson ready "$ready_to_merge" \
  --argjson blockers "$blockers" \
  --argjson is_worktree "$is_worktree" \
  --argjson has_worktrunk "$has_worktrunk" \
  --arg main_worktree_path "$main_worktree_path" \
  --arg current_worktree_path "$current_worktree_path" \
  --arg branch "$branch" \
  --arg default_branch "$default_branch" \
  --argjson pr_number "$pr_number" \
  --arg pr_url "$pr_url" \
  '{
    ready_to_merge: $ready,
    blockers: $blockers,
    is_worktree: $is_worktree,
    has_worktrunk: $has_worktrunk,
    main_worktree_path: $main_worktree_path,
    current_worktree_path: $current_worktree_path,
    branch: $branch,
    default_branch: $default_branch,
    pr_number: $pr_number,
    pr_url: $pr_url
  }'
