#!/usr/bin/env bash
set -euo pipefail

# git-cleanup — Remove local branches whose remote tracking branch is gone.
#
# Usage:
#   git-cleanup                       Preview branches that would be deleted (dry-run)
#   git-cleanup --delete              Delete every gone branch
#
# Classification (shown in preview and used to choose -d vs -D):
#   merged         — branch tip is an ancestor of main (classic fast-forward / merge commit)
#   squash-merged  — branch's tree is already reachable in main under a different SHA
#                    (detected via commit-tree + git cherry patch-id equivalence)
#   unmerged       — neither; a closed-without-merge PR or abandoned work
#
# All three are deleted under --delete, because a gone upstream already signals intent.
# `unmerged` branches are loudly warned about before deletion so nothing disappears silently.

# ---------------------------------------------------------------------------
# Color helpers (disabled when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DELETE=false

for arg in "$@"; do
  case "$arg" in
    --delete) DELETE=true ;;
    --force)
      # Retained for backwards compatibility. --delete now cleans every gone
      # branch regardless of merge status, so --force is no longer meaningful.
      echo -e "${YELLOW}Note: --force is deprecated and now a no-op; --delete already handles all gone branches.${RESET}" >&2
      ;;
    --help|-h)
      echo "Usage: git-cleanup [--delete]"
      echo ""
      echo "Remove local branches whose remote tracking branch has been deleted."
      echo ""
      echo "Options:"
      echo "  (none)     Dry-run — list gone branches with their merge classification"
      echo "  --delete   Delete every gone branch (merged, squash-merged, and unmerged)"
      echo "  --help     Show this help message"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $arg${RESET}" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Ensure we're in a git repo
# ---------------------------------------------------------------------------
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo -e "${RED}Not a git repository.${RESET}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the mainline branch name (prefer main, fall back to master)
# ---------------------------------------------------------------------------
MAIN_LOCAL=""
if git show-ref --verify --quiet refs/heads/main; then
  MAIN_LOCAL="main"
elif git show-ref --verify --quiet refs/heads/master; then
  MAIN_LOCAL="master"
else
  echo -e "${RED}Could not find a local 'main' or 'master' branch to compare against.${RESET}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fetch every remote + prune stale tracking refs
#
# `--all` covers multi-remote repos (e.g. origin + upstream fork setup);
# `--prune` drops tracking refs whose upstream branch has been deleted, which
# is what makes `upstream:track == [gone]` accurate below.
# ---------------------------------------------------------------------------
echo -e "${BOLD}Fetching all remotes and pruning stale tracking refs...${RESET}"
git fetch --all --prune

# ---------------------------------------------------------------------------
# Resolve the comparison ref
#
# Classification (merged / squash-merged) needs an up-to-date mainline tip.
# Local `main` is often behind `origin/main` because users run /git-cleanup
# without a prior `git pull`. Prefer the remote-tracking ref so the fetch
# we just did actually changes the answer.
# ---------------------------------------------------------------------------
MAIN_REF=""
if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "${MAIN_LOCAL}@{upstream}" 2>/dev/null); then
  MAIN_REF="$upstream"
else
  # No upstream tracking ref — fall back to the local branch. Emit a note so
  # the user understands why squash-merge detection might be stale.
  MAIN_REF="$MAIN_LOCAL"
  echo -e "${YELLOW}Note: '${MAIN_LOCAL}' has no upstream tracking ref — comparing against local '${MAIN_LOCAL}' (may miss recent squash-merges from other developers).${RESET}"
fi
echo -e "${BOLD}Comparing against:${RESET} ${MAIN_REF}"

# ---------------------------------------------------------------------------
# Classify a branch: echoes "merged", "squash-merged", or "unmerged".
# ---------------------------------------------------------------------------
classify_branch() {
  local branch=$1
  if git merge-base --is-ancestor "$branch" "$MAIN_REF" 2>/dev/null; then
    echo merged
    return
  fi

  local mb tree tmp
  mb=$(git merge-base "$MAIN_REF" "$branch" 2>/dev/null) || { echo unmerged; return; }
  tree=$(git rev-parse "$branch^{tree}" 2>/dev/null) || { echo unmerged; return; }
  tmp=$(git commit-tree "$tree" -p "$mb" -m _ 2>/dev/null) || { echo unmerged; return; }

  if git cherry "$MAIN_REF" "$tmp" 2>/dev/null | grep -q '^-'; then
    echo squash-merged
  else
    echo unmerged
  fi
}

