---
name: weekly-recap
description: Generate a Slack-ready weekly recap aimed at executive leadership (e.g. a startup CEO). Aggregates the last 7 days of Claude Code sessions, GitHub activity in a target org, Google Calendar, and Gmail; synthesizes an executive summary, focus areas, accomplishments, and next steps; runs an interactive sensitivity + clarification pass; and writes a paste-ready archive file. Default org is `fintentional`.
argument-hint: "[--since <YYYY-MM-DD>] [--until <YYYY-MM-DD>] [--org <org>] [--quiet] [--no-github] [--no-sessions] [--no-calendar] [--no-gmail]"
---

Produce a weekly recap for an executive audience. The reader is technical but busy: a startup CEO who wants transparency, evidence of progress, and just enough technical flavor to feel the shape of the week. Never name the reader in the output — the recap should read as a standalone update anyone senior could pick up.

## Phase 0 — Preflight

### 0a. Parse arguments

Inspect `$ARGUMENTS` for bare tokens and flags:

- `--quiet` — skip Phase 3 (interactive review). Recap synthesizes from raw signals only.
- `--no-github`, `--no-sessions`, `--no-calendar`, `--no-gmail` — disable that source. Degrade gracefully.
- `--since <YYYY-MM-DD>`, `--until <YYYY-MM-DD>` — override the window. Defaults: trailing 7 days ending today, inclusive.
- `--org <name>` — override the GitHub org (default `fintentional`).

Pass `$ARGUMENTS` through unchanged to the scripts — they ignore unknown flags.

### 0b. Run preflight

```bash
"${CLAUDE_SKILL_DIR}/scripts/preflight.sh" $ARGUMENTS
```

Parse the JSON. Record `window_start`, `window_end`, `gh_user`, `gh_authenticated`, `org_access`.

- If `gh_authenticated` is `false` AND `--no-github` is not set: stop and tell the user to run `gh auth login`, then re-run.
- If `org_access` is `false` AND `--no-github` is not set: warn that the target org isn't accessible and ask (via `AskUserQuestion`) whether to proceed org-less (skip GitHub) or abort.

### 0c. Check MCP auth (Gmail + Calendar)

Unless `--no-gmail` was passed, call `mcp__claude_ai_Gmail__authenticate` with no params. If the response indicates auth is required, surface the auth URL to the user, then call `mcp__claude_ai_Gmail__complete_authentication` with the code the user returns. Same pattern for `mcp__claude_ai_Google_Calendar__*`.

If the user declines to authenticate either one, treat it as `--no-<source>` for this run.

## Phase 1 — Collect (parallel)

Run the two bash collectors in parallel (single Bash message, both non-backgrounded — they finish in seconds). Write the raw outputs to `/tmp/` so they can be inspected later.

```bash
"${CLAUDE_SKILL_DIR}/scripts/collect-github.sh"   --since <window_start> --until <window_end> --org <org> > /tmp/wr-github-<window_end>.json
"${CLAUDE_SKILL_DIR}/scripts/collect-sessions.sh" --since <window_start> --until <window_end>              > /tmp/wr-sessions-<window_end>.json
```

Substitute the actual dates/org from preflight. Skip any script whose source was disabled by `--no-*`.

Concurrently, fetch Calendar + Gmail via MCP (unless disabled):

- **Calendar** — call `mcp__claude_ai_Google_Calendar__*` list-events over the window. Drop any event whose payload contains a non-empty `recurringEventId` — those are standups / 1:1s / other recurring commitments and add no signal. Keep: title, start time, duration (or end - start), attendee count, organizer. Write the filtered list to `/tmp/wr-calendar-<window_end>.json`.
- **Gmail** — query the user's **sent** messages and **threads they replied to** in the window. Use labels/filters available via the MCP. For each kept message, capture: subject, to-recipients (domain only is enough — don't save personal emails), thread length, and a 1-sentence snippet. Drop messages whose from-sender matches any newsletter/automation pattern:

  ```
  noreply@   no-reply@   notifications@   alerts@
  @stripe.com (alerts only)   @linkedin.com   @newsletter.*
  github-noreply   *-bot@
  ```

  Write the filtered list to `/tmp/wr-gmail-<window_end>.json`.

