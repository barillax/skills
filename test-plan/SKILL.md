---
name: test-plan
description: Generate a testing plan for the current branch's changes. Analyzes the diff against the base branch and produces specific manual and automated testing steps. Use when preparing a PR, reviewing changes, or planning QA.
context: fork
agent: Explore
---

Generate a structured testing plan for the changes on this branch.

## Context

Base branch: `$ARGUMENTS` (default: `main`)

### Changed files

```!
git diff ${ARGUMENTS:-main}...HEAD --stat 2>/dev/null || git diff --stat
```

### Commit history

```!
git log ${ARGUMENTS:-main}...HEAD --oneline 2>/dev/null || echo "(no commits yet — uncommitted changes only)"
```

### Full diff

```!
git diff ${ARGUMENTS:-main}...HEAD 2>/dev/null | head -500 || git diff | head -500
```

## Instructions

Analyze the diff above and produce a testing plan. Categorize the changes first:

- **UI**: Component changes, styling, layout
- **Backend**: API endpoints, queries, mutations, actions, schema changes (Convex / Workers / server routes)
- **Config/Deps**: Package updates, build config, environment
- **Tests**: New or modified test files
- **Docs**: Documentation changes

Then output the plan in this exact format:

### Smoke Tests

High-level checks that the app still works:

- List 2-4 things to verify (app loads, auth flow, core navigation)

### Feature-Specific Tests

Steps tied directly to the changes in this diff:

- Be specific — reference actual components, screens, or functions changed
- Include expected behavior for each step
- Cover both happy path and basic error scenarios

### Edge Cases

Things that could break based on what was changed:

- Cross-component dependencies
- Platform differences (iOS vs Android vs web)
- Dark mode / accessibility implications
- State management edge cases

### Automated Test Coverage

- Which changed files have corresponding test files?
- Which changes lack test coverage?
- Suggest specific test cases that should be added (if any)

Keep the plan concise and actionable. Focus on what a reviewer or QA tester actually needs to verify.
