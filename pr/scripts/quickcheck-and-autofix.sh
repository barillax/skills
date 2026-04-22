#!/usr/bin/env bash
# Run quality checks (typecheck, lint, format). If lint/format fail, auto-fix
# and commit the fixes, then re-check. Typecheck failures are reported but not
# auto-fixed (they require LLM judgment for non-mechanical errors).
#
# Usage: quickcheck-and-autofix.sh
#
# Requires: pnpm/yarn/bun/npm (auto-detected), git, jq.
# Exit status: always 0 — callers read the JSON output.
# Output: JSON {
#   "passed": bool,
#   "autofix_applied": bool,
#   "autofix_commit": str|null,
#   "remaining_failures": { "typecheck"?: { "output": str }, "lint"?: { "output": str }, "format"?: { "output": str } }
# }

set -euo pipefail

for tool in git jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "quickcheck-and-autofix: missing required tool: $tool" >&2
    exit 2
  fi
done

# --- Package manager detection (inline, no external dep) ---
detect_pm() {
  local r
  r=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  [[ -f "$r/pnpm-lock.yaml" ]] && { echo pnpm; return; }
  [[ -f "$r/yarn.lock"      ]] && { echo yarn; return; }
  [[ -f "$r/bun.lockb"      ]] && { echo bun;  return; }
  local pm=""
  if [[ -f "$r/package.json" ]]; then
    pm=$(jq -r '.packageManager // empty' "$r/package.json" 2>/dev/null | sed 's/@.*//')
  fi
  [[ -n "$pm" ]] && { echo "$pm"; return; }
  echo npm
}
PM=$(detect_pm)


MAX_LINES=80

# --- Run a single check, capture pass/fail and truncated output ---
run_check() {
  local name="$1"
  shift
  local output=""
  local passed=true

  if output=$("$@" 2>&1); then
    passed=true
  else
    passed=false
  fi

  # Truncate to last N lines
  local line_count
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  if [[ "$line_count" -gt "$MAX_LINES" ]]; then
    output="... (truncated, showing last $MAX_LINES of $line_count lines) ...
$(echo "$output" | tail -n "$MAX_LINES")"
  fi

  printf '%s' "$passed" > "/tmp/qcaf_${name}_passed"
  printf '%s' "$output" > "/tmp/qcaf_${name}_output"
}

cleanup_temps() {
  rm -f /tmp/qcaf_typecheck_passed /tmp/qcaf_typecheck_output \
        /tmp/qcaf_lint_passed /tmp/qcaf_lint_output \
        /tmp/qcaf_format_passed /tmp/qcaf_format_output
}

# =============================================
# Pass 1 — Initial check
# =============================================
run_check typecheck "$PM" run typecheck 2>/dev/null
run_check lint "$PM" run lint 2>/dev/null
run_check format "$PM" run format:check 2>/dev/null

tc_passed=$(cat /tmp/qcaf_typecheck_passed)
lint_passed=$(cat /tmp/qcaf_lint_passed)
fmt_passed=$(cat /tmp/qcaf_format_passed)

# If everything passes on first try, exit early
if [[ "$tc_passed" == "true" && "$lint_passed" == "true" && "$fmt_passed" == "true" ]]; then
  cleanup_temps
  jq -n '{
    passed: true,
    autofix_applied: false,
    autofix_commit: null,
    remaining_failures: {}
  }'
  exit 0
fi

# =============================================
# Auto-fix lint + format (if either failed)
# =============================================
autofix_applied=false
autofix_commit="null"

if [[ "$lint_passed" != "true" || "$fmt_passed" != "true" ]]; then
  # Run auto-fixers
  "$PM" run lint:fix >/dev/null 2>&1 || true
  "$PM" run format >/dev/null 2>&1 || true

  # Check if anything changed
  if [[ -n "$(git status --porcelain)" ]]; then
    autofix_applied=true

    # Stage and commit the fixes
    git add -u >/dev/null 2>&1
    if git commit -m "chore(ci): apply lint and format fixes

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>" >/dev/null 2>&1; then
      autofix_commit=$(git rev-parse --short HEAD)
      autofix_commit="\"$autofix_commit\""
    else
      # Commit failed (hook rejection) — unstage
      git reset HEAD >/dev/null 2>&1 || true
      autofix_applied=false
    fi
  fi
fi

# =============================================
# Pass 2 — Re-check after autofix
# =============================================
cleanup_temps

run_check typecheck "$PM" run typecheck 2>/dev/null
run_check lint "$PM" run lint 2>/dev/null
run_check format "$PM" run format:check 2>/dev/null

tc_passed=$(cat /tmp/qcaf_typecheck_passed)
tc_output=$(cat /tmp/qcaf_typecheck_output)
lint_passed=$(cat /tmp/qcaf_lint_passed)
lint_output=$(cat /tmp/qcaf_lint_output)
fmt_passed=$(cat /tmp/qcaf_format_passed)
fmt_output=$(cat /tmp/qcaf_format_output)

cleanup_temps

# =============================================
# Build output
# =============================================
all_passed=true
remaining="{}"

if [[ "$tc_passed" != "true" || "$lint_passed" != "true" || "$fmt_passed" != "true" ]]; then
  all_passed=false

  # Build remaining_failures object
  remaining=$(jq -n \
    --argjson tc_passed "$tc_passed" \
    --arg tc_output "$tc_output" \
    --argjson lint_passed "$lint_passed" \
    --arg lint_output "$lint_output" \
    --argjson fmt_passed "$fmt_passed" \
    --arg fmt_output "$fmt_output" \
    '{}
    | if ($tc_passed | not) then . + { typecheck: { output: $tc_output } } else . end
    | if ($lint_passed | not) then . + { lint: { output: $lint_output } } else . end
    | if ($fmt_passed | not) then . + { format: { output: $fmt_output } } else . end
    ')
fi

jq -n \
  --argjson passed "$all_passed" \
  --argjson autofix_applied "$autofix_applied" \
  --argjson autofix_commit "$autofix_commit" \
  --argjson remaining_failures "$remaining" \
  '{
    passed: $passed,
    autofix_applied: $autofix_applied,
    autofix_commit: $autofix_commit,
    remaining_failures: $remaining_failures
  }'
