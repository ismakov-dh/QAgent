# QAgent — Claude Code Plugin for Automated UI & Behavior Testing

**Date:** 2026-03-12
**Status:** Draft

## Overview

QAgent is a Claude Code plugin that tests web applications by imitating real user interactions, verifying that actions produce expected state changes, and reporting misbehaviors. Claude acts as the orchestrator — reading app context, generating a test plan, live-driving a browser via MCP, and reasoning about whether the app behaves correctly.

## Triggers

- **Manual:** User invokes `/qagent:test` in Claude Code
- **CI:** Runs headlessly in a CI pipeline

## App Context

Context is provided in two ways:

### Inline arguments

```
/qagent:test https://myapp.com "Added payment flow, fixed login redirect"
```

### Config file (`qagent.json`)

```json
{
  "app": {
    "name": "MyApp",
    "url": "https://staging.myapp.com",
    "description": "E-commerce platform for digital goods"
  },
  "auth": {
    "admin": { "username": "admin@test.com", "password": "${ADMIN_PASSWORD}" },
    "user": { "username": "user@test.com", "password": "${USER_PASSWORD}" }
  },
  "changelog": "Added payment flow via Stripe. Fixed login redirect loop for expired sessions.",
  "flows": [
    {
      "name": "purchase-flow",
      "role": "user",
      "steps": [
        { "action": "login" },
        { "action": "navigate", "to": "/products" },
        { "action": "click", "target": "Buy Now on first product" },
        { "action": "complete-payment" },
        { "action": "verify", "expect": "order status shows 'Confirmed'" }
      ]
    }
  ],
  "browser": {
    "provider": "chrome-devtools | playwright-local | playwright-docker | playwright-remote",
    "url": "http://...",
    "image": "qagent-playwright-mcp"
  },
  "reporters": [
    { "type": "console" },
    { "type": "slack", "webhook": "${SLACK_WEBHOOK}" }
  ]
}
```

**Key decisions:**
- Credentials via env vars, never hardcoded
- `flows` are optional — Claude infers additional flows from `description` + `changelog`
- Steps use natural language for `target` and `expect` — Claude interprets them
- Multi-app support: each app has its own `qagent.json`, one app tested per invocation

## Execution Engine — MCP-Only Browser Control

The plugin always interacts with the browser via MCP. The underlying MCP server varies by environment:

| Environment | MCP Server | Config |
|-------------|-----------|--------|
| Claude Code (local) | Chrome DevTools MCP (already connected) | Auto-detected |
| CI (local) | Playwright MCP server via `npx` | `"provider": "playwright-local"` |
| CI (Docker) | Playwright MCP in isolated container | `"provider": "playwright-docker"`, `"image": "qagent-playwright-mcp"` |
| CI (Remote) | Playwright MCP via HTTP | `"provider": "playwright-remote"`, `"url": "http://..."` |

**MCP server config in plugin `.mcp.json`** (for non-Chrome DevTools environments):
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

Docker variant:
```json
{
  "mcpServers": {
    "playwright": {
      "command": "docker",
      "args": ["run", "--rm", "-i", "qagent-playwright-mcp"]
    }
  }
}
```

Remote variant:
```json
{
  "mcpServers": {
    "playwright": {
      "url": "http://localhost:3000/mcp"
    }
  }
}
```

**The skill code is identical regardless of environment.** It uses whichever MCP browser tools are available at runtime.

## Test Plan

The plan is the central artifact. Generated before execution, updated during execution, saved as a report after.

### Plan structure

```json
{
  "app": "MyApp",
  "url": "https://staging.myapp.com",
  "trigger": "manual | ci",
  "changelog_summary": "Added payment flow, fixed login redirect",
  "flows": [
    {
      "id": "flow-1",
      "name": "purchase-flow",
      "source": "config",
      "role": "user",
      "steps": [
        { "id": "s1", "intent": "Login as user", "status": "pending" },
        { "id": "s2", "intent": "Navigate to /products", "status": "pending" }
      ]
    },
    {
      "id": "flow-2",
      "name": "login-redirect-regression",
      "source": "inferred",
      "reasoning": "Changelog mentions fixed login redirect bug — verify it's actually fixed",
      "role": "user",
      "steps": [
        { "id": "s1", "intent": "Login with expired session token", "status": "pending" },
        { "id": "s2", "intent": "Verify no redirect loop", "status": "pending" }
      ]
    }
  ]
}
```

### Step results after execution

Passing step:
```json
{
  "id": "s3",
  "intent": "Click Buy Now on first product",
  "status": "passed",
  "observation": "Button clicked, redirected to /checkout. Price shown: $29.99",
  "screenshot": "screenshots/flow-1-s3.png"
}
```

Failing step:
```json
{
  "id": "s4",
  "intent": "Complete payment",
  "status": "failed",
  "observation": "Clicked Submit Payment, spinner appeared for 8s then error toast: 'Payment service unavailable'",
  "screenshot": "screenshots/flow-1-s4.png",
  "severity": "critical"
}
```

