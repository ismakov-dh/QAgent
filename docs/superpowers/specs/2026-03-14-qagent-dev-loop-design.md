# QAgent — Dev Loop, Live Brainstorming & Branch-Aware Test Management

**Date:** 2026-03-14
**Status:** Draft
**Builds on:** [2026-03-12-qagent-plugin-design.md](./2026-03-12-qagent-plugin-design.md)

## Overview

This spec extends QAgent from a one-shot test runner into a continuous testing companion that lives alongside the development workflow. Three interconnected features:

1. **Changelog auto-detection** — QAgent derives changelog from git history, including cross-repo sources (e.g., backend changes affecting frontend)
2. **Live brainstorming** (`/qagent:explore`) — collaborative browser exploration to discover test cases interactively
3. **Branch-aware test management** (`/qagent:merge`) — test cases discovered on feature branches are tagged with metadata and merged into the main test suite with deduplication

The development loop becomes: develop → push → CI runs `/qagent:test` (auto-changelog from git) → discovers + runs test cases → proposals staged or auto-accepted → developer reviews → merges test cases with code.

Locally, the developer can run `/qagent:explore` for interactive brainstorming and `/qagent:test` for on-demand testing. Both write discovered test cases to `qagent.json` with branch metadata. Before merging the feature branch, `/qagent:merge` handles deduplication and scope classification.

## Flow Metadata Schema

Every flow in `qagent.json` gets optional metadata fields:

```json
{
  "name": "checkout-validation",
  "role": "user",
  "scope": "general",
  "branch": "feat/billing-redesign",
  "discovered_by": "explore",
  "discovered_at": "2026-03-14T10:30:00Z",
  "steps": [...]
}
```

| Field | Type | Values | Default | Purpose |
|-------|------|--------|---------|---------|
| `scope` | string | `"general"` \| `"feature"` | `"general"` | General flows apply everywhere. Feature flows are specific to the branch's work. |
| `branch` | string | any | current branch | Which branch discovered this flow. |
| `discovered_by` | string | `"config"` \| `"test"` \| `"explore"` | `"config"` | How the flow was added — manually written, discovered by test run, or discovered during brainstorming. |
| `discovered_at` | string | ISO 8601 timestamp | null | When the flow was discovered. Null for manually written flows. |

**Backward compatibility:** Existing flows without metadata are treated as `scope: "general"`, `discovered_by: "config"`. Nothing breaks.

## Changelog Auto-Detection

### Problem

Currently, `changelog` must be provided manually — either as a string in `qagent.json` or as a CLI argument. In CI, nobody is typing a changelog. On feature branches, the relevant changes are already in git.

### Solution

The `changelog` config field supports three shapes:

**String (current behavior):**
```json
{
  "changelog": "Added billing page, fixed login redirect"
}
```

**Object with sources:**
```json
{
  "changelog": {
    "sources": [
      { "type": "git", "path": "." },
      { "type": "git", "path": "../backend" },
      { "type": "url", "url": "https://api.example.com/changelog.json" },
      { "type": "text", "content": "Manual notes here" }
    ]
  }
}
```

**Omitted entirely:** Defaults to `[{ "type": "git", "path": "." }]`.

### Source types

| Type | Resolution |
|------|-----------|
| `git` | Find merge-base with default branch (`git merge-base HEAD main`). Collect commit messages (`git log --oneline {base}..HEAD`) and changed files (`git diff --name-only {base}..HEAD`). If on main with no merge base, use last 5 commits. |
| `url` | HTTP GET the URL, use response body as changelog text. Useful for backend services that publish release notes. |
| `text` | Inline text, used as-is. |

### Priority

Explicit `changelog` string > `changelog.sources` object > git auto-detect fallback.

### Combined output

All sources are merged into one structured changelog string before Phase 2 (plan generation):

```
[git: .]
Commits since main:
- abc1234 feat: add billing page
- def5678 fix: login redirect on expired session
Changed files: src/billing/*, src/auth/login.ts

[git: ../backend]
Commits since main:
- 789abcd chore: change /api/invoices response to include tax_id
Changed files: api/invoices.go

[url: https://api.example.com/changelog.json]
v2.3.1: Added tax_id to invoice response
```

This combined changelog drives flow inference — QAgent sees both frontend and backend changes and can infer cross-boundary test cases (e.g., "verify billing page renders the new tax_id field").