# ---------------------------------------------------------------------------
# Identify the current branch and collect gone branches + their classification
# (parallel arrays — bash 3 on macOS has no associative arrays by default)
# ---------------------------------------------------------------------------
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

GONE_BRANCHES=()
GONE_STATUS=()
UNMERGED_COUNT=0

while IFS= read -r line; do
  branch=$(echo "$line" | awk '{print $1}')

  # Protect main, master, and the current branch
  case "$branch" in
    main|master) continue ;;
  esac
  if [ "$branch" = "$CURRENT_BRANCH" ]; then
    continue
  fi

  status=$(classify_branch "$branch")
  GONE_BRANCHES+=("$branch")
  GONE_STATUS+=("$status")
  if [ "$status" = "unmerged" ]; then
    UNMERGED_COUNT=$((UNMERGED_COUNT + 1))
  fi
done < <(
  git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads/ \
    | awk '$2 == "[gone]"'
)

# ---------------------------------------------------------------------------
# Helper: colorize a status label for display
# ---------------------------------------------------------------------------
format_status() {
  case "$1" in
    merged)        printf "%b%-14s%b" "$GREEN"  "[merged]"        "$RESET" ;;
    squash-merged) printf "%b%-14s%b" "$BLUE"   "[squash-merged]" "$RESET" ;;
    unmerged)      printf "%b%-14s%b" "$YELLOW" "[unmerged]"      "$RESET" ;;
    *)             printf "%-14s" "[$1]" ;;
  esac
}

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
if [ ${#GONE_BRANCHES[@]} -eq 0 ]; then
  echo -e "${GREEN}Nothing to clean up — no gone branches found.${RESET}"
  exit 0
fi

if [ "$DELETE" = false ]; then
  echo ""
  echo -e "${YELLOW}Found ${#GONE_BRANCHES[@]} branch(es) with deleted remote (all will be deleted on --delete):${RESET}"
  for i in "${!GONE_BRANCHES[@]}"; do
    printf "  %b %s\n" "$(format_status "${GONE_STATUS[$i]}")" "${GONE_BRANCHES[$i]}"
  done
  if [ "$UNMERGED_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Warning: ${UNMERGED_COUNT} branch(es) are not reachable from ${MAIN_REF} — their commits will be lost on delete.${RESET}"
  fi
  echo ""
  echo "Re-run with --delete to remove them."
  exit 0
fi

# ---------------------------------------------------------------------------
# Delete branches
# ---------------------------------------------------------------------------
if [ "$UNMERGED_COUNT" -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}Warning: ${UNMERGED_COUNT} branch(es) are not reachable from ${MAIN_REF} — their commits will be lost.${RESET}"
fi

echo ""
DELETED=0
FAILED=0
for i in "${!GONE_BRANCHES[@]}"; do
  branch="${GONE_BRANCHES[$i]}"
  status="${GONE_STATUS[$i]}"

  # -d is only safe for classic-merged branches; squash-merged and unmerged
  # need -D (the tree is already in main for squash-merged; the user already
  # signaled intent by deleting the remote for unmerged).
  if [ "$status" = "merged" ]; then
    flag="-d"
  else
    flag="-D"
  fi

  if git branch "$flag" "$branch" 2>/dev/null; then
    printf "  %b %b %s\n" "${GREEN}Deleted${RESET}" "$(format_status "$status")" "$branch"
    DELETED=$((DELETED + 1))
  else
    printf "  %b %b %s\n" "${RED}Failed ${RESET}" "$(format_status "$status")" "$branch"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo -e "${BOLD}Done.${RESET} Deleted $DELETED branch(es)."
if [ "$FAILED" -gt 0 ]; then
  echo -e "${RED}$FAILED branch(es) could not be deleted.${RESET}"
  exit 1
fi
