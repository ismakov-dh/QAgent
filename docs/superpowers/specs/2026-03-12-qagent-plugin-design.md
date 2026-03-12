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

QAgent performs three levels of verification:

1. **Visual/functional** — broken pages, error messages on screen, console errors, non-200 responses
2. **Flow-level** — did the flow complete as expected? Redirect loops, dead ends, broken navigation
3. **State-change verification** — the key differentiator: "I pressed Send, it said OK, but did the status actually change?" Claude checks the resulting page state, not just the action acknowledgment
4. **Regression** — changelog says X was fixed/added, verify it actually works

For explicit flows, expected outcomes come from the config. For inferred flows, Claude uses its judgment based on app context, changelog, and general UX expectations.

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

## Non-Goals (v1)

- No parallel browser sessions (one flow at a time to avoid state conflicts)
- No visual regression / pixel diffing (Claude uses judgment, not screenshots-to-baseline comparison)
- No test recording/playback mode
- No built-in credential management (env vars only)
