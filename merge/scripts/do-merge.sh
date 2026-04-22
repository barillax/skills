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

if ! merge_output=$(gh pr merge "$pr_number" --squash --delete-branch 2>&1); then
  echo -e "${RED}${BOLD}Merge failed:${RESET}"
  echo "$merge_output"
  exit 1
fi

echo -e "${GREEN}✓${RESET} Merged PR #${pr_number} via squash merge. ${pr_url}"

# ---------------------------------------------------------------------------
# Local cleanup
# ---------------------------------------------------------------------------
if [[ "$is_worktree" == "true" ]]; then
  echo ""
  echo -e "${YELLOW}Worktree detected — skipping local checkout.${RESET}"
  echo "Worktree cleanup needed."
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
