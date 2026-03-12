# QAgent Plugin Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude Code plugin that orchestrates automated UI and behavior testing of web apps via MCP browser tools, with secrets management, configurable reporters, and a learning loop that evolves the test suite from failures.

**Architecture:** Claude Code plugin with 3 skills (`test`, `plan`, `report`), 2 subagent definitions (`flow-executor`, `reporter`), and helper scripts. The plugin reads a `qagent.json` config, resolves secrets, generates a test plan, executes flows via MCP browser tools, verifies state changes, proposes new test cases from failures, and reports results to configurable channels.

**Tech Stack:** Claude Code plugin system (Markdown skills/agents with YAML frontmatter), shell scripts (bash), Node.js scripts for reporters, JSON for config/plans/reports.

**Spec:** `docs/superpowers/specs/2026-03-12-qagent-plugin-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `.claude-plugin/plugin.json` | Plugin manifest — name, version, description, keywords |
| `skills/test/SKILL.md` | Main `/qagent:test` skill — orchestrates the full test run |
| `skills/plan/SKILL.md` | `/qagent:plan` skill — generates plan without executing |
| `skills/report/SKILL.md` | `/qagent:report` skill — re-sends last results to a channel |
| `agents/flow-executor.md` | Subagent that executes a single user flow against the browser |
| `agents/reporter.md` | Subagent that formats and delivers results to an output channel |
| `scripts/reporters/slack.sh` | Sends formatted JSON payload to Slack webhook |
| `scripts/reporters/telegram.sh` | Sends formatted message to Telegram bot API |
| `scripts/detect-environment.sh` | Detects available MCP browser tools and reports the provider type |
| `templates/qagent-example.json` | Example config file for users to copy and customize |
| `.mcp.json` | Playwright MCP server definition (fallback for non-Chrome-DevTools environments) |

**Spec deviations (intentional):**
- `scripts/reporters/console.sh` from the spec is **not a separate script** — console output is handled directly by the reporter subagent's reasoning since it's just stdout formatting. No shell script needed.
- Flow-level `"error"` status is added (not in spec) to distinguish infrastructure failures from test failures at the flow level.
- `plan` skill saves a `qagent-plan-draft.json` as a convenience artifact (not in spec).

---

## Chunk 1: Plugin Scaffold & Config

### Task 1: Plugin Manifest

**Files:**
- Create: `.claude-plugin/plugin.json`

- [ ] **Step 1: Create plugin.json**

```json
{
  "name": "qagent",
  "version": "0.1.0",
  "description": "Automated UI and behavior testing — Claude orchestrates browser interactions, verifies state changes, and evolves test cases from failures",
  "author": {
    "name": "qagent"
  },
  "license": "MIT",
  "keywords": ["testing", "qa", "ui-testing", "behavior-testing", "browser-automation", "mcp"]
}
```

- [ ] **Step 2: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "feat: add qagent plugin manifest"
```

### Task 2: Example Config Template

**Files:**
- Create: `templates/qagent-example.json`

- [ ] **Step 1: Create example config**