Parse all four JSON files. Note any missing (disabled or failed) sources — the recap will acknowledge gaps explicitly.

## Phase 2 — Synthesize

Read all four JSON blobs (`wr-github`, `wr-sessions`, `wr-calendar`, `wr-gmail`). You are now writing the recap.

### 2a. Group related items across sources

A single accomplishment often shows up in multiple feeds. Deduplicate before drafting:

- A Claude session in a project directory (`cwd`) whose name matches a repo's `nameWithOwner` tail, whose slug/first_prompt echoes a merged PR's title, is **one accomplishment**, not two. Cite the PR URL; use the session as evidence of depth.
- A calendar event paired with a matching email thread (same counterparty, same week) is **one external interaction**.
- Open PRs, in-flight branches from `push_events`, and the top session topics that didn't yet ship feed the **Next Week** section.

### 2b. Draft the four sections

Write each section in the order below. Skip any section that would have zero real items rather than padding it.

1. **Executive Summary** — 2 to 3 sentences. Frame the week's *theme*: what moved forward, why it matters. Confident, direct, no hedging. Include setbacks only if they changed direction ("tried X, pivoted to Y because Z"); if there were no real setbacks, don't invent one.

2. **By the numbers** — one italicized line, *only if* the week crossed the productivity threshold (any **one** of: ≥3 PRs merged, ≥15 commits, ≥5 sessions). Format:

   `_By the numbers: N PRs merged · M commits · K sessions across P projects._`

   Adjust or omit columns that don't apply. Below the threshold, omit the whole line — thin weeks shouldn't advertise their thinness.

3. **This week's focus** — 1 to 3 focus areas, each a short phrase followed by a 1-sentence elaboration. Infer themes from clusters across PRs + sessions (e.g., "Infrastructure scaffolding — stood up PlanetScale, Hyperdrive, and per-developer bootstrap so the team can onboard in minutes").

4. **Accomplishments** — bulleted. Each bullet: one concrete outcome + *why it matters* (business / team impact, not implementation trivia). Name the technology by its common name ("PlanetScale migration", "Cloudflare Worker hardening") — fine for a vibecoder CEO. Link PR titles where useful. Keep to 4-7 bullets; combine multiple PRs on the same theme into one bullet.

5. **Next week** — bulleted. Pull from: currently-open PRs (`prs_open`), active-but-unmerged branches (`push_events`), open session plans, and any calendar events signaling upcoming decisions. 3-5 items, each a sentence.

6. **Notes / watchouts** — optional. Include only if there's a real risk, blocker, or decision that needs exec visibility (external dependency slipping, a hiring decision, a compliance ask). Skip the section outright if empty.

### 2c. Tone + detail rules (follow strictly)

- **Confident, not performative.** "Shipped X, which unblocks Y" — not "I'm excited to share..."
- **Specific, not grandiose.** Name real systems; avoid adjectives like "robust", "scalable", "world-class".
- **No self-congratulation.** The evidence speaks.
- **Technical depth: medium.** Say "set up PlanetScale with separate app/migrator roles" — don't say "configured a Hyperdrive config binding pointing at a PlanetScale database with GRANT statements".
- **Don't reference the skill itself or Claude.** The output should read like the user wrote it.

### 2d. What *not* to include (automatic omission)

Drop any candidate item touching:

- Individual investor names, term sheet specifics, valuation numbers, equity details.
- Legal / compliance matters currently under review.
- Employee performance, hiring decisions before announcement, specific comp.
- Customer-specific negotiation terms or unannounced partnerships.
- Specific runway / burn figures (unless already routinely shared).

If an item *looks* like it could touch one of these and you're not certain, don't drop it silently — it goes into the sensitivity sweep in Phase 3.

## Phase 3 — Interactive review

Skip this phase entirely if `--quiet` was set. Otherwise, batch all clarifications into a **single `AskUserQuestion` call** with up to 4 questions. One call, multiple questions — don't drip-feed.

The 4 question slots, in priority order:

