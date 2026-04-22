#!/usr/bin/env bash
# Stage tracked changes and commit. Optionally creates a new branch first.
# Skips files matching secret patterns (.env*, credentials*, *.key, *.pem).
#
# Usage:
#   commit-changes.sh [--branch <name>] [--from-stdin] <commit-message>
#   commit-changes.sh [--branch <name>] [--from-stdin] -F <message-file>
#   commit-changes.sh [--branch <name>] [--from-stdin] --message-file <file>
#
# Commit message:
#   - Pass it as the final positional argument, OR
#   - Pass `-F <file>` / `--message-file <file>` to read it from a file. This
#     is the recommended path for AI/scripted callers — heredoc-quoted strings
#     containing apostrophes break under nested shell eval (Claude Code's Bash
#     tool, CI runners). File-based input sidesteps all shell escaping.
#
# File selection:
#   - By default, stages all modified/deleted tracked files plus untracked
#     files, minus secret patterns (filtered `git add -A`).
#   - With --from-stdin, instead reads a newline-separated list of file paths
#     from stdin and stages those (still skipping secret patterns).
#
# Requires: git, jq.
# Exit status: 0 on success, 1 on failure (nothing to commit, hook failure, etc.)
# Output: JSON { "committed": bool, "branch": str, "sha": str, "files_staged": [str], "error": str|null }

set -euo pipefail

for tool in git jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "commit-changes: missing required tool: $tool" >&2
    exit 2
  fi
done

# --- Parse arguments ---
branch=""
message=""
message_file=""
from_stdin=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      branch="$2"
      shift 2
      ;;
    --branch=*)
      branch="${1#--branch=}"
      shift
      ;;
    --from-stdin)
      from_stdin=true
      shift
      ;;
    -F|--message-file)
      message_file="$2"
      shift 2
      ;;
    --message-file=*)
      message_file="${1#--message-file=}"
      shift
      ;;
    *)
      message="$1"
      shift
      ;;
  esac
done

# Resolve message: file path takes precedence over inline argument
if [[ -n "$message_file" ]]; then
  if [[ ! -f "$message_file" ]]; then
    jq -n --arg f "$message_file" \
      '{ committed: false, branch: "", sha: "", files_staged: [], error: ("Message file not found: " + $f) }'
    exit 1
  fi
  message=$(cat "$message_file")
fi

if [[ -z "$message" ]]; then
  jq -n '{ committed: false, branch: "", sha: "", files_staged: [], error: "No commit message provided (pass as positional arg or via -F <file>)" }'
  exit 1
fi

# --- Secret patterns to skip ---
SECRET_PATTERNS=(
  '\.env$'
  '\.env\.'
  'credentials'
  '\.key$'
  '\.pem$'
  '\.p12$'
  '\.p8$'
  '\.jks$'
  '\.mobileprovision$'
)

is_secret() {
  local file="$1"
  for pattern in "${SECRET_PATTERNS[@]}"; do
    if echo "$file" | grep -qE "$pattern"; then
      return 0
    fi
  done
  return 1
}

# --- Create branch if requested ---
current_branch=$(git branch --show-current)
if [[ -n "$branch" ]]; then
  # Capture stderr so we can surface a real error if checkout fails (e.g.
  # branch already exists). Silently swallowing this would leave the script
  # committing on whatever branch was current — usually main.
  if ! checkout_err=$(git checkout -b "$branch" 2>&1); then
    jq -n --arg branch "$branch" --arg err "$checkout_err" \
      '{ committed: false, branch: "", sha: "", files_staged: [], error: ("Failed to create branch \"" + $branch + "\": " + $err) }'
    exit 1
  fi
  current_branch="$branch"
fi

# --- Determine files to stage ---
files_to_stage=()

if [[ "$from_stdin" == "true" ]]; then
  # Explicit opt-in: read newline-separated file list from stdin.
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if ! is_secret "$file"; then
      files_to_stage+=("$file")
    fi
  done
else
  # Default: auto-detect modified/deleted/untracked files via git status.
  # We don't use [[ -t 0 ]] to choose between modes — the heuristic is
  # unreliable when called from non-interactive contexts (e.g. Claude Code's
  # Bash tool, CI runners) where stdin is a non-tty pipe with no data, which
  # makes `read` block forever. Stdin mode is now opt-in via --from-stdin.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    status="${line:0:2}"
    file="${line:3}"

    # Handle renames: "R  old -> new" format
    if [[ "$file" == *" -> "* ]]; then
      file="${file##* -> }"
    fi

    if ! is_secret "$file"; then
      files_to_stage+=("$file")
    fi
  done < <(git status --porcelain)
fi

if [[ ${#files_to_stage[@]} -eq 0 ]]; then
  # Revert branch creation if nothing to stage
  if [[ -n "$branch" ]]; then
    git checkout - >/dev/null 2>&1
    git branch -D "$branch" >/dev/null 2>&1 || true
  fi
  jq -n '{ committed: false, branch: "", sha: "", files_staged: [], error: "No files to stage (all matched secret patterns or no changes)" }'
  exit 1
fi

# --- Stage files ---
git add "${files_to_stage[@]}" 2>/dev/null

# --- Commit ---
# Use -F file to bypass shell argument length/escaping limits when the message
# contains newlines, apostrophes, etc. Capture stderr so the JSON error
# surfaces the actual hook output instead of a generic "commit failed".
sha=""
commit_msg_tmp=$(mktemp -t pr-commit-msg.XXXXXX)
trap 'rm -f "$commit_msg_tmp"' EXIT
printf '%s' "$message" > "$commit_msg_tmp"

if commit_err=$(git commit -F "$commit_msg_tmp" 2>&1 >/dev/null); then
  sha=$(git rev-parse --short HEAD)
else
  # Commit failed — typically a pre-commit hook rejection. Surface the actual
  # error output so the caller can see what hook failed and why.
  if [[ -n "$branch" ]]; then
    git checkout - >/dev/null 2>&1
    git branch -D "$branch" >/dev/null 2>&1 || true
  fi

  files_json=$(printf '%s\n' "${files_to_stage[@]}" | jq -R . | jq -s .)
  jq -n \
    --argjson files "$files_json" \
    --arg error "$commit_err" \
    '{ committed: false, branch: "", sha: "", files_staged: $files, error: ("Commit failed: " + $error) }'
  exit 1
fi

# --- Output ---
files_json=$(printf '%s\n' "${files_to_stage[@]}" | jq -R . | jq -s .)
jq -n \
  --arg branch "$current_branch" \
  --arg sha "$sha" \
  --argjson files "$files_json" \
  '{ committed: true, branch: $branch, sha: $sha, files_staged: $files, error: null }'