This file is a complete, commented example that users copy to `qagent.json` and customize. Since JSON doesn't support comments, use descriptive placeholder values.

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
  "changelog": "Describe recent changes here. Each bug fix gets a regression test. Each new feature gets a smoke test.",
  "flows": [
    {
      "name": "example-login-flow",
      "role": "user",
      "steps": [
        { "action": "login" },
        { "action": "verify", "expect": "dashboard is visible with welcome message" }
      ]
    }
  ],
  "browser": {
    "provider": "chrome-devtools"
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

- [ ] **Step 2: Commit**

```bash
git add templates/qagent-example.json
git commit -m "feat: add example qagent.json config template"
```

### Task 3: MCP Server Config

**Files:**
- Create: `.mcp.json`

- [ ] **Step 1: Create .mcp.json with Playwright fallback**

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@anthropic/playwright-mcp-server"]
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add .mcp.json
git commit -m "feat: add playwright MCP server fallback config"
```

---

## Chunk 2: Subagent Definitions

### Task 4: Flow Executor Subagent

**Files:**
- Create: `agents/flow-executor.md`

- [ ] **Step 1: Write the flow-executor agent definition**

This is the core agent — it receives a single flow definition and executes it step-by-step against the browser via MCP tools. It must handle screenshots, console/network monitoring, state-change verification, deviations, error recovery, and timeout awareness.

```markdown
---
name: flow-executor
description: Executes a single user flow against a web app via MCP browser tools. Takes screenshots, checks console/network, verifies state changes, and reports step-by-step results.
allowed-tools: Read, Write, Bash, mcp__chrome-devtools__*, mcp__playwright__*
---

# Flow Executor

You are executing a single user flow as part of a QAgent test run. You receive the flow definition, app context, and auth credentials. Your job is to execute each step, verify outcomes, and return structured results.

## Input

You receive:
- **Flow definition**: JSON object with `id`, `name`, `role`, `steps[]` (each with `id`, `intent`, `status: "pending"`)
- **App URL**: The base URL of the web app
- **Auth credentials**: Username/password (already resolved from secrets) for the flow's role
- **Timeouts**: `step` (seconds per step), `flow` (seconds for entire flow)

## Execution Rules

1. Execute steps sequentially in order
2. Before each step: check if flow timeout has been exceeded. If so, mark remaining steps as `"status": "skipped"` and return
3. For each step:
   a. Interpret the natural language `intent` and perform the browser action
   b. Take a screenshot after the action completes
   c. Check for console errors via `list_console_messages`
   d. Check for network errors via `list_network_requests` (look for 4xx/5xx)
   e. If the step has a `verify`/`expect` component, check the page state matches
   f. Determine `status`: `"passed"` if action succeeded and expectation met, `"failed"` otherwise
   g. Write an `observation` describing what you saw
   h. If you notice something unexpected not related to the current step, insert a deviation step (id: `{current-step-id}.{n}`, source: `"observed"`, status: `"issue"`)

4. **Error recovery:**
   - If a step fails with `critical` severity → stop executing this flow, mark remaining steps as `"skipped"`
   - If auth/login fails → stop the entire flow (mark remaining as `"skipped"`, note auth failure)
   - Network error → retry once after 3 seconds. If still failing, mark as `"failed"`
   - 5xx response → mark as `"failed"`, log status code, continue to next step

5. **Browser state:** Assume you start with a clean browser session (cookies/localStorage cleared by the orchestrator before your flow begins)

## Severity Assignment

| Severity | When to assign |
|----------|---------------|
| `critical` | Core flow broken, data loss, security issue (payment fails, login broken, data not saved) |
| `high` | Feature unusable but workaround may exist (button broken, wrong redirect) |
| `medium` | Unexpected behavior with no data impact (console errors, slow loads, UI glitches) |
| `low` | Cosmetic or minor UX issues (typos, alignment, missing icons) |

## Output Format

Return a JSON object — the flow definition with all steps updated:

```json
{
  "id": "flow-1",
  "name": "purchase-flow",
  "source": "config",
  "role": "user",
  "status": "passed | failed | error",
  "steps": [
    {
      "id": "s1",
      "intent": "Login as user",
      "status": "passed",
      "observation": "Navigated to /login, filled credentials, redirected to /dashboard",
      "screenshot": "screenshots/flow-1-s1.png"
    }
  ]
}
```

The overall flow `status` is:
- `"passed"` if all steps passed (deviations with `low`/`medium` severity are OK)
- `"failed"` if any step has `"status": "failed"` with `critical` or `high` severity
- `"error"` if an infrastructure problem prevented execution

## Important

- Always take a screenshot after each action using `take_screenshot`. The MCP tool returns screenshot data. Save it to disk:
  - Use `take_screenshot` MCP tool (Chrome DevTools or Playwright)
  - The tool typically saves to a temp path or returns base64 data
  - Use Bash or Write to copy/decode to `qagent-reports/screenshots/{flow-id}-{step-id}.png`
  - Create `qagent-reports/screenshots/` directory if it doesn't exist: `mkdir -p qagent-reports/screenshots`
- Never log or output credential values
- Interpret step intents with common sense. "Click Buy Now on first product" means find a button or link with text like "Buy Now" on the first product listing.
- When verifying state changes, wait briefly (up to 3s) for async updates before declaring failure
- If a page shows a loading spinner, wait for it to complete (up to step timeout) before evaluating
```

- [ ] **Step 2: Commit**

```bash
git add agents/flow-executor.md
git commit -m "feat: add flow-executor subagent definition"
```

### Task 5: Reporter Subagent

**Files:**
- Create: `agents/reporter.md`

- [ ] **Step 1: Write the reporter agent definition**

```markdown
---
name: reporter
description: Formats test results and delivers them to configured output channels (console, JSON file, Slack, Telegram).
allowed-tools: Read, Bash, Write
---

# Reporter

You receive a completed test plan and a list of reporter configurations. Your job is to aggregate results and deliver them to each configured channel.

## Input

You receive:
- **Completed plan**: JSON object with all flows and step results
- **Reporter configs**: Array of `{ "type": "...", ... }` objects from qagent.json

## Aggregation

From the completed plan, compute:

```json
{
  "summary": {
    "app": "<app name>",
    "url": "<app url>",
    "total_flows": <count>,
    "passed": <flows where status == "passed">,
    "failed": <flows where status == "failed">,
    "issues": <total deviation steps across all flows>,
    "duration": "<formatted duration>"
  },
  "failures": [<steps with status "failed", include flow name, step intent, observation, severity>],
  "issues": [<steps with status "issue", include flow name, step intent, observation, severity>],
  "full_plan": <the complete plan object>
}
```

## Reporters

### console (always runs)

Output to stdout using this format:

```
✗ QAgent Report — {app} ({url})

  {flow-name} .............. PASSED|FAILED
    ✓ {step intent}
    ✗ {step intent} — "{observation summary}"
    ⚠ [DEVIATION] {deviation intent}

  Summary: N passed, N failed, N deviations | {duration}
```

Use ✓ for passed, ✗ for failed, ⚠ for deviations. If all flows pass, use ✓ instead of ✗ in the header.

### json

Save the full aggregated report to the configured path:
```bash
mkdir -p {path}
# Write the aggregated JSON to {path}/qagent-report-{timestamp}.json
```

### slack

Format a concise message and send via webhook:
```bash
curl -s -X POST -H 'Content-type: application/json' \
  --data '{"text":"<formatted summary>"}' \
  "{webhook_url}"
```

The message should include: app name, pass/fail counts, list of failures with severity, and a one-line summary.

Use the script at `${CLAUDE_PLUGIN_ROOT}/scripts/reporters/slack.sh` if available, otherwise use curl directly.

### telegram

Format and send via Telegram Bot API:
```bash
curl -s -X POST \
  "https://api.telegram.org/bot{bot_token}/sendMessage" \
  -d chat_id="{chat_id}" \
  -d parse_mode="Markdown" \
  -d text="<formatted summary>"
```

Use the script at `${CLAUDE_PLUGIN_ROOT}/scripts/reporters/telegram.sh` if available, otherwise use curl directly.

## Important

- Console reporter always runs, regardless of config
- Never include secret values in any output
- If a reporter delivery fails (e.g., Slack webhook returns error), log the error but don't fail the overall run
- Keep Slack/Telegram messages concise — summary + failures only, not the full plan
```

- [ ] **Step 2: Commit**

```bash
git add agents/reporter.md
git commit -m "feat: add reporter subagent definition"
```

---

## Chunk 3: Reporter Scripts

### Task 6: Slack Reporter Script

**Files:**
- Create: `scripts/reporters/slack.sh`

- [ ] **Step 1: Write the Slack reporter**

```bash
#!/usr/bin/env bash
# Usage: echo '{"text":"..."}' | slack.sh <webhook_url>
# Sends a JSON payload to a Slack incoming webhook.

set -euo pipefail

WEBHOOK_URL="${1:?Usage: slack.sh <webhook_url>}"

if [ -z "$WEBHOOK_URL" ]; then
  echo "Error: Slack webhook URL is required" >&2
  exit 1
fi

PAYLOAD=$(cat -)

RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H 'Content-type: application/json' \
  --data "$PAYLOAD" \
  "$WEBHOOK_URL")

