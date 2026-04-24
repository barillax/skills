#!/usr/bin/env bash
# Collect GitHub signals in an org for /weekly-recap.
# Emits JSON on stdout. Failed sub-queries degrade to empty arrays (never error the whole run).
#
# Usage: collect-github.sh --since YYYY-MM-DD --until YYYY-MM-DD [--org <org>] [--no-bots]
#
# Requires: gh (authenticated), jq.

set -euo pipefail

for tool in gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "weekly-recap/collect-github: missing required tool: $tool" >&2
    exit 2
  fi
done

org="fintentional"
since=""
until_date=""
filter_bots=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)     since="$2"; shift 2 ;;
    --since=*)   since="${1#--since=}"; shift ;;
    --until)     until_date="$2"; shift 2 ;;
    --until=*)   until_date="${1#--until=}"; shift ;;
    --org)       org="$2"; shift 2 ;;
    --org=*)     org="${1#--org=}"; shift ;;
    --no-bots)   filter_bots=false; shift ;;
    *)           shift ;;
  esac
done

if [[ -z "$since" || -z "$until_date" ]]; then
  echo "weekly-recap/collect-github: --since and --until are required (YYYY-MM-DD)" >&2
  exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
  jq -n --arg err "gh not authenticated" '{error: $err}'
  exit 1
fi

gh_user=$(gh api user -q .login 2>/dev/null || echo "")

BOT_LOGINS='["dependabot[bot]","renovate[bot]","github-actions[bot]","renovate-bot","dependabot","renovate","github-actions"]'

# --- Base queries (use --updated to capture anything that moved; classify with jq) ---

authored_raw=$(gh search prs \
  --owner "$org" \
  --author "@me" \
  --updated "${since}..${until_date}" \
  --limit 100 \
  --json number,title,state,url,repository,createdAt,updatedAt,closedAt,author,isDraft \
  2>/dev/null || echo '[]')

reviewed_raw=$(gh search prs \
  --owner "$org" \
  --reviewed-by "@me" \
  --updated "${since}..${until_date}" \
  --limit 100 \
  --json number,title,state,url,repository,createdAt,updatedAt,closedAt,author \
  2>/dev/null || echo '[]')

issues_raw=$(gh search issues \
  --owner "$org" \
  --author "@me" \
  --created "${since}..${until_date}" \
  --limit 100 \
  --json number,title,state,url,repository,createdAt,updatedAt,author \
  2>/dev/null || echo '[]')

# --- Bot filter (in jq) ---

bot_filter='
  if $filter_bots then
    map(select((.author // {}) as $a | ($bots | index($a.login // "")) | not))
  else . end
'

authored=$(echo "$authored_raw" | jq --argjson bots "$BOT_LOGINS" --argjson filter_bots "$filter_bots" "$bot_filter")
reviewed=$(echo "$reviewed_raw" | jq --argjson bots "$BOT_LOGINS" --argjson filter_bots "$filter_bots" "$bot_filter")
issues_opened=$(echo "$issues_raw" | jq --argjson bots "$BOT_LOGINS" --argjson filter_bots "$filter_bots" "$bot_filter")

# --- Classify authored PRs by state + closedAt-in-window ---

classify='
  def in_window($at):
    ($at // "") as $a
    | ($a != "") and ($a >= ($since + "T00:00:00Z")) and ($a <= ($until + "T23:59:59Z"));
  {
    prs_merged:            [ .[] | select(.state == "merged")             | select(in_window(.closedAt)) ],
    prs_open:              [ .[] | select(.state == "open") ],
    prs_closed_not_merged: [ .[] | select(.state == "closed")             | select(in_window(.closedAt)) ]
  }
'

classified=$(echo "$authored" | jq --arg since "$since" --arg until "$until_date" "$classify")

prs_merged=$(echo            "$classified" | jq '.prs_merged')
prs_open=$(echo              "$classified" | jq '.prs_open')
prs_closed_not_merged=$(echo "$classified" | jq '.prs_closed_not_merged')

# --- Reviewed: keep all that moved in window (state is informational) ---
prs_reviewed=$(echo "$reviewed" | jq '.')

# --- Push events → branches the user pushed to (payload commit counts are nulled
#     by the events API at large scale, so we only use this for branch/repo discovery). ---

events=$(gh api "users/${gh_user}/events?per_page=100" 2>/dev/null || echo '[]')

push_events=$(echo "$events" | jq --arg since "$since" --arg until "$until_date" --arg org "$org" '
  def in_window($at): ($at >= ($since + "T00:00:00Z")) and ($at <= ($until + "T23:59:59Z"));
  [ .[]
    | select(.type == "PushEvent")
    | select(in_window(.created_at))
    | select((.repo.name // "") | startswith($org + "/"))
    | {
        repo:    .repo.name,
        branch:  ((.payload.ref // "") | sub("refs/heads/"; "")),
        created_at: .created_at
      }
  ]
  | group_by(.repo + "|" + .branch)
  | map({
      repo:       .[0].repo,
      branch:     .[0].branch,
      pushes:     length,
      last_push:  (map(.created_at) | max)
    })
  | sort_by(-.pushes)
')

# --- Accurate commit counts: query each active repo's commits endpoint with author+window. ---

active_repos=$(jq -n \
  --argjson pushes "$push_events" \
  --argjson authored "$authored" \
  '
    ( [$pushes[]?.repo] + [$authored[]?.repository.nameWithOwner] )
    | map(select(. != null and . != ""))
    | unique
  ')

commits_by_repo="[]"
while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  n=$(gh api "repos/${repo}/commits?author=${gh_user}&since=${since}T00:00:00Z&until=${until_date}T23:59:59Z&per_page=100" \
      -q 'length' 2>/dev/null || echo 0)
  commits_by_repo=$(echo "$commits_by_repo" | jq --arg repo "$repo" --argjson n "$n" '. + [{repo: $repo, count: $n}]')
done < <(echo "$active_repos" | jq -r '.[]')

commits_by_repo=$(echo "$commits_by_repo" | jq 'map(select(.count > 0)) | sort_by(-.count)')
total_commits=$(echo "$commits_by_repo" | jq '[.[] | .count] | add // 0')

# --- Final JSON ---

jq -n \
  --arg gh_user "$gh_user" \
  --arg org "$org" \
  --arg since "$since" \
  --arg until "$until_date" \
  --argjson prs_merged "$prs_merged" \
  --argjson prs_open "$prs_open" \
  --argjson prs_closed_not_merged "$prs_closed_not_merged" \
  --argjson prs_reviewed "$prs_reviewed" \
  --argjson issues_opened "$issues_opened" \
  --argjson push_events "$push_events" \
  --argjson commits_by_repo "$commits_by_repo" \
  --argjson total_commits "$total_commits" \
  '{
    gh_user:  $gh_user,
    org:      $org,
    window:   { start: $since, end: $until },
    counts: {
      prs_merged:             ($prs_merged             | length),
      prs_open:               ($prs_open               | length),
      prs_closed_not_merged:  ($prs_closed_not_merged  | length),
      prs_reviewed:           ($prs_reviewed           | length),
      issues_opened:          ($issues_opened          | length),
      commits:                $total_commits,
      repos_touched:          ($commits_by_repo        | length)
    },
    prs_merged:             $prs_merged,
    prs_open:               $prs_open,
    prs_closed_not_merged:  $prs_closed_not_merged,
    prs_reviewed:           $prs_reviewed,
    issues_opened:          $issues_opened,
    commits_by_repo:        $commits_by_repo,
    push_events:            $push_events
  }'
