#!/usr/bin/env bash
# monitor-pr-state.sh — Watch the current branch's PR and emit one event per
# actionable state transition. Designed to be invoked via the Claude Code
# `Monitor` tool from /pr Phase 4 instead of a /loop /babysit cron.
#
# Each stdout line is a JSON event; exit ends the watch.
#
# Usage:
#   monitor-pr-state.sh [--automerge]
#
# Events (all JSON, one per line):
#   {"event":"needs_attention","reasons":[...],"action":"babysit"}
#       Something actionable changed. Agent should invoke /babysit.
#
#   {"event":"green","action":"merge"|"ready"}
#       PR is fully green: mergeable, no failing / pending checks, no
#       unresolved threads, review not CHANGES_REQUESTED. With --automerge
#       action is "merge" (agent invokes /merge); otherwise "ready" (agent
#       tells the user the PR is ready to merge by hand). Monitor exits.
#
#   {"event":"pr_closed","state":"CLOSED"|"MERGED"|"GONE"}
#       The PR is no longer open (closed, merged out-of-band, or deleted).
#       Monitor exits.
#
#   {"event":"error","detail":"..."}
#       Emitted only for persistent, unrecoverable errors. Transient failures
#       (network blips, gh rate limits) are silently retried.

set -uo pipefail

AUTOMERGE_ACTION="ready"
for arg in "$@"; do
  case "$arg" in
    --automerge) AUTOMERGE_ACTION="merge" ;;
  esac
done

STATUS_SCRIPT="${HOME}/.claude/skills/babysit/scripts/status.sh"
if [[ ! -x "$STATUS_SCRIPT" ]]; then
  printf '%s\n' '{"event":"error","detail":"babysit status.sh not found or not executable"}'
  exit 1
fi

POLL_INTERVAL="${PR_MONITOR_POLL_SEC:-60}"
FAIL_STREAK=0
FAIL_STREAK_MAX=5

prev_sig=""

while true; do
  if ! status_json=$("$STATUS_SCRIPT" 2>/dev/null); then
    FAIL_STREAK=$((FAIL_STREAK + 1))
    if [[ "$FAIL_STREAK" -ge "$FAIL_STREAK_MAX" ]]; then
      printf '%s\n' '{"event":"error","detail":"babysit status.sh failed 5 consecutive times"}'
      exit 1
    fi
    sleep "$POLL_INTERVAL"
    continue
  fi
  FAIL_STREAK=0

  if [[ "$(jq -r '.error // ""' <<<"$status_json")" == "no_pr_for_branch" ]]; then
    printf '%s\n' '{"event":"pr_closed","state":"GONE"}'
    exit 0
  fi

  pr_state=$(jq -r '.pr_state // ""' <<<"$status_json")
  if [[ "$pr_state" == "CLOSED" || "$pr_state" == "MERGED" ]]; then
    jq -nc --arg state "$pr_state" '{event:"pr_closed",state:$state}'
    exit 0
  fi

  # Signature covers every field the agent would act on. Identity of pending
  # checks isn't included (the agent doesn't act on "still running"), but the
  # count is — so a check transitioning from pending to pass/fail registers.
  sig=$(jq -c '{
    all_green,
    failing: [.failing_checks[].name] | sort,
    pending_count: (.pending_checks | length),
    threads: (.unresolved_threads | length),
    review_decision: (.review_decision // ""),
    merge_state_status: (.merge_state_status // ""),
    mergeable: (.mergeable // "")
  }' <<<"$status_json")

  if [[ "$sig" == "$prev_sig" ]]; then
    sleep "$POLL_INTERVAL"
    continue
  fi
  prev_sig="$sig"

  all_green=$(jq -r '.all_green' <<<"$status_json")
  if [[ "$all_green" == "true" ]]; then
    jq -nc --arg action "$AUTOMERGE_ACTION" '{event:"green",action:$action}'
    exit 0
  fi

  # Enumerate every actionable reason — silence is not success. If the only
  # remaining non-green condition is pending checks (i.e. CI is still running
  # after a push), reasons ends up empty and we hold the event until the next
  # transition.
  reasons=$(jq -c '
    [
      (if (.mergeable // "") == "CONFLICTING" then "conflict" else empty end),
      (if (.merge_state_status // "") == "BEHIND" then "behind_base" else empty end),
      (if (.review_decision // "") == "CHANGES_REQUESTED" then "changes_requested" else empty end),
      (if ((.failing_checks // []) | length) > 0
         then ("failing_checks:" + ([.failing_checks[].name] | join(","))) else empty end),
      (if ((.unresolved_threads // []) | length) > 0
         then ("threads:" + (((.unresolved_threads // []) | length | tostring))) else empty end)
    ]
  ' <<<"$status_json")

  if [[ "$(jq -r 'length' <<<"$reasons")" == "0" ]]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  jq -nc --argjson reasons "$reasons" '{event:"needs_attention",reasons:$reasons,action:"babysit"}'

  sleep "$POLL_INTERVAL"
done