if [ "$RESPONSE" -ne 200 ]; then
  echo "Error: Slack webhook returned HTTP $RESPONSE" >&2
  exit 1
fi

echo "Slack notification sent successfully"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/reporters/slack.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/reporters/slack.sh
git commit -m "feat: add slack reporter script"
```

### Task 7: Telegram Reporter Script

**Files:**
- Create: `scripts/reporters/telegram.sh`

- [ ] **Step 1: Write the Telegram reporter**

```bash
#!/usr/bin/env bash
# Usage: echo "message text" | telegram.sh <bot_token> <chat_id>
# Sends a message via Telegram Bot API.

set -euo pipefail

BOT_TOKEN="${1:?Usage: telegram.sh <bot_token> <chat_id>}"
CHAT_ID="${2:?Usage: telegram.sh <bot_token> <chat_id>}"

MESSAGE=$(cat -)

RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d parse_mode="Markdown" \
  --data-urlencode text="$MESSAGE")

if [ "$RESPONSE" -ne 200 ]; then
  echo "Error: Telegram API returned HTTP $RESPONSE" >&2
  exit 1
fi

echo "Telegram notification sent successfully"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/reporters/telegram.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/reporters/telegram.sh
git commit -m "feat: add telegram reporter script"
```

### Task 7.5: Environment Detection Script

**Files:**
- Create: `scripts/detect-environment.sh`

- [ ] **Step 1: Write the detection script**

This script checks which MCP browser tools are available by looking for known MCP tool patterns. Used by the test skill during startup validation.

```bash
#!/usr/bin/env bash
# Usage: detect-environment.sh
# Outputs the detected browser provider: chrome-devtools, playwright, or none.
# Checks for MCP tool availability by looking at Claude Code's tool list.

