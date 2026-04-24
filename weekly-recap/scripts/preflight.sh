#!/usr/bin/env bash
# Preflight for /weekly-recap: validates gh auth, fintentional-org access,
# and resolves the date window. Emits a single JSON document on stdout.
#
# Usage: preflight.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--org <org>]
#
# Defaults: trailing 7 days ending today, inclusive. Org: fintentional.
# Requires: gh, jq, date (BSD or GNU). Exit 2 on missing deps.

set -euo pipefail

for tool in gh jq date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "weekly-recap/preflight: missing required tool: $tool" >&2
    exit 2
  fi
done

org="fintentional"
since=""
until_date=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)    since="$2"; shift 2 ;;
    --since=*)  since="${1#--since=}"; shift ;;
    --until)    until_date="$2"; shift 2 ;;
    --until=*)  until_date="${1#--until=}"; shift ;;
    --org)      org="$2"; shift 2 ;;
    --org=*)    org="${1#--org=}"; shift ;;
    *)          shift ;;
  esac
done

today_iso=$(date +%Y-%m-%d)
if [[ -z "$until_date" ]]; then
  until_date="$today_iso"
fi

if [[ -z "$since" ]]; then
  if date -v-6d +%Y-%m-%d >/dev/null 2>&1; then
    since=$(date -v-6d +%Y-%m-%d)
  else
    since=$(date -d '6 days ago' +%Y-%m-%d)
  fi
fi

gh_authenticated=true
gh_user=""
if ! gh auth status >/dev/null 2>&1; then
  gh_authenticated=false
else
  gh_user=$(gh api user -q .login 2>/dev/null || echo "")
fi

org_access=false
if "$gh_authenticated"; then
  if gh api "orgs/${org}" -q .login >/dev/null 2>&1; then
    org_access=true
  fi
fi

jq -n \
  --arg window_start "$since" \
  --arg window_end "$until_date" \
  --arg org "$org" \
  --argjson gh_authenticated "$gh_authenticated" \
  --arg gh_user "$gh_user" \
  --argjson org_access "$org_access" \
  '{
    window_start: $window_start,
    window_end:   $window_end,
    org:          $org,
    gh_authenticated: $gh_authenticated,
    gh_user:      $gh_user,
    org_access:   $org_access
  }'