## `/qagent:explore` — Live Brainstorming Skill

### Purpose

Collaborative free-roaming browser exploration to discover test cases. The agent and operator take turns driving the browser. The agent observes the app like a QA tester and proposes test cases based on what it sees.

### Invocation

```
/qagent:explore [config-path]
```

If no arguments, uses `qagent.json` discovery (same as `/qagent:test`).

### Lifecycle

```
Start → Load config → Resolve secrets → Check browser → Open page → Explore loop → Wrap up → Save
```

### Startup

Same as `/qagent:test` Phase 1, minus trigger detection (explore is always interactive):
1. Load config
2. Resolve secrets (for auth if needed)
3. Check browser availability (Chrome DevTools or Playwright MCP)
4. Check app reachability
5. Open a browser page to the app URL

### Explore loop

1. **Agent navigates** to the app URL, describes what it sees — page structure, key elements, interactive components, navigation options
2. **Agent proposes** areas to explore: "I see a sidebar with Settings, Billing, Team. Where should we start?"
3. **Operator directs** — "go to billing" / "click that dropdown" / "what happens if you submit an empty form?"
4. **Agent executes** the action, takes a screenshot, describes the result
5. **Agent suggests test cases** based on observations:
   ```
   I notice the billing form has no client-side validation on the card number field.

   Proposed test case: "submit-invalid-card"
     Steps:
       - navigate to /billing
       - enter "abc" in card number field
       - click submit
       - verify: error message shown for invalid card
     Scope: general

   Add this? [y/n/edit]
   ```
6. If accepted, the flow is queued with metadata:
   - `discovered_by: "explore"`
   - `branch`: current git branch
   - `scope`: as proposed (operator can change via `edit`)
   - `discovered_at`: ISO timestamp
7. **Periodic check-in** — after covering ~5 pages or interactions in one area: "We've covered the billing section — 3 test cases found. Go deeper, explore somewhere else, or wrap up?"

### Agent behavior during exploration

- **Observe actively** — after every page load, look for: missing validation, broken states, empty states, error handling gaps, edge cases (special characters, long strings, rapid clicks), accessibility issues
- **Think like a QA tester** — "what could go wrong here?" for every interactive element
- **Don't overwhelm** — max 2 proposals between operator interactions. Queue observations and present the best ones.
- **Screenshot every significant state** — save to `qagent-reports/explore/` for reference
- **Context awareness** — remember what's been explored in this session. Don't re-propose the same area or similar test cases.

### Wrap up

When the operator says "done", "wrap up", "that's enough", or similar:

1. **Summary:**
   ```
   Explore session complete.
   Explored: billing, settings, team management
   Discovered: 7 test cases (5 general, 2 feature-scoped)
   ```
2. **List all accepted cases** with their scope tags
3. **Scope review:** "Any of these need their scope changed before saving?"
4. **Write** accepted flows to `qagent.json` with full metadata
5. **Close** the browser page

### What it does NOT do

- Does not execute existing flows — that's `/qagent:test`
- Does not run in CI — interactive only
- Does not modify existing flows — only discovers new ones
- Does not handle auth automatically — if the operator wants to test an authenticated area, they direct the agent to log in first (agent uses auth credentials from config)

## `/qagent:merge` — Test Case Merging Skill

### Purpose

Merge discovered test cases from a feature branch into a target branch's `qagent.json`. Handles deduplication, scope classification, and interactive approval.

### Invocation

```
/qagent:merge [target-branch]
```

Default target is `main`.

### Process

#### 1. Identify discovered flows

Read `qagent.json` from the current branch. Filter flows that have `branch` metadata matching the current branch — these are flows discovered during this branch's development.

If no flows have `branch` metadata matching, check for flows with `discovered_at` timestamps after the branch creation date as a fallback.

#### 2. Read target flows

Load the target branch's `qagent.json`:
```bash
git show {target-branch}:qagent.json
```

If the file doesn't exist on the target branch, treat it as an empty flows array.

#### 3. Classify

For each discovered flow:

| Scope | Action |
|-------|--------|
| `"general"` | Propose for merge — this flow is useful everywhere |
| `"feature"` | Ask: "This flow tests {feature}. Will it still be relevant after merge? [y/n/re-scope]" If yes → re-scope to `"general"` and include. If no → drop. |