set -euo pipefail

# Check for Chrome DevTools MCP tools
if claude --print-tools 2>/dev/null | grep -q "mcp__chrome-devtools__"; then
  echo "chrome-devtools"
  exit 0
fi

# Check for Playwright MCP tools
if claude --print-tools 2>/dev/null | grep -q "mcp__playwright__"; then
  echo "playwright"
  exit 0
fi

echo "none"
exit 1
```

Note: The exact mechanism to detect available MCP tools depends on the Claude Code runtime. The skill can also detect tools directly by checking which tools are in its allowed-tools set. This script is a fallback for CI environments.

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/detect-environment.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/detect-environment.sh
git commit -m "feat: add environment detection script for MCP browser tools"
```

---

## Chunk 4: Skills — Plan & Report

### Task 8: Plan Skill

**Files:**
- Create: `skills/plan/SKILL.md`

- [ ] **Step 1: Write the plan skill**

This skill generates a test plan without executing it. It reads config, resolves secrets (for validation only), and outputs the plan for review.

```markdown
---
name: plan
description: Generate a QAgent test plan from app context and changelog without executing it. Use when you want to review what will be tested before running.
argument-hint: [config-path-or-url] [changelog]
allowed-tools: Read, Bash, Grep, Glob
---

# Generate QAgent Test Plan

Generate a test plan for a web app without executing it.

## Input

Arguments: `$ARGUMENTS`
- If a file path is provided, read it as the config file
- If a URL is provided as first argument, use it as the app URL
- If a second argument is provided, use it as the changelog
- If no arguments, look for `qagent.json` in: (1) current directory, (2) nearest ancestor with `.git`

## Steps

1. **Load config**
   - Find and read `qagent.json` (or parse inline args)
   - Config discovery order: (1) path passed as argument, (2) current working directory, (3) nearest ancestor directory containing `.git`. First match wins.
   - If inline args: `$1` = app URL, `$2` = changelog text
   - If config file: read and parse the full JSON

2. **Validate secrets**
   - Find all `secret:KEY` references in the config
   - Check the configured secrets provider:
     - `"provider": "file"` → check files exist at `{path}/{KEY}`
     - `"provider": "env"` → check env vars exist
     - No provider configured → check env vars as fallback
   - List any unresolvable secrets but do NOT output their values
   - If secrets are missing → **STOP** and output error listing the unresolved keys (same behavior as `/qagent:test` — plan generation validates that the config is runnable)

3. **Generate test plan**

   Create a plan JSON object:
   ```json
   {
     "app": "<app name>",
     "url": "<app url>",
     "trigger": "<manual|ci — detect from environment>",
     "changelog_summary": "<changelog text>",
     "generated_at": "<ISO timestamp>",
     "flows": []
   }
   ```

   **Config flows:** For each flow in `qagent.json` → `flows[]`, add it to the plan with `source: "config"`, converting each step's `action`/`target`/`expect` into a natural language `intent`.

   **Inferred flows** (if `inference` is not `false`):
   - Parse the changelog for bug fixes → generate 1 regression test flow per fix
   - Parse the changelog for new features → generate 1 smoke test flow per feature
   - Cap at `limits.max_inferred_flows` (default 5)
   - Each inferred flow must include `reasoning` explaining why it was generated
   - Mark as `source: "inferred"`

   All steps start with `status: "pending"`.

4. **Output the plan**

   Print the plan as formatted JSON to stdout. Also save to `qagent-reports/qagent-plan-draft.json`.

   ```
   QAgent Test Plan — {app name} ({url})

   Flows to execute:
   1. {flow-name} ({source}) — {step count} steps
      {reasoning if inferred}
   2. ...

   Total: {N} flows ({M} from config, {K} inferred)
   ```
```

