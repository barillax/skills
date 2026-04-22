#!/usr/bin/env bash
# Classify a failing CI check name as either `autofix` (mechanical, babysit
# can likely repair it unattended) or `escalate` (needs user judgment).
#
# The list lives here so it can be updated without editing SKILL.md prose.
# Lowercase-insensitive substring match.
#
# Usage: classify-check.sh "<check-name>"
# Output: a single word, `autofix` or `escalate`.

set -euo pipefail

name="${1:-}"
lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

case "$lower" in
  *lint*|*eslint*|*format*|*prettier*|*typecheck*|*tsc*|*type-check*) echo autofix ;;
  *jest*|*vitest*|*test:all*|*test-all*|*unit*test*|*unit-test*)      echo autofix ;;
  *" test"*|test*|*-test|*_test)                                      echo autofix ;;
  *build*)                                                            echo autofix ;;
  *) echo escalate ;;
esac