#### 4. Deduplicate

Compare each flow proposed for merge against the target's existing flows:

- **Same `name`** → skip, already exists. Inform: "'{name}' already exists in {target}, skipping."
- **Different name but similar steps** (overlapping intents, >70% step similarity by intent text) → flag: "'{name}' looks similar to existing '{existing-name}'. Replace / Skip / Add both?"

#### 5. Present merge plan

```
Merging test cases: feat/billing-redesign → main

Add (general):
  1. "submit-invalid-card" — 4 steps, discovered by explore
  2. "invoice-tax-id-display" — 3 steps, discovered by test

Needs decision (feature-scoped):
  3. "billing-redesign-layout" — feature-specific. Keep? [y/n]

Possible duplicate:
  4. "checkout-flow" — similar to existing "purchase-flow". Replace / Skip / Add both?

Apply merge? [y/n]
```

#### 6. Apply

Write the merged flows into `qagent.json`. Two modes depending on workflow:

- **If on the feature branch (pre-merge):** Write to current branch's `qagent.json`. The flows will merge with the code when the branch merges. This is the typical flow — run `/qagent:merge main` before creating the PR.
- **If on the target branch (post-merge):** Write directly to the target's `qagent.json`.

#### 7. Clean up metadata

Merged flows get their metadata updated:
- `branch` → cleared (they now belong to the target branch)
- `discovered_by` → preserved for history
- `discovered_at` → preserved for history
- `scope` → set to `"general"` (feature-scoped flows were either re-scoped or dropped)

### What it does NOT do

- Does not merge code — only `qagent.json` flows
- Does not auto-run without approval — always interactive
- Does not handle merge conflicts in non-flow config (`app`, `auth`, `secrets`, `reporters`) — those are manual
- Does not run in CI — it's a pre-merge developer tool

## Changes to Existing Skills

### `/qagent:test`

Three additions:

1. **Changelog auto-detection** (Phase 1, after config load): If no changelog provided, derive from git. If `changelog` is an object with sources, resolve each source. See "Changelog Auto-Detection" section above.

2. **Flow metadata on discovery** (Phase 3.4 learning loop + Phase 4 CI learning): Every discovered flow gets metadata:
   - `scope` — ask the user in interactive mode; default `"general"` in CI
   - `branch` — current git branch
   - `discovered_by` — `"test"`
   - `discovered_at` — ISO timestamp

3. **CI auto-changelog**: In CI, the pipeline doesn't need to pass changelog manually. QAgent detects it's on a branch, diffs against main, and builds the changelog. For cross-repo changelogs, configure `changelog.sources` in `qagent.json`.

### `/qagent:plan`

One addition:

1. **Changelog auto-detection**: Same logic as `/qagent:test`. If no changelog provided, derive from git. This way `/qagent:plan` can preview inferred flows without manual changelog input.

### `/qagent:report`

No changes.

## Updated Config Shape

New/changed fields in `qagent.json`:

```json
{
  "changelog": {
    "sources": [
      { "type": "git", "path": "." },
      { "type": "git", "path": "../backend" }
    ]
  },
  "flows": [
    {
      "name": "example-flow",
      "role": "user",
      "scope": "general",
      "branch": "feat/billing",
      "discovered_by": "explore",
      "discovered_at": "2026-03-14T10:30:00Z",
      "steps": [...]
    }
  ]
}
```

All new fields are optional. Existing configs work without changes.

## Skill Inventory

| Skill | Status | Trigger |
|-------|--------|---------|
| `/qagent:test` | Existing — extended | Manual + CI |
| `/qagent:plan` | Existing — extended | Manual + CI |
| `/qagent:report` | Existing — no changes | Manual + CI |
| `/qagent:explore` | **New** | Manual only |
| `/qagent:merge` | **New** | Manual only |
| `/qagent:init` | **Future** — not in this design | Manual only |

## Non-Goals (this iteration)

- `/qagent:init` — config scaffolding skill (separate design)
- `/qagent:watch` — watcher mode (dropped; CI + manual invocation covers the use case)
- Visual regression testing (screenshot diffing)
- OAuth / MFA / CAPTCHA handling
- Multi-app testing in a single run
- Automatic PR creation with test cases