- [ ] **Step 2: Commit**

```bash
git add skills/plan/SKILL.md
git commit -m "feat: add /qagent:plan skill — generates test plan without execution"
```

### Task 9: Report Skill

**Files:**
- Create: `skills/report/SKILL.md`

- [ ] **Step 1: Write the report skill**

```markdown
---
name: report
description: Re-send the results of the last QAgent test run to a specified output channel. Use after a test run to send results to Slack, Telegram, etc.
argument-hint: [channel]
allowed-tools: Read, Bash, Write
---

# Re-Report QAgent Results

Re-send the last test run's results to a specified channel.

## Input

`$ARGUMENTS` = the reporter channel name (e.g., `slack`, `telegram`, `json`, `console`)

If no argument provided, default to `console`.

## Steps

1. **Find the last run**
   - Read `qagent-reports/latest.json`
   - If it doesn't exist, look for the most recent `qagent-plan-*.json` file in `qagent-reports/`
   - If no reports found, error: "No QAgent reports found. Run `/qagent:test` first."

2. **Load config for reporter settings**
   - Read `qagent.json` to get reporter configurations (webhook URLs, bot tokens, etc.)
   - Resolve any `secret:` references needed for the reporter

3. **Dispatch reporter subagent**
   - Pass the completed plan and the specific reporter config for the requested channel
   - The reporter subagent handles formatting and delivery

4. **Confirm delivery**
   - Output confirmation: "Results sent to {channel}."
   - If delivery failed, output the error from the reporter
```

- [ ] **Step 2: Commit**

```bash
git add skills/report/SKILL.md
git commit -m "feat: add /qagent:report skill — re-sends results to output channel"
```

---

## Chunk 5: Test Skill (Main Orchestrator)

### Task 10: Test Skill

**Files:**
- Create: `skills/test/SKILL.md`

- [ ] **Step 1: Write the test skill — the main orchestrator**

This is the largest and most important file. It ties everything together: config loading, secret resolution, plan generation, flow execution, learning loop, and reporting.

