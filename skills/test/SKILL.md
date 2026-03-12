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

Find and parse `qagent.json` or inline arguments. Config discovery order: (1) path passed as argument, (2) current working directory, (3) nearest ancestor directory containing `.git`. First match wins.

If inline args:
- `$1` = app URL
- `$2` = changelog text
- Use defaults for everything else (no auth, no explicit flows, console reporter only)

If config file: read and parse the full JSON.

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

**CRITICAL: Secret values must NEVER be logged, included in reports, screenshots, or output.**

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

Store the detected browser type (`chrome-devtools` or `playwright`) for use in Phase 3.

### 1.5 Check app reachability

```bash
curl -s -o /dev/null -w "%{http_code}" -m 10 "{app_url}"
```

If the response is not 2xx or 3xx → **STOP** and output error:
```
QAgent Error: App at {url} is not reachable (HTTP {code}).
```
Exit with code 2. This is an infrastructure error, not a test failure.

## Phase 2: Plan Generation

Generate the test plan following the same logic as the `/qagent:plan` skill:

1. Convert config flows to plan flows (`source: "config"`). For each flow in config, assign sequential IDs (`flow-1`, `flow-2`, ...). For each step, convert the `action`/`target`/`expect` fields into a natural language `intent` and assign step IDs (`s1`, `s2`, ...). All steps start as `status: "pending"`.

2. If inference is enabled (config `inference` is not `false`), generate inferred flows from the changelog:
   - For each bug fix mentioned → generate 1 regression test flow
   - For each new feature mentioned → generate 1 smoke test flow
   - Cap at `limits.max_inferred_flows` (default 5)
   - Each inferred flow must include `reasoning` explaining why it was generated
   - Mark as `source: "inferred"`

3. Output the plan summary to console:
   ```
   QAgent — {app name} ({url})
   Plan: {N} flows ({M} config, {K} inferred)

   Flows:
   1. {flow-name} ({source}) — {step count} steps
   2. ...
   ```

## Phase 3: Flow Execution

For each flow in the plan, sequentially:

**Before starting each flow, check if the session timeout has been exceeded. If so, mark all remaining flows as `"skipped"` and proceed to Phase 5.**

### 3.1 Open a dedicated browser page

Each flow gets its own isolated browser page. This provides clean cookie/storage state without manual clearing.

**Chrome DevTools MCP:**
1. Call `list_pages` to see current pages
2. Call `new_page` with:
   - `url`: the app URL (e.g., `"https://staging.myapp.com"`)
   - `isolatedContext`: `"qagent-flow-{flow-id}"` — this creates an isolated browser context with its own cookies, localStorage, and session storage. No state leaks between flows.
3. Note the returned `pageId` — pass it to the flow-executor subagent

**Playwright MCP:**
1. Use the equivalent page creation tool
2. If Playwright MCP supports isolated contexts, use them
3. Otherwise, create a new page and clear state manually:
   - Navigate to `"about:blank"`
   - `evaluate`: `"localStorage.clear(); sessionStorage.clear();"`
   - `evaluate`: `"document.cookie.split(';').forEach(c => document.cookie = c.trim().split('=')[0] + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/');"`

### 3.2 Dispatch flow-executor subagent

Use the Agent tool to dispatch the `flow-executor` subagent. Provide it with:
- The flow definition (JSON with id, name, role, steps)
- App URL
- **Page ID** — the `pageId` of the browser page opened in 3.1. The flow-executor must call `select_page` with this ID before performing any browser actions.
- Resolved auth credentials for the flow's role (username + password, already resolved from secrets)
- Timeouts from config (`timeouts.step` default 30s, `timeouts.flow` default 300s)
- Which MCP browser tools are available (detected in Phase 1.4)

Example Agent dispatch:
```
Agent tool with prompt:
"You are a QAgent flow-executor. Execute this flow against {app_url}:

Flow: {flow JSON}
Page ID: {pageId} — call select_page with this ID before any browser action
Auth: username={username}, password={password}
Timeouts: step={step_timeout}s, flow={flow_timeout}s
Browser: {chrome-devtools|playwright} MCP tools available

Follow the flow-executor instructions exactly. Return the updated flow JSON with all step results."
```

### 3.3 Collect results and close the page

Receive the updated flow from the subagent. Then **always close the browser page**, regardless of success or failure:

**Chrome DevTools MCP:**
- Call `close_page` with the `pageId` from step 3.1
- If `close_page` fails (e.g., it's the last page), log a warning but continue

**Playwright MCP:**
- Use the equivalent page close tool
- If no explicit close tool, navigate to `about:blank` to free resources

**This is critical:** Unclosed pages leak memory, accumulate state, and can interfere with subsequent flows or the user's browser. Always close, even if the flow errored or timed out.

Update the plan with the results. Track:
- How many flows passed/failed
- Any deviations discovered
- Total duration

### 3.4 Learning (interactive mode)

If learning is enabled (default: `true` — learning is on unless `learning.enabled` is explicitly `false` or the `learning` block is absent from config) and the trigger is `"manual"` (interactive mode):

For each failed step in this flow, immediately:
1. Gather additional context from the failure: the screenshot, console errors, network state, DOM around the failing element
2. Reason about what went wrong and what could be improved
3. Propose one or more changes:
   - **Update existing flow**: modify steps to handle the failure better (e.g., add waits, change selectors)
   - **New flow**: add a new test case to cover an edge case discovered by the failure
4. Present each proposal to the user clearly:
   ```
   ✗ Step "{step intent}" FAILED
     Observation: {observation}

   I'd like to propose:

   1. UPDATE {flow-name}: {description of change}
      Reason: {why this would help}

   2. NEW FLOW {new-flow-name}: {description}
      Reason: {why this edge case should be tested}

   Accept proposal 1? [y/n/edit]
   ```
5. Wait for user approval for each proposal
6. If accepted, queue the change for writing to `qagent.json` at the end
7. Continue to the next flow

After all flows complete, apply all accepted proposals:
- Read current `qagent.json`
- Modify only the `flows` array (never touch `app`, `auth`, `secrets`, `reporters`, or other config)
- Write the updated `qagent.json`

## Phase 4: Learning (CI modes)

If `learning.enabled` is true and trigger is `"ci"`:

### staging mode (default for CI)

Collect all proposals from all failed flows. Write them to the staging file:
```json
{
  "generated_at": "<ISO timestamp>",
  "source_run": "<plan filename>",
  "proposals": [
    {
      "id": "p1",
      "type": "update-flow | new-flow",
      "flow": "<flow name being updated, or null for new>",
      "reason": "<why this change is proposed>",
      "diff": {
        "before": "<original step or null>",
        "after": "<updated step(s) or new flow definition>"
      }
    }
  ]
}
```
Save to the path configured in `learning.staging_path` (default: `./qagent-proposed.json`).

### auto-accept mode

Same as staging, but instead of writing a staging file:
1. Apply each proposal directly to `qagent.json`
2. Cap at 10 proposals per run (prevents runaway generation)
3. Proposals only modify `flows` — never `app`, `auth`, `secrets`, or `reporters`
4. After applying, output: "Auto-accepted {N} proposals. Updated qagent.json."

## Phase 5: Cleanup & Reporting

### 5.0 Close any remaining browser pages

Before reporting, ensure all QAgent-opened pages are closed:

1. Call `list_pages` to get all open pages
2. For each page that was opened by QAgent (pages in `qagent-flow-*` isolated contexts), call `close_page`
3. Do NOT close pages that existed before QAgent started — only close pages we created
4. If all pages would be closed (browser needs at least one), leave the last one on `about:blank`

This handles edge cases where:
- A flow-executor subagent crashed before the orchestrator could close the page
- The session timed out and flows were skipped before cleanup
- An error in Phase 3/4 caused early exit to Phase 5

### 5.1 Save the plan

Create the `qagent-reports/` directory if it doesn't exist:
```bash
mkdir -p qagent-reports/screenshots
```

Save the completed plan:
- `qagent-reports/qagent-plan-{YYYY-MM-DD-HHmmss}.json` — the full plan with all results
- Copy to `qagent-reports/latest.json` — pointer for `/qagent:report`

### 5.2 Dispatch reporter subagent

Use the Agent tool to dispatch the `reporter` subagent. Provide it with:
- The completed plan (full JSON)
- The reporter configs from `qagent.json` (the `reporters` array)
- For CI trigger: all configured reporters fire automatically
- For manual trigger: console reporter only fires by default (others only if explicitly configured)

The reporter subagent will:
1. Aggregate results (pass/fail counts, failures list, issues list)
2. Output console report (always)
3. Send to any additional configured channels (Slack, Telegram, JSON file)

### 5.3 Exit code (CI)

If trigger is `"ci"`, determine the exit code:
- All flows passed, no critical/high issues → exit 0
- Any `critical` or `high` severity failure → exit 1
- Only `medium`/`low` issues → exit 0 (warnings already printed by reporter)
- Infrastructure error → exit 2 (already handled in Phase 1)

Output the exit code determination:
```
QAgent finished. Exit code: {0|1} ({reason})
```

## Timeouts

| Scope | Default | Config key |
|-------|---------|-----------|
| Per step | 30s | `timeouts.step` |
| Per flow | 5m (300s) | `timeouts.flow` |
| Session | 30m (1800s) | `timeouts.session` |

If a flow exceeds its timeout, mark remaining steps as `"status": "skipped"` and move to the next flow. If the session timeout is exceeded, skip all remaining flows and proceed directly to Phase 5 (reporting).

## Important Rules

- **NEVER** log or output secret values — not in console, not in reports, not anywhere
- **NEVER** include credentials in screenshots or reports
- Always take screenshots — they are the primary evidence for pass/fail decisions
- When verifying state changes, wait briefly (up to 3s) for async updates before declaring failure
- If a page shows a loading spinner, wait for it to complete before evaluating
- Each flow gets its own isolated browser page — **always close it** when the flow completes (pass or fail)
- Run Phase 5.0 cleanup before reporting to catch any orphaned pages
- Proposals from the learning loop only modify `flows` — never other config sections
- In `auto-accept` mode, cap at 10 proposals per run