### Deviations

When Claude notices something unexpected mid-flow, it inserts a deviation inline:
```json
{
  "id": "s2.1",
  "intent": "[DEVIATION] Console error spotted: 'Uncaught TypeError in cart.js:142'",
  "source": "observed",
  "status": "issue",
  "severity": "medium"
}
```

**Key decisions:**
- `source: "config"` vs `"inferred"` distinguishes explicit flows from Claude's judgment calls
- Steps use natural language `intent`, not CSS selectors
- Deviations are inserted inline where they were spotted
- Severity: `critical` / `high` / `medium` / `low` — assigned by Claude based on impact

## Verification Strategy

QAgent performs four levels of verification:

1. **Visual/functional** — broken pages, error messages on screen, console errors, non-200 responses
2. **Flow-level** — did the flow complete as expected? Redirect loops, dead ends, broken navigation
3. **State-change verification** — the key differentiator: "I pressed Send, it said OK, but did the status actually change?" Claude checks the resulting page state, not just the action acknowledgment
4. **Regression** — changelog says X was fixed/added, verify it actually works

For explicit flows, expected outcomes come from the config. For inferred flows, Claude uses its judgment based on app context, changelog, and general UX expectations.

### Severity guidelines

| Severity | Criteria | Examples |
|----------|----------|----------|
| `critical` | Core flow broken, data loss, security issue | Payment fails, login broken, data not saved |
| `high` | Feature unusable but workaround exists | Button doesn't work, wrong redirect |
| `medium` | Unexpected behavior, no data impact | Console errors, slow loads, UI glitches |
| `low` | Cosmetic, minor UX issues | Typos, alignment, missing icons |

## Plugin Structure

```
qagent/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── test/                    # /qagent:test — main entry point
│   │   └── SKILL.md
│   ├── plan/                    # /qagent:plan — generate plan only, no execution
│   │   └── SKILL.md
│   └── report/                  # /qagent:report — re-format last results for a channel
│       └── SKILL.md
├── agents/
│   ├── flow-executor.md         # Subagent: executes a single user flow
│   └── reporter.md              # Subagent: formats + sends results to output channel
├── scripts/
│   ├── detect-environment.sh    # Detects which MCP browser is available
│   └── reporters/
│       ├── console.sh
│       ├── slack.sh
│       └── telegram.sh
├── templates/
│   └── qagent-example.json      # Example app config
├── .mcp.json                    # Playwright MCP server definition (fallback)
└── docs/
```

## Skills

### `/qagent:test` — Main entry point

1. Read `qagent.json` or parse inline arguments
2. Detect available MCP browser tools
3. Generate test plan (Claude reasons about config + changelog)
4. For each flow → dispatch `flow-executor` subagent
5. Collect results → update plan
6. Dispatch `reporter` subagent
7. Save final plan to `qagent-plan-<timestamp>.json`

### `/qagent:plan` — Plan only, no execution

Same as step 1-3 of `test`. Outputs the plan for review. Useful for dry runs.

### `/qagent:report` — Re-report last results

Takes the last saved plan and sends it through a specified reporter.
```
/qagent:report slack
```

## Subagents

### `flow-executor`

**Receives:** flow definition, app URL, auth credentials, available MCP tools
**Does:**
- Navigates, clicks, fills, verifies — one step at a time
- Takes screenshots at each step
- Checks console logs and network requests after each action
- Evaluates whether the expected outcome actually happened (state-change verification)
- Logs deviations for unexpected issues
- Returns updated flow with all step results

### `reporter`

**Receives:** completed plan with results, reporter config
**Does:**
- Formats summary for the target channel
- Calls appropriate script in `scripts/reporters/`
- Returns delivery confirmation

## Reporter System

Every reporter receives the same summary data:
```json
{
  "summary": {
    "app": "MyApp",
    "url": "https://staging.myapp.com",
    "total_flows": 3,
    "passed": 1,
    "failed": 1,
    "issues": 2,
    "duration": "2m 34s"
  },
  "failures": [],
  "issues": [],
  "full_plan": {}
}
```

### Built-in reporters

| Reporter | Output | Config |
|----------|--------|--------|
| `console` | Formatted summary to stdout — always on | none |
| `json` | Full plan JSON saved to file | `{ "path": "./reports/" }` |
| `slack` | Summary + failures to channel | `{ "webhook": "${SLACK_WEBHOOK}" }` |
| `telegram` | Summary + failures to chat | `{ "bot_token": "${TG_BOT_TOKEN}", "chat_id": "${TG_CHAT_ID}" }` |

### Console output format

```
✗ QAgent Report — MyApp (https://staging.myapp.com)

  purchase-flow .............. FAILED
    ✓ Login as user
    ✓ Navigate to /products
    ✓ Click Buy Now
    ✗ Complete payment — "Payment service unavailable"
    ⚠ [DEVIATION] Console error: Uncaught TypeError in cart.js:142

  login-redirect-regression .. PASSED
    ✓ Login with expired session
    ✓ No redirect loop
    ✓ Lands on dashboard

  Summary: 1 passed, 1 failed, 1 deviation | 2m 34s
```