```markdown
---
name: test
description: Run QAgent automated UI and behavior tests against a web app. Orchestrates browser interactions via MCP, verifies state changes, proposes new test cases from failures, and reports results.
argument-hint: [config-path-or-url] [changelog]
allowed-tools: Read, Write, Bash, Grep, Glob, Agent, mcp__chrome-devtools__*, mcp__playwright__*
---

# QAgent Test Runner

You are the QAgent test orchestrator. You read app context, generate a test plan, execute flows via MCP browser tools, verify state changes, learn from failures, and report results.

## Input

Arguments: `$ARGUMENTS`
- If a URL is provided as first argument, use it as the app URL with the second argument as changelog
- If a file path is provided, read it as the config file
- If no arguments, look for `qagent.json` in: (1) current directory, (2) nearest ancestor with `.git`

## Phase 1: Startup Validation

### 1.1 Load config

Find and parse `qagent.json` or inline arguments. If inline:
- `$1` = app URL
- `$2` = changelog text
- Use defaults for everything else (no auth, no explicit flows, console reporter only)

### 1.2 Detect trigger

- If `trigger` is set in config and is not `"auto"` → use it
- If env var `CI=true` or `QAGENT_CI=true` → `"ci"`
- Otherwise → `"manual"`

### 1.3 Resolve secrets

For every value in the config matching `secret:KEY`:
- If `secrets.provider` is `"file"` → read `{secrets.path}/{KEY}` (default path: `/var/run/secrets/qagent`)
- If `secrets.provider` is `"env"` → read env var `$KEY`
- If no `secrets` block → fall back to env var `$KEY`
- If any secret is missing → **STOP** and output error:
  ```
  QAgent Error: Missing secrets: KEY1, KEY2
  Configure secrets in qagent.json or set environment variables.
  ```
  Exit with code 2.

### 1.4 Check browser availability

Check which MCP browser tools are available:
- Look for `mcp__chrome-devtools__navigate_page` or similar Chrome DevTools tools
- Look for `mcp__playwright__*` tools
- If neither is available → **STOP** and output error:
  ```
  QAgent Error: No browser MCP server available.
  Configure browser.provider in qagent.json or ensure Chrome DevTools MCP is connected.
  ```
  Exit with code 2.

### 1.5 Check app reachability

```bash
curl -s -o /dev/null -w "%{http_code}" -m 10 "{app_url}"
```

If the response is not 2xx or 3xx → **STOP** and output error:
```
QAgent Error: App at {url} is not reachable (HTTP {code}).
```
Exit with code 2.

## Phase 2: Plan Generation

Generate the test plan following the same logic as the `/qagent:plan` skill:

1. Convert config flows to plan flows (`source: "config"`)
2. If inference enabled, generate inferred flows from changelog (`source: "inferred"`, max `limits.max_inferred_flows`)
3. All steps start as `status: "pending"`
4. Output the plan summary to console

```
QAgent — {app name} ({url})
Plan: {N} flows ({M} config, {K} inferred)
```

## Phase 3: Flow Execution

For each flow in the plan, sequentially:

### 3.1 Clear browser state

Clear cookies, localStorage, and session data to ensure a clean state. Each flow starts fresh.

**Chrome DevTools MCP:**
```
1. navigate_page to "about:blank"
2. evaluate_script: "localStorage.clear(); sessionStorage.clear();"
3. evaluate_script: "document.cookie.split(';').forEach(c => document.cookie = c.trim().split('=')[0] + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/');"
```

**Playwright MCP:**
```
1. Navigate to "about:blank"
2. Use evaluate to run the same JS cleanup
3. If Playwright MCP exposes a `clear_cookies` or `clear_storage` tool, prefer that
```

Determine which MCP tools are available based on what was detected in Phase 1.4.

### 3.2 Dispatch flow-executor subagent

Use the Agent tool to dispatch the `flow-executor` subagent with:
- The flow definition
- App URL
- Resolved auth credentials for the flow's role
- Timeouts from config

### 3.3 Collect results

Receive the updated flow from the subagent. Update the plan with the results.

### 3.4 Learning (interactive mode)

If learning is enabled (default: `true` — learning is on unless `learning.enabled` is explicitly `false` or the `learning` block is absent from config) and the trigger is `"manual"` (interactive mode):
- For each failed step in this flow, immediately:
  1. Gather additional context: screenshot, console errors, network state, DOM around the failure
  2. Reason about what went wrong
  3. Propose updates or new flows:
     - Show each proposal to the user
     - Wait for approval (accept/reject/edit) for each
     - If accepted, queue the change for writing to `qagent.json`
  4. Continue to the next flow

## Phase 4: Learning (CI modes)

If `learning.enabled` is true and trigger is `"ci"`:

### staging mode (default for CI)

Collect all proposals from all failed flows. Write them to the staging file:
```json
{
  "generated_at": "<ISO timestamp>",
  "source_run": "<plan filename>",
  "proposals": [...]
}
```
Save to the path configured in `learning.staging_path` (default: `./qagent-proposed.json`).

### auto-accept mode

Same as staging, but instead of writing a staging file:
1. Apply each proposal directly to `qagent.json`
2. Cap at 10 proposals per run
3. Proposals only modify `flows` — never `app`, `auth`, `secrets`, or `reporters`

## Phase 5: Reporting

### 5.1 Save the plan

Create the `qagent-reports/` directory if it doesn't exist. Save the completed plan:
- `qagent-reports/qagent-plan-{YYYY-MM-DD-HHmmss}.json`
- Copy to `qagent-reports/latest.json`

### 5.2 Dispatch reporter subagent

Use the Agent tool to dispatch the `reporter` subagent with:
- The completed plan
- The reporter configs from `qagent.json`
- For CI trigger: all configured reporters fire
- For manual trigger: console only (unless others are configured)

### 5.3 Exit code (CI)

If trigger is `"ci"`:
- All passed, no critical/high issues → exit 0
- Any critical or high failure → exit 1
- Only medium/low issues → exit 0 (warnings printed)

## Timeouts

| Scope | Default |
|-------|---------|
| Per step | 30s |
| Per flow | 5m |
| Session | 30m |

Override via `timeouts` in config. If a flow exceeds its timeout, mark remaining steps as skipped and move to the next flow.

## Important Rules

- NEVER log or output secret values
- NEVER include credentials in screenshots or reports
- Always take screenshots — they are the primary evidence
- When verifying state changes, wait briefly (up to 3s) for async updates
- If a page shows a loading spinner, wait for it to complete before evaluating
- Browser state MUST be cleared between flows
```

