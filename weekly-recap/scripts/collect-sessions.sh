#!/usr/bin/env bash
# Collect Claude Code session signals for /weekly-recap.
# Reads JSONL transcripts under $CLAUDE_PROJECTS_DIR (default ~/.claude/projects),
# keeps sessions whose first user-message timestamp falls in the window,
# and emits a JSON summary grouped by working directory.
#
# Usage: collect-sessions.sh --since YYYY-MM-DD --until YYYY-MM-DD
#
# Requires: jq.

set -euo pipefail

for tool in jq find wc tail grep; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "weekly-recap/collect-sessions: missing required tool: $tool" >&2
    exit 2
  fi
done

since=""
until_date=""
base_dir="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)     since="$2"; shift 2 ;;
    --since=*)   since="${1#--since=}"; shift ;;
    --until)     until_date="$2"; shift 2 ;;
    --until=*)   until_date="${1#--until=}"; shift ;;
    --dir)       base_dir="$2"; shift 2 ;;
    --dir=*)     base_dir="${1#--dir=}"; shift ;;
    *)           shift ;;
  esac
done

if [[ -z "$since" || -z "$until_date" ]]; then
  echo "weekly-recap/collect-sessions: --since and --until are required (YYYY-MM-DD)" >&2
  exit 2
fi

if [[ ! -d "$base_dir" ]]; then
  jq -n \
    --arg base "$base_dir" \
    --arg since "$since" \
    --arg until "$until_date" \
    '{
      window: {start: $since, end: $until},
      error:  ("base dir not found: " + $base),
      counts: {sessions: 0, projects: 0},
      sessions_by_project: {}
    }'
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
: > "$tmp"

while IFS= read -r f; do
  [[ -z "$f" ]] && continue

  # Find the first real user message. Skip bookkeeping entries injected by slash
  # commands and the built-in bash-input shortcut; those aren't prose the user
  # typed as intent.
  first_user=$(grep '"type":"user"' "$f" 2>/dev/null \
    | grep -Ev '<local-command-|<command-name>|<command-message>|<bash-input>|<bash-stdout>|<bash-stderr>' \
    | head -1 \
    || true)
  [[ -z "$first_user" ]] && continue

  record=$(echo "$first_user" | jq -c --arg path "$f" '
    . as $r
    | {
        session_id:  ($r.sessionId // ""),
        cwd:         ($r.cwd // ""),
        project_name:($r.cwd // "" | split("/") | last),
        slug:        ($r.slug // ""),
        first_prompt: (
          ($r.message // {}).content as $c
          | if ($c | type) == "string" then $c
            elif ($c | type) == "array" then
              ([$c[] | select(.type? == "text") | (.text // "")] | join(" "))
            else "" end
        ),
        started_at: ($r.timestamp // ""),
        file: $path
      }
  ' 2>/dev/null || true)

  [[ -z "$record" ]] && continue

  started_at=$(echo "$record" | jq -r '.started_at')
  started_date="${started_at%%T*}"
  [[ -z "$started_date" ]] && continue
  if [[ "$started_date" < "$since" ]]; then continue; fi
  if [[ "$started_date" > "$until_date" ]]; then continue; fi

  size_lines=$(wc -l < "$f" | tr -d ' ')
  last_line=$(tail -1 "$f" 2>/dev/null || echo '')
  ended_at=""
  if [[ -n "$last_line" ]]; then
    ended_at=$(echo "$last_line" | jq -r '.timestamp // ""' 2>/dev/null || echo "")
  fi

  echo "$record" | jq -c \
    --argjson size "$size_lines" \
    --arg ended "$ended_at" \
    '. + {
       size_lines: $size,
       ended_at:   $ended,
       first_prompt: (.first_prompt | gsub("\\s+"; " ") | if length > 240 then .[0:240] + "..." else . end)
     }' >> "$tmp"
done < <(find "$base_dir" -type f -name '*.jsonl' -maxdepth 2 2>/dev/null)

jq -s --arg since "$since" --arg until "$until_date" '
  . as $all
  | ( $all
      | group_by(.cwd // "unknown")
      | map( { (.[0].cwd // "unknown"): (sort_by(.started_at) | reverse) } )
      | add // {}
    ) as $grouped
  | {
      window: {start: $since, end: $until},
      counts: {
        sessions: ($all | length),
        projects: ($grouped | keys | length),
        total_lines: ([$all[] | .size_lines] | add // 0)
      },
      sessions_by_project: $grouped
    }
' "$tmp"
