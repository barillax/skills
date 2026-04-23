#!/usr/bin/env bash
# Merge the current branch's PR and clean up locally.
# Reads preflight JSON from stdin (pipe from preflight.sh).
#
# Exit codes:
#   0 — merge + cleanup complete (normal checkout)
#   1 — error (blocked or merge failed)
#   2 — merge succeeded, worktree cleanup needed (caller handles ExitWorktree)
#
# Requires: git, gh, jq, npm.

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers (disabled when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

# ---------------------------------------------------------------------------
# Read preflight JSON from stdin
# ---------------------------------------------------------------------------
input=$(cat)

ready=$(jq -r '.ready_to_merge' <<<"$input")
pr_number=$(jq -r '.pr_number' <<<"$input")
pr_url=$(jq -r '.pr_url' <<<"$input")
is_worktree=$(jq -r '.is_worktree' <<<"$input")
has_worktrunk=$(jq -r '.has_worktrunk' <<<"$input")
main_worktree_path=$(jq -r '.main_worktree_path' <<<"$input")
current_worktree_path=$(jq -r '.current_worktree_path' <<<"$input")
branch=$(jq -r '.branch' <<<"$input")
default_branch=$(jq -r '.default_branch' <<<"$input")

# ---------------------------------------------------------------------------
# Check readiness
# ---------------------------------------------------------------------------
if [[ "$ready" != "true" ]]; then
  echo -e "${RED}${BOLD}Cannot merge.${RESET} Blockers:"
  echo ""
  jq -r '.blockers[] | "  • \(.code): \(.detail)"' <<<"$input"
  echo ""
  echo "Fix these issues and re-run /merge."
  exit 1
fi

# ---------------------------------------------------------------------------
# Merge
# ---------------------------------------------------------------------------
echo -e "${BOLD}Merging PR #${pr_number}...${RESET}"

# In a worktree, `gh pr merge --delete-branch` fails when the current worktree
# is on the branch being deleted: gh tries to `git checkout <default>` locally
# to free the branch, which errors with `'main' is already used by worktree`.
# Skip --delete-branch in that case; we delete the remote ref separately via
# the GitHub API, and wt/git-cleanup handles the local branch later.
merge_flags=(--squash)
if [[ "$is_worktree" != "true" ]]; then
  merge_flags+=(--delete-branch)
fi

if ! merge_output=$(gh pr merge "$pr_number" "${merge_flags[@]}" 2>&1); then
  echo -e "${RED}${BOLD}Merge failed:${RESET}"
  echo "$merge_output"
  exit 1
fi

echo -e "${GREEN}✓${RESET} Merged PR #${pr_number} via squash merge. ${pr_url}"

# In worktree mode, delete the remote branch explicitly (we skipped
# --delete-branch above). Non-fatal on failure — the branch may already be
# gone if the repo has "automatically delete head branches" enabled.
if [[ "$is_worktree" == "true" ]]; then
  if gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$branch" >/dev/null 2>&1; then
    echo -e "${GREEN}✓${RESET} Deleted remote branch ${branch}."
  else
    echo -e "${YELLOW}(Remote branch ${branch} already gone or delete refused — not blocking.)${RESET}"
  fi
fi

# ---------------------------------------------------------------------------
# Local cleanup
# ---------------------------------------------------------------------------
if [[ "$is_worktree" == "true" ]]; then
  echo ""
  echo -e "${YELLOW}Worktree detected — local cleanup handled by the caller.${RESET}"
  echo ""
  echo -e "${BOLD}Caller context (JSON):${RESET}"
  # Emit a single-line JSON on its own line so the caller can parse it.
  jq -nc \
    --arg branch "$branch" \
    --arg default_branch "$default_branch" \
    --arg main_worktree_path "$main_worktree_path" \
    --arg current_worktree_path "$current_worktree_path" \
    --argjson has_worktrunk "$has_worktrunk" \
    --argjson pr_number "$pr_number" \
    '{branch: $branch, default_branch: $default_branch, main_worktree_path: $main_worktree_path, current_worktree_path: $current_worktree_path, has_worktrunk: $has_worktrunk, pr_number: $pr_number}'
  exit 2
fi

echo ""
echo -e "${BOLD}Switching to ${default_branch} and pulling...${RESET}"
git checkout "$default_branch"
git pull

echo ""
echo -e "${BOLD}Cleaning up stale branches...${RESET}"
# Use the bundled git-cleanup script — sibling skill under ~/.claude/skills/git-cleanup/
cleanup_script="${CLAUDE_SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/../git-cleanup/scripts/cleanup.sh"
if [[ -x "$cleanup_script" ]]; then
  "$cleanup_script" --delete
else
  echo -e "${YELLOW}(Skipping cleanup — git-cleanup skill not installed. Install with: npx skills add barillax/skills/git-cleanup)${RESET}"
fi

echo ""
echo -e "${GREEN}${BOLD}Done.${RESET} Merged PR #${pr_number}, on ${default_branch}, branches cleaned up."