- [ ] **Step 2: Commit**

```bash
git add skills/test/SKILL.md
git commit -m "feat: add /qagent:test skill — main test orchestrator"
```

---

## Chunk 6: Final Assembly & Verification

### Task 11: Verify Plugin Structure

- [ ] **Step 1: Verify the complete directory structure matches the spec**

```bash
find . -type f | grep -v '.git/' | grep -v 'node_modules/' | sort
```

Expected output:
```
./.claude-plugin/plugin.json
./.mcp.json
./agents/flow-executor.md
./agents/reporter.md
./docs/superpowers/plans/2026-03-12-qagent-plugin.md
./docs/superpowers/specs/2026-03-12-qagent-plugin-design.md
./scripts/detect-environment.sh
./scripts/reporters/slack.sh
./scripts/reporters/telegram.sh
./skills/plan/SKILL.md
./skills/report/SKILL.md
./skills/test/SKILL.md
./templates/qagent-example.json
```

- [ ] **Step 2: Verify all scripts are executable**

```bash
test -x scripts/reporters/slack.sh && echo "slack.sh OK" || echo "slack.sh NOT executable"
test -x scripts/reporters/telegram.sh && echo "telegram.sh OK" || echo "telegram.sh NOT executable"
test -x scripts/detect-environment.sh && echo "detect-environment.sh OK" || echo "detect-environment.sh NOT executable"
```

Expected: both OK

- [ ] **Step 3: Validate plugin.json is valid JSON**

```bash
python3 -c "import json; json.load(open('.claude-plugin/plugin.json')); print('OK')"
```

Expected: `OK`

- [ ] **Step 4: Validate example config is valid JSON**

```bash
python3 -c "import json; json.load(open('templates/qagent-example.json')); print('OK')"
```

Expected: `OK`

- [ ] **Step 5: Validate .mcp.json is valid JSON**

```bash
python3 -c "import json; json.load(open('.mcp.json')); print('OK')"
```

Expected: `OK`

### Task 12: Final Commit

- [ ] **Step 1: Add any remaining files and create final commit**

```bash
git add -A
git status
# If there are unstaged changes:
git commit -m "feat: complete qagent plugin scaffold — all skills, agents, scripts, and config"
```

- [ ] **Step 2: Verify git log shows clean history**

```bash
git log --oneline
```

Expected: series of focused commits, one per component.