### CI behavior

- `trigger: "ci"` → all configured reporters fire automatically
- `trigger: "manual"` → console fires by default, others only if configured or via `/qagent:report <channel>`

## Timeouts & Budgets

| Scope | Default | Configurable |
|-------|---------|-------------|
| Per-step timeout | 30s | `qagent.json` → `timeouts.step` |
| Per-flow timeout | 5m | `qagent.json` → `timeouts.flow` |
| Global session timeout | 30m | `qagent.json` → `timeouts.session` |
| Max inferred flows | 5 | `qagent.json` → `limits.max_inferred_flows` |

If a step times out, it is marked `failed` with `severity: high` and observation noting the timeout. Flow continues to next step unless the timed-out step was a prerequisite (e.g., login).

## Error Handling

### Startup validation

Before any test execution, the plugin validates:
1. **Browser availability** — at least one MCP browser server is reachable. If not → exit with clear error: "No browser MCP server available. Configure `browser.provider` in qagent.json or ensure Chrome DevTools MCP is connected."
2. **App reachability** — HTTP HEAD request to app URL. If unreachable → exit with error: "App at {url} is not reachable." This is reported as an infrastructure error, not a test failure.
3. **Env var resolution** — all `${VAR}` references in config are resolved. Missing vars → exit with error listing the unresolved variables.
4. **Config discovery** — plugin looks for `qagent.json` in: (1) path passed as argument, (2) current working directory, (3) project root. First match wins.

### During execution

- **Step failure with `critical` severity** → abort remaining steps in that flow, move to next flow
- **Step failure with `high/medium/low` severity** → log and continue to next step
- **Auth failure** (login step fails) → abort the entire flow (all subsequent steps depend on auth)
- **Network error mid-flow** → retry once after 3s. If still failing, mark step as `failed` with observation noting the network error
- **App returns 5xx** → mark as `failed`, log the status code, continue

### Browser state

Browser state (cookies, localStorage) is **cleared between flows**. Each flow starts with a clean session. This prevents state leakage between roles (admin vs user) and between independent flows.

## Trigger Detection

The `trigger` field in the plan is determined as follows:
- If running inside Claude Code interactively (user invoked `/qagent:test`) → `"manual"`
- If `CI=true` or `QAGENT_CI=true` env var is set → `"ci"`
- Can be overridden in `qagent.json` → `"trigger": "ci"`

## Step Actions

Step actions in flows are **free-form natural language**. Claude interprets them. There is no fixed vocabulary. Examples:
- `"login"` — Claude finds the login page, fills credentials for the specified role
- `"navigate"`, `"click"`, `"fill"` — self-explanatory, Claude finds the right elements
- `"complete-payment"` — Claude follows the payment flow to completion
- `"verify"` with `"expect"` — Claude checks the page state matches the expectation

**v1 auth limitation:** Only username/password form login is supported. OAuth, SSO, MFA, and CAPTCHA are out of scope. If auth requires these, the user should provide a pre-authenticated session cookie in the config.

## Flow Inference Strategy

When generating inferred flows from `description` + `changelog`:
1. For each bug fix mentioned in changelog → generate a regression test flow (1 per fix)
2. For each new feature mentioned → generate a smoke test flow (1 per feature)
3. Cap at `limits.max_inferred_flows` (default 5)
4. Each inferred flow includes `reasoning` explaining why it was generated
5. Inference can be disabled: `"inference": false` in `qagent.json`

## Output & Storage

| Artifact | Location | Naming |
|----------|----------|--------|
| Test plan (final) | `./qagent-reports/` | `qagent-plan-{YYYY-MM-DD-HHmmss}.json` |
| Screenshots | `./qagent-reports/screenshots/` | `{flow-id}-{step-id}.png` |
| Latest pointer | `./qagent-reports/latest.json` | Symlink or copy of most recent plan |

`/qagent:report` uses `latest.json` to find the most recent run. All paths are relative to CWD. The `qagent-reports/` directory is created automatically. Add it to `.gitignore`.

## Reporter Implementation

Reporter scripts are simple executables (Node.js or shell) in `scripts/reporters/`. The reporter subagent:
1. Aggregates results from the plan: steps with `status: "failed"` → `failures[]`, steps with `status: "issue"` → `issues[]`
2. Formats the summary in Claude's reasoning (not in bash)
3. Shells out only for delivery (e.g., `curl` for Slack webhook, Telegram API call)

## Non-Goals (v1)

- No parallel browser sessions (one flow at a time to avoid state conflicts)
- No visual regression / pixel diffing (Claude uses judgment, not screenshots-to-baseline comparison)
- No test recording/playback mode
- No built-in credential management (env vars only)
- No OAuth/SSO/MFA/CAPTCHA handling