1. **Sensitivity** (multi-select) — scan the draft for trigger words: `investor`, `term sheet`, `valuation`, `acquisition`, `board`, `legal`, `compliance`, `counsel`, `runway`, any customer proper noun, any employee proper noun other than the user's own. Group every hit into one multi-select question with an option per hit: "Keep as-is", "Rephrase generically", "Omit". Default: "Rephrase generically" for any borderline case.

2. **Ambiguity** (single-select, 1 question covering the worst offender) — pick the single most cryptic accomplishment (session slug or PR title that doesn't convey the outcome) and ask: "This item — [slug/title] — what did you actually accomplish here?". Options: 2-3 plausible reframings + "I'll type it" (free-form).

3. **Missing signal** (single-select) — one question: "Anything from this week that doesn't show up in these signals? (verbal decisions, thinking time, external meetings, phone calls)". Options: "No, covered", "Yes — I'll add" (free-form), "Yes — but keep it out of the recap".

4. **Tone check** (single-select, optional — include only if the draft is notably thin or notably boastful) — show a one-line preview of the Executive Summary and ask: "Does this framing land?". Options: "Yes", "Too self-congratulatory", "Too humble", "I'll rewrite".

If there are zero sensitivity hits and zero cryptic items, skip Phase 3 entirely — don't ask questions just to ask.

Apply the answers:
- "Omit" items — remove from the draft.
- "Rephrase generically" — rewrite to drop the specific name/number but keep the outcome (e.g., "briefed a lead investor on Q2 plan" → "briefed leadership stakeholders on Q2 plan").
- Free-form additions — integrate into the most relevant section, not a separate "extras" block.

## Phase 4 — Format + output

### 4a. Convert to Slack mrkdwn

Slack doesn't render standard Markdown. Transform:

| Markdown → Slack mrkdwn |
|---|
| `**bold**` → `*bold*` |
| `*italic*` → `_italic_` |
| `[text](url)` → `<url\|text>` |
| `# Heading`, `## Heading`, `### Heading` → `*Heading*` (single bold line, blank line before and after) |
| `- item`, `* item` → `• item` |
| inline `` `code` `` — unchanged |
| `> quote` — unchanged |

Do not emit any `**`, any `##`, or any `[text](url)` pattern — those render as literal characters in Slack. Do not add emojis unless the user explicitly requests them.

### 4b. Structure

```
*Weekly Recap — <Mon DD>–<Mon DD, YYYY>*

*Executive Summary*
<2–3 sentences>

_By the numbers: ..._        ← conditional, omit if under threshold

*This Week's Focus*
• *<Focus area>* — <1-sentence elaboration>

*Accomplishments*
• <Bullet + why it matters> <url|PR title>
• ...

*Next Week*
• <Priority>
• ...

*Notes*                      ← conditional, omit if empty
• <Risk or decision>

_Archived at ~/Documents/weekly-recaps/<YYYY-MM-DD>.md · raw signals at /tmp/wr-*.json_
```

Windows render like `Apr 17–23, 2026` (no year on the first date if same year). One blank line between sections.

### 4c. Write + display

```bash
mkdir -p "$HOME/Documents/weekly-recaps"
```

Then use the `Write` tool to save the final mrkdwn to `~/Documents/weekly-recaps/<window_end>.md` (the `until` date in `YYYY-MM-DD` form).

Print the full recap to chat — the user copies from there into Slack. Do not wrap it in a code block (Slack mrkdwn doesn't survive a round-trip through a ` ``` ` fence).

End with a one-line footer to the user (outside the recap text):

> Recap saved to `~/Documents/weekly-recaps/<date>.md`. Raw signals at `/tmp/wr-*.json` if you want to sanity-check.

## Guarantees and non-goals

- **Idempotent for read-only work.** Re-running the same window produces the same collected signals; synthesis may vary slightly by design.
- **Never posts to Slack directly (v1).** The user reviews and pastes.
- **Never invents signals.** If a source is disabled or empty, the recap says so (quietly, in the Notes section only if material).
- **Sensitivity defaults to cautious.** When in doubt, the sensitivity sweep asks; borderline items default to "rephrase", not "include".
- **Single author assumption.** All signals are scoped to the authenticated user.
