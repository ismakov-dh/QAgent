# QAgent Dev Loop, Brainstorming & Branch-Aware Merge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend QAgent from a one-shot test runner into a continuous testing companion with changelog auto-detection from git, live browser brainstorming (`/qagent:explore`), and branch-aware test case merging (`/qagent:merge`).

**Architecture:** Two new skills (explore, merge), modifications to two existing skills (test, plan), updated config template. All skills are Claude Code plugin SKILL.md files — markdown prompts with YAML frontmatter. No code files — only markdown and JSON. Flow metadata (`scope`, `branch`, `discovered_by`, `discovered_at`) is added to the flow schema in `qagent.json`.

**Tech Stack:** Claude Code plugin system (SKILL.md, agents/*.md), MCP browser tools, git CLI, bash, JSON

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `skills/test/SKILL.md` | Modify | Add changelog auto-detection (Phase 1.6), flow metadata on discovery, flow name uniqueness check |
| `skills/plan/SKILL.md` | Modify | Add changelog auto-detection to plan generation |
| `skills/explore/SKILL.md` | Create | New skill — live collaborative browser brainstorming |
| `skills/merge/SKILL.md` | Create | New skill — branch-aware test case merging |
| `templates/qagent-example.json` | Modify | Add flow metadata fields, changelog sources example |
| `docs/superpowers/specs/2026-03-14-qagent-dev-loop-design.md` | Reference | Design spec (read-only during implementation) |

---

## Task 1: Update example config with new fields

**Files:**
- Modify: `templates/qagent-example.json`

- [ ] **Step 1: Add flow metadata and changelog sources to example config**

Update the example config to show all new fields. Add metadata to the example flow and add a `changelog.sources` example. The example should demonstrate both the simple string changelog and the sources object (commented or as an alternative).

```json
{
  "app": {
    "name": "My Web App",
    "url": "https://staging.example.com",
    "description": "Brief description of what the app does and its main user flows"
  },
  "auth": {
    "user": {
      "username": "testuser@example.com",
      "password": "secret:USER_PASSWORD"
    },
    "admin": {
      "username": "admin@example.com",
      "password": "secret:ADMIN_PASSWORD",
      "cookie": ""
    }
  },
  "secrets": {
    "provider": "env",
    "path": "/var/run/secrets/qagent"
  },
  "changelog": {
    "sources": [
      { "type": "git", "path": "." },
      { "type": "git", "path": "../backend" }
    ]
  },
  "flows": [
    {
      "name": "example-login-flow",
      "role": "user",
      "scope": "general",
      "steps": [
        { "action": "login" },
        { "action": "verify", "expect": "dashboard is visible with welcome message" }
      ]
    }
  ],
  "browser": {
    "provider": "chrome-devtools"
  },
  "execution": {
    "strategy": "auto",
    "concurrency": 3
  },
  "checks": {
    "console": true,
    "network": true,
    "screenshotOnPass": false,
    "screenshotOnFail": true
  },
  "reporters": [
    { "type": "console" },
    { "type": "json", "path": "./qagent-reports/" }
  ],
  "timeouts": {
    "step": 30,
    "flow": 300,
    "session": 1800
  },
  "limits": {
    "max_inferred_flows": 5
  },
  "inference": true,
  "trigger": "auto",
  "learning": {
    "enabled": true,
    "mode": "interactive",
    "staging_path": "./qagent-proposed.json"
  }
}
```

- [ ] **Step 2: Validate JSON**

Run: `cat templates/qagent-example.json | python3 -m json.tool > /dev/null`
Expected: No output (valid JSON)

- [ ] **Step 3: Commit**

```bash
git add templates/qagent-example.json
git commit -m "feat: add flow metadata and changelog sources to example config"
```

---

## Task 2: Add changelog auto-detection to `/qagent:test`

**Files:**
- Modify: `skills/test/SKILL.md`

The spec requires a new Phase 1.6 after config loading that resolves the `changelog` field from multiple source types. This replaces the current assumption that changelog is always a plain string.

- [ ] **Step 1: Add Phase 1.6 — Resolve changelog**

Insert a new section after Phase 1.5 (Check app reachability) and before Phase 2 (Plan Generation). Add the following content to `skills/test/SKILL.md`:

```markdown
### 1.6 Resolve changelog

The `changelog` field drives flow inference in Phase 2. Resolve it based on its shape:

**If `changelog` is a string:** Use as-is (backward compatible).

**If `changelog` is an object with `sources`:** Resolve each source:

For each source in `changelog.sources`:
- **`type: "git"`**: Detect the default branch: run `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`. If that fails, try `main`, then `master` (check with `git rev-parse --verify {branch} 2>/dev/null`). If none exist, output error: "Could not determine default branch. Set it explicitly or run `git remote set-head origin --auto`." and exit with code 2.

  Find merge base: `git merge-base HEAD {default-branch}`. Collect commits and changed files:
  ```bash
  # Resolve path relative to qagent.json directory, not CWD
  cd "{qagent_json_dir}/{source.path}"
  BASE=$(git merge-base HEAD {default-branch})
  git log --oneline $BASE..HEAD
  git diff --name-only $BASE..HEAD
  ```
  If on the default branch with no merge base, use: `git log --oneline -5`

  Format as:
  ```
  [git: {path}]
  Commits since {default-branch}:
  - {commit lines}
  Changed files: {file list}
  ```

- **`type: "url"`**: Fetch with `curl -s -m 10 "{url}"`. If the request fails (non-2xx or timeout), log warning: "Changelog source {url} failed ({reason}), skipping." and continue to the next source.

- **`type: "text"`**: Use `content` as-is.

Combine all resolved sources into one changelog string, separated by blank lines.

**If `changelog` is omitted entirely:** Default to a single git source for the current repo:
```bash
# Same as type: "git" with path: "."
```

**Error handling:** If ALL sources fail or produce empty results, warn: "No changelog available — flow inference will be limited to config flows only." and proceed with an empty changelog string.
```

- [ ] **Step 2: Read the file and verify the section was inserted correctly**

Read `skills/test/SKILL.md` and verify Phase 1.6 appears between 1.5 and Phase 2.

- [ ] **Step 3: Update Phase 2 to reference resolved changelog**

In Phase 2 (Plan Generation), the current line 85 reads:

```
2. If inference is enabled (config `inference` is not `false`), generate inferred flows from the changelog:
```

Change "from the changelog:" to "from the resolved changelog (from Phase 1.6):"

- [ ] **Step 4: Commit**

```bash
git add skills/test/SKILL.md
git commit -m "feat: add changelog auto-detection to /qagent:test (Phase 1.6)"
```

---

## Task 3: Add flow metadata to `/qagent:test` learning loop

**Files:**
- Modify: `skills/test/SKILL.md`

The learning loop (Phase 3.4 and Phase 4) needs to write metadata on every discovered flow.

**Important distinction:** `discovered_by` (persisted in `qagent.json`, values: `"manual"` / `"test-run"` / `"explore-session"`) tracks how a flow was first created. This is different from the plan's `source` field (runtime only, values: `"config"` / `"inferred"`) which tracks whether a flow came from config or was inferred during this specific run. Do not conflate these two fields.

- [ ] **Step 1: Update Phase 3.4.1 — Add metadata to failure-based proposals**

In Phase 3.4.1 (Learn from failures), after step 3 ("Propose one or more changes"), add instructions that every proposed new flow must include metadata:

```markdown
Every proposed new flow must include metadata:
- `scope` — ask the user: "Is this test case general (applies everywhere) or specific to this feature branch? [general/feature]". Default to `"general"` if unclear.
- `branch` — current git branch (run `git branch --show-current`)
- `discovered_by` — `"test-run"`
- `discovered_at` — current ISO timestamp
```

- [ ] **Step 2: Update Phase 3.4.2 — Add metadata to inferred flow proposals**

In Phase 3.4.2 (Persist discovered test cases), update the proposal format to include metadata and scope question:

```markdown
For each inferred flow, propose it for permanent addition to the config:

```
Discovered test case: "{flow-name}" ({passed|failed})
  Source: inferred from changelog — "{reasoning}"
  Steps: {step count} steps
  Result: {pass/fail summary}
  Scope: general (change? [general/feature])

Add this test case to qagent.json for future runs? [y/n/edit]
```

If accepted, write with metadata:
- `scope` — as confirmed by user (default `"general"`)
- `branch` — current git branch
- `discovered_by` — `"test-run"`
- `discovered_at` — current ISO timestamp
```

- [ ] **Step 3: Add flow name uniqueness check to Phase 3.4.3**

In Phase 3.4.3 (Apply accepted proposals), before writing to `qagent.json`, add:

```markdown
Before writing each new flow, check for name collisions with existing flows in `qagent.json`. If a collision is found, ask the user to rename: "A flow named '{name}' already exists. Rename this one? [suggest: '{name}-2']". Wait for the user's response. If the user accepts the suggestion, use it. If they provide a different name, use that instead.
```

- [ ] **Step 4: Update Phase 4 — Add metadata to CI proposals**

In Phase 4 (Learning — CI modes), add to the staging file format that new flows include metadata fields, and note that `scope` defaults to `"general"` in CI (no interactive prompt):

```markdown
In CI mode, all discovered flows default to `scope: "general"`, `discovered_by: "test-run"`, `branch` from `git branch --show-current`, `discovered_at` from current timestamp.
```

- [ ] **Step 5: Read and verify all changes**

Read `skills/test/SKILL.md` sections 3.4.1, 3.4.2, 3.4.3, and Phase 4 to verify metadata instructions are present.

- [ ] **Step 6: Commit**

```bash
git add skills/test/SKILL.md
git commit -m "feat: add flow metadata to test learning loop (scope, branch, discovered_by)"
```

---

## Task 4: Add changelog auto-detection to `/qagent:plan`

**Files:**
- Modify: `skills/plan/SKILL.md`

Same changelog resolution logic as `/qagent:test` Phase 1.6, applied to the plan skill.

- [ ] **Step 1: Add changelog resolution to step 1 (Load config)**

After "If config file: read and parse the full JSON", add a new sub-step:

```markdown
   **Resolve changelog:**
   - If `changelog` is a string → use as-is
   - If `changelog` is an object with `sources` → resolve each source:
     - `type: "git"` → detect default branch (`git symbolic-ref refs/remotes/origin/HEAD`, fall back to `main`/`master`), find merge-base, collect commits + changed files. Path is relative to `qagent.json` directory.
     - `type: "url"` → `curl -s -m 10 "{url}"`. If fails, log warning and skip.
     - `type: "text"` → use `content` as-is.
   - If `changelog` is omitted → default to git auto-detect from current repo
   - If all sources fail → warn "No changelog available" and use empty string
   - Combine all sources into one changelog string for plan generation
```

- [ ] **Step 2: Update step 4 (Generate test plan) to reference resolved changelog**

In step 4 (Generate test plan), the "Inferred flows" section at line 59 currently reads:

```
   - Parse the changelog for bug fixes → generate 1 regression test flow per fix
```

Change "Parse the changelog" to "Parse the resolved changelog"

- [ ] **Step 3: Read and verify**

Read `skills/plan/SKILL.md` to verify changelog resolution appears in step 1.

- [ ] **Step 4: Commit**

```bash
git add skills/plan/SKILL.md
git commit -m "feat: add changelog auto-detection to /qagent:plan"
```

---

## Task 5: Create `/qagent:explore` skill

**Files:**
- Create: `skills/explore/SKILL.md`

This is the largest single task — a new skill for collaborative browser brainstorming.

- [ ] **Step 1: Create the skill directory**

```bash
mkdir -p skills/explore
```

- [ ] **Step 2: Write the SKILL.md**

Create `skills/explore/SKILL.md` with the full skill definition. Key sections from the spec:

```markdown
---
name: explore
description: Live collaborative browser exploration to discover test cases. Opens the app, navigates interactively with the operator, and proposes test cases based on observations.
argument-hint: [config-path]
allowed-tools: Read, Write, Bash, Grep, Glob, mcp__chrome-devtools__*, mcp__playwright__*
---

# QAgent Explore — Live Brainstorming

You are a QA tester exploring a web application collaboratively with the operator. Your job is to navigate the app, observe it critically, and propose test cases based on what you see. The operator directs where to go; you observe and suggest.

## Input

Arguments: `$ARGUMENTS`
- If a file path is provided, read it as the config file
- If no arguments, look for `qagent.json` in: (1) current directory, (2) nearest ancestor with `.git`

## Phase 1: Startup

### 1.1 Load config

Find and parse `qagent.json`. Config discovery order: (1) path passed as argument, (2) current working directory, (3) nearest ancestor directory containing `.git`. First match wins.

### 1.2 Resolve secrets

For every value in the config matching `secret:KEY`:
- If `secrets.provider` is `"file"` → read `{secrets.path}/{KEY}` (default path: `/var/run/secrets/qagent`)
- If `secrets.provider` is `"env"` → read env var `$KEY`
- If no `secrets` block → fall back to env var `$KEY`
- If any secret is missing → **STOP** and output error listing the unresolved keys. Exit with code 2.

**CRITICAL: Secret values must NEVER be logged or output.**

### 1.3 Check browser availability

Check which MCP browser tools are available:
- Look for `mcp__chrome-devtools__navigate_page` or similar Chrome DevTools tools
- Look for `mcp__playwright__*` tools
- If neither is available → **STOP** and output error:
  ```
  QAgent Error: No browser MCP server available.
  ```
  Exit with code 2.

The skill uses whichever browser MCP tools are available — not all namespaces need to be present.

### 1.4 Check app reachability

```bash
curl -s -o /dev/null -w "%{http_code}" -m 10 "{app_url}"
```

If not 2xx or 3xx → **STOP** with error. Exit with code 2.

### 1.5 Open browser page

Open a browser page to the app URL:

**Chrome DevTools MCP:**
1. Call `new_page` with `url` set to the app URL
2. Note the `pageId` for all subsequent browser actions
3. Call `select_page` with the `pageId`

**Playwright MCP:**
1. Use the equivalent page creation tool
2. Navigate to the app URL

### 1.6 Start session

Record the session start time. Calculate the session timeout deadline from `timeouts.session` (default 1800s = 30m).

Output:
```
QAgent Explore — {app name} ({url})
Session timeout: {timeout}m
Browser: {chrome-devtools|playwright}

Navigating to {url}...
```

## Phase 2: Explore Loop

### 2.1 Describe the current page

After the page loads, describe what you see:
- Page title and URL
- Main layout (header, sidebar, content area, footer)
- Key interactive elements (buttons, forms, links, dropdowns)
- Navigation options
- Any immediately visible issues (errors, broken images, console errors)

Propose 2-3 areas to explore: "I see [areas]. Where should we start?"

### 2.2 Operator interaction

Wait for the operator to direct you. They may:
- Tell you where to go: "go to billing", "click settings"
- Ask you to perform an action: "submit the form empty", "try logging out"
- Ask what you notice: "what else did you see?", "any issues?"
- Ask to wrap up: "done", "wrap up", "that's enough"

### 2.3 Execute and observe

When the operator gives a direction:
1. Call `select_page` with the page ID (before every browser action)
2. Perform the action (navigate, click, fill, etc.)
3. Take a screenshot and save to `qagent-reports/screenshots/explore-{timestamp}-{n}.png` (create directory if needed: `mkdir -p qagent-reports/screenshots`)
4. Describe what happened — what changed on the page, any errors, any unexpected behavior
5. Check for console errors (`list_console_messages`) and network errors (`list_network_requests`)

### 2.4 Propose test cases

After observing the page, think like a QA tester: "what could go wrong here?"

Look for:
- Missing validation (empty form submissions, invalid input)
- Broken states (what if the user is not authenticated? what if data is empty?)
- Error handling gaps (network errors, server errors)
- Edge cases (special characters, very long strings, rapid clicks)
- State change verification (does the action actually change the expected state?)
- Accessibility issues (missing labels, keyboard navigation)

When you spot something worth testing, propose a test case. Max 2 proposals between operator interactions — queue excess observations.

Format:
```
I notice {observation}.

Proposed test case: "{flow-name}"
  Steps:
    - {step 1}
    - {step 2}
    - ...
  Scope: {general|feature}

Add this? [y/n/edit]
```

If accepted:
- Queue the flow with metadata:
  - `scope`: as proposed (operator can change via `edit`)
  - `branch`: current git branch (run `git branch --show-current`)
  - `discovered_by`: `"explore-session"`
  - `discovered_at`: current ISO timestamp
- Convert the steps into the `qagent.json` flow format:
  ```json
  {
    "name": "{flow-name}",
    "role": "user",
    "scope": "{scope}",
    "branch": "{branch}",
    "discovered_by": "explore-session",
    "discovered_at": "{timestamp}",
    "steps": [
      { "action": "{step 1}" },
      { "action": "{step 2}", "expect": "{expectation if any}" }
    ]
  }
  ```

If the operator selects `edit`, let them modify the flow before accepting.

### 2.5 Periodic check-in

After covering ~5 pages or interactions in one area, check in:

```
We've covered {area} — {N} test cases found. Go deeper, explore somewhere else, or wrap up?
```

### 2.6 Session timeout

Track elapsed time. At 5 minutes before the session timeout, warn:

```
Session timeout approaching ({remaining}m left). Wrap up or extend?
```

If no response by the deadline, auto-wrap-up.

## Phase 3: Wrap Up

When the operator says "done" (or session timeout triggers):

### 3.1 Summary

```
Explore session complete.
Explored: {areas visited}
Discovered: {N} test cases ({M} general, {K} feature-scoped)
Duration: {time}
```

### 3.2 List discovered cases

List all accepted test cases with their scope:
```
  1. "{name}" ({scope}) — {step count} steps
  2. "{name}" ({scope}) — {step count} steps
  ...
```

### 3.3 Scope review

Ask: "Any of these need their scope changed before saving? [enter numbers to change, or 'ok' to proceed]"

### 3.4 Flow name uniqueness

Before writing, check each flow name against existing flows in `qagent.json`. If a collision is found, ask: "A flow named '{name}' already exists. Rename this one? [suggest: '{name}-2']"

### 3.5 Write to config

Read current `qagent.json`, append all accepted flows to the `flows` array, and write back. Only modify `flows` — never touch other config sections.

Output: "Saved {N} test cases to qagent.json."

### 3.6 Close browser page

Close the browser page used during exploration:

**Chrome DevTools MCP:**
- Call `close_page` with the `pageId`
- If it's the last page and can't be closed, navigate to `about:blank`

**Playwright MCP:**
- Use the equivalent close tool
- If no close tool, navigate to `about:blank`

## Important Rules

- **NEVER** log or output secret values
- Call `select_page` before EVERY browser action (Chrome DevTools has global state)
- Max 2 proposals between operator interactions — don't overwhelm
- Queue excess observations for later (present when asked or during wrap-up)
- Remember what's been explored — don't re-propose the same area
- Screenshots go to `qagent-reports/screenshots/explore-{timestamp}-{n}.png`
- Only modify `flows` in `qagent.json` — never other config sections
- **Auth:** If the operator wants to test an authenticated area, use the auth credentials from config to log in. Follow the same login procedure as the test skill (navigate to login page, fill credentials for the specified role).

## What This Skill Does NOT Do

- Does not execute existing flows — that's `/qagent:test`
- Does not run in CI — interactive only
- Does not modify existing flows — only discovers new ones
- Does not handle auth automatically — the operator must direct you to log in first
```

- [ ] **Step 3: Read and verify the file was created correctly**

Read `skills/explore/SKILL.md` and verify it has correct YAML frontmatter and all sections from the spec.

- [ ] **Step 4: Commit**

```bash
git add skills/explore/SKILL.md
git commit -m "feat: add /qagent:explore skill — live collaborative brainstorming"
```

---

## Task 6: Create `/qagent:merge` skill

**Files:**
- Create: `skills/merge/SKILL.md`

- [ ] **Step 1: Create the skill directory**

```bash
mkdir -p skills/merge
```

- [ ] **Step 2: Write the SKILL.md**

Create `skills/merge/SKILL.md` with the full skill definition:

```markdown
---
name: merge
description: Merge discovered test cases from a feature branch into a target branch's qagent.json. Handles deduplication, scope classification, and interactive approval.
argument-hint: [target-branch]
allowed-tools: Read, Write, Bash, Grep, Glob
---

# QAgent Merge — Branch-Aware Test Case Merging

You merge test cases discovered on a feature branch into a target branch's test suite. You handle deduplication, scope classification, and interactive approval.

## Input

Arguments: `$ARGUMENTS`
- If a branch name is provided, use it as the target branch
- If no arguments, detect the default branch:
  1. Try `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`
  2. Fall back to `main` (check with `git rev-parse --verify main 2>/dev/null`)
  3. Fall back to `master` (check with `git rev-parse --verify master 2>/dev/null`)
  4. If none exist, output error: "Could not determine target branch. Provide it as an argument: /qagent:merge <branch>" and stop.

## Phase 1: Pre-checks

### 1.1 Check dirty working tree

```bash
git diff --name-only -- qagent.json
git diff --cached --name-only -- qagent.json
```

If `qagent.json` has uncommitted changes, warn:
```
⚠ qagent.json has uncommitted changes. Continue anyway? [y/n]
```
If the user says no, stop.

### 1.2 Load current config

Read `qagent.json` from the current branch. Config discovery order: (1) current working directory, (2) nearest ancestor with `.git`.

### 1.3 Identify discovered flows

Get the current branch name:
```bash
git branch --show-current
```

Filter flows from `qagent.json` that have `branch` metadata matching the current branch name — these are flows discovered during this branch's development.

**Fallback:** If no flows match by `branch` field, find the merge-base commit date:
```bash
git log -1 --format=%cI $(git merge-base HEAD {target-branch})
```
Then check for flows with `discovered_at` timestamps after that date.

If no flows are found by either method:
```
No test cases discovered on this branch. Nothing to merge.
```
Stop.

### 1.4 Read target flows

Load the target branch's `qagent.json`:
```bash
git show {target-branch}:qagent.json 2>/dev/null
```

If that fails (branch not available locally):
```bash
git show origin/{target-branch}:qagent.json 2>/dev/null
```

If both fail, treat the target as having an empty `flows` array and inform the user:
```
Could not read qagent.json from {target-branch}. Treating target as empty (all flows will be added).
```

Parse the JSON and extract the `flows` array.

### 1.5 Check for non-flow config changes

Compare the current `qagent.json` against the target's version. If there are differences outside the `flows` array (e.g., `app.url`, `reporters`, `auth` changed), warn:
```
⚠ qagent.json has config changes beyond flows (app, reporters, etc.).
  These will be included when the branch merges. Review them separately.
```

## Phase 2: Classify & Deduplicate

### 2.1 Classify by scope

For each discovered flow:

| Scope | Action |
|-------|--------|
| `"general"` | Include in merge plan — this flow is useful everywhere |
| `"feature"` | Ask: "'{name}' is feature-scoped. Will it still be relevant after merge? [y/n/re-scope to general]" |
| No scope (default `"general"`) | Include in merge plan |

If the user says `n` to a feature-scoped flow, drop it from the merge plan.
If the user says `re-scope`, change its scope to `"general"`.

### 2.2 Deduplicate against target

Compare each flow proposed for merge against the target's existing flows:

- **Same `name`**: Skip. Inform: "'{name}' already exists in {target}, skipping."
- **Semantic similarity**: Judge whether two flows test the same behavior by comparing their step intents and overall purpose. If a discovered flow appears to duplicate an existing flow (same user journey, same verifications), flag it:
  ```
  '{discovered-name}' appears to test the same behavior as existing '{target-name}'.
  Replace / Skip / Add both?
  ```

## Phase 3: Present & Apply

### 3.1 Present merge plan

```
Merging test cases: {current-branch} → {target-branch}

Add ({N} general):
  1. "{name}" — {step count} steps, discovered by {discovered_by}
  2. ...

{If any feature-scoped decisions were made:}
Dropped ({N} feature-scoped):
  3. "{name}" — dropped by user

{If any duplicates were found:}
Skipped ({N} duplicates):
  4. "{name}" — duplicate of "{existing-name}"

Apply merge? [y/n]
```

If the user says no, stop without changes.

### 3.2 Clean up metadata

For each flow being merged, update metadata:
- `branch` → clear (set to `null` or remove the field — the flow now belongs to the target)
- `scope` → set to `"general"` (feature-scoped flows were either re-scoped or dropped)
- `discovered_by` → preserve (for history)
- `discovered_at` → preserve (for history)

### 3.3 Apply

Read current `qagent.json`, append the merged flows to the `flows` array, and write back. Only modify `flows` — never touch other config sections.

Output:
```
Merged {N} test cases into qagent.json.
{If on feature branch:} These will be included when {current-branch} merges into {target-branch}.
{If on target branch:} Test cases are now part of {target-branch}.
```

## Important Rules

- **NEVER** log or output secret values from `qagent.json`
- Only modify `flows` — never touch `app`, `auth`, `secrets`, `reporters`, or other config
- Always show the merge plan and get user approval before writing
- Semantic deduplication is a judgment call — when in doubt, flag it for the user
- If `qagent.json` doesn't exist, stop with error: "No qagent.json found."
```

- [ ] **Step 3: Read and verify**

Read `skills/merge/SKILL.md` and verify correct YAML frontmatter and all sections.

- [ ] **Step 4: Commit**

```bash
git add skills/merge/SKILL.md
git commit -m "feat: add /qagent:merge skill — branch-aware test case merging"
```

---

## Task 7: Verify plugin structure and push

**Files:**
- All modified/created files

- [ ] **Step 1: Verify directory structure**

```bash
ls -la skills/explore/SKILL.md skills/merge/SKILL.md
```

Expected: Both files exist.

- [ ] **Step 2: Verify all JSON is valid**

```bash
cat templates/qagent-example.json | python3 -m json.tool > /dev/null && echo "OK"
```

Expected: "OK"

- [ ] **Step 3: Verify YAML frontmatter in new skills**

```bash
head -6 skills/explore/SKILL.md
head -6 skills/merge/SKILL.md
```

Expected: Both start with `---` and have `name:`, `description:`, `allowed-tools:` fields.

- [ ] **Step 4: Verify git status is clean**

```bash
git status
```

Expected: nothing to commit, working tree clean

- [ ] **Step 5: Push to remote**

```bash
git push origin main
```

Expected: Push succeeds.
