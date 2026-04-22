#!/usr/bin/env bash
# Emit a single deterministic JSON document describing the state of the PR
# attached to the current branch. This is the single source of truth for
# /babysit — phases 1-5 of the skill read only this script's output.
#
# Requires: gh (authenticated), jq, git.
# Exit status: 0 on success (including "no PR" case). Non-zero only for
# unexpected errors (missing deps, gh auth failure, etc.).

set -euo pipefail

for tool in gh jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "babysit/status: missing required tool: $tool" >&2
    exit 2
  fi
done

branch=$(git rev-parse --abbrev-ref HEAD)

if ! pr_json=$(gh pr view --json number,url,state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefName,baseRefName,statusCheckRollup 2>/dev/null); then
  jq -n --arg b "$branch" '{branch:$b, pr_number:null, error:"no_pr_for_branch"}'
  exit 0
fi

repo_json=$(gh repo view --json owner,name)
owner=$(jq -r '.owner.login' <<<"$repo_json")
name=$(jq -r '.name' <<<"$repo_json")
number=$(jq -r '.number' <<<"$pr_json")

# Unresolved review threads: only available via GraphQL (REST exposes comments
# but not the `isResolved` flag). We pull all threads, filter to unresolved
# non-outdated ones, and keep just the first comment of each for context.
threads_json=$(gh api graphql \
  -F owner="$owner" \
  -F name="$name" \
  -F number="$number" \
  -f query='
    query($owner:String!, $name:String!, $number:Int!) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$number) {
          reviewThreads(first:100) {
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              comments(first:1) {
                nodes {
                  author { login }
                  body
                  url
                }
              }
            }
          }
        }
      }
    }' 2>/dev/null || echo '{}')

# Merge the two payloads into the schema the SKILL.md phases consume.
jq -n \
  --arg branch "$branch" \
  --arg repo "$owner/$name" \
  --argjson pr "$pr_json" \
  --argjson threads "$threads_json" '
  ($pr.statusCheckRollup // []) as $checks
  | (
      # Normalize, then dedupe by (name, workflow). When a CI workflow re-runs
      # — typically because GitHub Actions auto-cancels the prior run via
      # concurrency policy — both runs leave check entries on the PR. Without
      # this dedup, the cancelled jobs from the old run get classified as
      # FAILURE/CANCELLED forever and break all_green. We extract the GHA run
      # ID from the details URL (monotonic global counter) and keep the entry
      # with the highest ID per (name, workflow) group. Non-Actions checks
      # (external statuses) have no /runs/N/ pattern and fall through with
      # run_id=0 — they have no duplicates anyway, so the group has 1 element.
      [$checks[] | {
          name: (.name // .context // "unknown"),
          status: (.status // "UNKNOWN"),
          conclusion: (.conclusion // null),
          details_url: (.detailsUrl // .targetUrl // null),
          workflow: (.workflowName // null),
          run_id: (
            try (
              (.detailsUrl // .targetUrl // "")
              | capture("/runs/(?<id>[0-9]+)/")
              | .id
              | tonumber
            ) catch 0
          )
      }]
      | group_by([.name, .workflow])
      | map(sort_by(.run_id) | last)
    ) as $norm_checks
  | (
      [$norm_checks[] | select(
          (.conclusion // "") as $c
          | $c == "FAILURE" or $c == "CANCELLED" or $c == "TIMED_OUT" or $c == "ACTION_REQUIRED"
      )]
    ) as $failing
  | (
      [$norm_checks[] | select(
          (.status // "") as $s
          | ($s == "QUEUED" or $s == "IN_PROGRESS" or $s == "PENDING" or $s == "WAITING" or $s == "REQUESTED")
      )]
    ) as $pending
  | (
      ($threads.data.repository.pullRequest.reviewThreads.nodes // [])
      | map(select(.isResolved == false and .isOutdated == false))
      | map({
          id,
          path,
          line,
          author: (.comments.nodes[0].author.login // null),
          body: (.comments.nodes[0].body // ""),
          url: (.comments.nodes[0].url // null)
        })
    ) as $unresolved
  | {
      branch: $branch,
      repo: $repo,
      pr_number: $pr.number,
      pr_url: $pr.url,
      pr_state: $pr.state,
      pr_draft: $pr.isDraft,
      base_ref: $pr.baseRefName,
      mergeable: $pr.mergeable,
      merge_state_status: $pr.mergeStateStatus,
      review_decision: $pr.reviewDecision,
      checks: $norm_checks,
      failing_checks: $failing,
      pending_checks: $pending,
      unresolved_threads: $unresolved,
      all_green: (
        $pr.mergeable == "MERGEABLE"
        and ($failing | length) == 0
        and ($pending | length) == 0
        and ($unresolved | length) == 0
        and ($pr.reviewDecision // "") != "CHANGES_REQUESTED"
      )
    }'
