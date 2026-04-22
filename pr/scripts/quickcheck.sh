#!/usr/bin/env bash
# Run lightweight local quality checks (typecheck, lint, format) and output
# structured JSON results. Tests are left to CI + /babysit.
#
# Usage: quickcheck.sh
#
# Requires: pnpm/yarn/bun/npm (auto-detected), jq.
# Exit status: always 0 — callers should read the JSON `.passed` field.

set -euo pipefail

for tool in jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "pr/quickcheck: missing required tool: $tool" >&2
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

# Run a check and capture result. Truncates output to last $MAX_LINES lines.
# Usage: run_check <name> <command...>
# Sets: check_<name>_passed, check_<name>_output
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

  # Export via temp files to avoid subshell scoping issues
  printf '%s' "$passed" > "/tmp/qc_${name}_passed"
  printf '%s' "$output" > "/tmp/qc_${name}_output"
}

# --- Run checks ---
run_check typecheck "$PM" run typecheck 2>/dev/null
run_check lint "$PM" run lint 2>/dev/null
run_check format "$PM" run format:check 2>/dev/null

# --- Read results ---
tc_passed=$(cat /tmp/qc_typecheck_passed)
tc_output=$(cat /tmp/qc_typecheck_output)
lint_passed=$(cat /tmp/qc_lint_passed)
lint_output=$(cat /tmp/qc_lint_output)
fmt_passed=$(cat /tmp/qc_format_passed)
fmt_output=$(cat /tmp/qc_format_output)

# Clean up
rm -f /tmp/qc_typecheck_passed /tmp/qc_typecheck_output \
      /tmp/qc_lint_passed /tmp/qc_lint_output \
      /tmp/qc_format_passed /tmp/qc_format_output

# --- Overall pass ---
all_passed=true
if [[ "$tc_passed" != "true" || "$lint_passed" != "true" || "$fmt_passed" != "true" ]]; then
  all_passed=false
fi

# --- Build JSON output ---
jq -n \
  --argjson passed "$all_passed" \
  --argjson tc_passed "$tc_passed" \
  --arg tc_output "$tc_output" \
  --argjson lint_passed "$lint_passed" \
  --arg lint_output "$lint_output" \
  --argjson fmt_passed "$fmt_passed" \
  --arg fmt_output "$fmt_output" \
  '{
    passed: $passed,
    checks: {
      typecheck: { passed: $tc_passed, output: $tc_output },
      lint: { passed: $lint_passed, output: $lint_output },
      format: { passed: $fmt_passed, output: $fmt_output }
    }
  }'
