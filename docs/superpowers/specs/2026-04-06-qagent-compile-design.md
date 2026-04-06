# QAgent — Compiled Playwright Scripts

**Date:** 2026-04-06
**Status:** Draft
**Builds on:** [2026-03-12-qagent-plugin-design.md](./2026-03-12-qagent-plugin-design.md), [2026-03-14-qagent-dev-loop-design.md](./2026-03-14-qagent-dev-loop-design.md)

## Overview

QAgent's LLM-driven flow execution is flexible but slow — each step requires multiple LLM round-trips for interpretation, action, and verification. This spec adds a compilation step that converts flow definitions into executable Playwright Test scripts. Compiled scripts run in seconds instead of minutes.

**The workflow:**
1. `/qagent:compile` — LLM navigates each flow once, discovers real selectors, generates `.spec.ts` files
2. `/qagent:test` — checks for compiled scripts, runs them via Playwright Test (fast path), falls back to LLM for flows without scripts or when scripts fail
3. Self-healing — when a script fails or a flow definition changes (hash mismatch), the user is prompted to recompile

Scripts are committed to git — reviewable, portable, and version-controlled alongside the test suite.

## `/qagent:compile` Skill

### Purpose

Read flows from `qagent.json`, open the app in a browser, LLM navigates each flow step by step, discovers real selectors, and generates Playwright Test `.spec.ts` files.

### Allowed tools

```yaml
allowed-tools: Read, Write, Bash, Grep, Glob, Agent, mcp__chrome-devtools__*, mcp__playwright__*
```

### Invocation

```
/qagent:compile [flow-names...] [config-path]
```

- No arguments: compile all flows in `qagent.json`
- Flow names: compile only those flows (e.g., `/qagent:compile login-flow purchase-flow`)
- Config path: use a specific `qagent.json` (otherwise standard discovery)

### Startup

Same as `/qagent:test` Phase 1:
1. Load config (`qagent.json` discovery)
2. Resolve secrets (needed for auth during compilation)
3. Check browser availability (Chrome DevTools or Playwright MCP)
4. Check app reachability

### Scaffold generation

On first compile (no `qagent-scripts/` directory), generate scaffold files:

**`qagent-scripts/package.json`:**
```json
{
  "private": true,
  "dependencies": {
    "@playwright/test": "latest",
    "dotenv": "latest"
  }
}
```

**`qagent-scripts/playwright.config.ts`:**
```typescript
import { defineConfig } from '@playwright/test';
import { config } from 'dotenv';

config();

export default defineConfig({
  use: {
    baseURL: process.env.QAGENT_APP_URL,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  timeout: 30_000,
  retries: 0,
  workers: 3,
  fullyParallel: true,
  reporter: [['json', { outputFile: 'test-results/results.json' }]],
});
```

**`qagent-scripts/.env.example`:**
Lists all required `QAGENT_*` environment variables without values. Generated from the config's auth roles.

Then run `cd qagent-scripts && npm install && npx playwright install chromium` to set up dependencies.

If `qagent-scripts/` already exists, skip scaffold generation. Only regenerate `package.json` or `playwright.config.ts` if they don't exist.

### Compilation process

For each flow (or selected flows):

#### 1. Check if recompilation is needed

Compute the flow hash (SHA-256 of `JSON.stringify({name, role, steps})`, truncated to 8 hex chars). If a script already exists at `qagent-scripts/{flow-name}.spec.ts` and the stored hash matches, skip this flow unless `--force` flag is passed. The `--force` flag recompiles all targeted flows regardless of hash match — useful when the app's UI changed but the flow definition didn't (e.g., a button was restyled with a new selector).

#### 2. Dispatch script-compiler subagent

Use the Agent tool to dispatch the `script-compiler` subagent with:
- Flow definition (name, role, steps)
- App URL
- Resolved auth credentials for the flow's role
- Which MCP browser tools are available

The subagent:
1. Opens a browser page to the app URL
2. For each step in the flow:
   - Interprets the natural language intent
   - Performs the action via MCP browser tools
   - Takes a screenshot to see the current page state
   - Identifies the best selector for the element acted on
   - Records: action type (`goto`, `fill`, `click`, `expect`), selector, input value, assertion
3. Returns a structured list of compiled steps

#### 3. Selector strategy

The subagent discovers selectors using this priority (most stable first):

| Priority | Type | Example | When to use |
|----------|------|---------|-------------|
| 1 | `data-testid` / `data-test-id` | `page.getByTestId('submit-btn')` | Always prefer if present |
| 2 | Role + accessible name | `page.getByRole('button', { name: 'Submit' })` | Semantic elements with labels |
| 3 | Text content | `page.getByText('Save changes')` | Visible, stable text |
| 4 | `id` attribute | `page.locator('#email')` | Unique IDs that aren't auto-generated |
| 5 | Short CSS selector | `page.locator('.checkout-btn')` | Only if above options don't work |

**Never use:**
- Full XPath (`/html/body/div[2]/div/form/button`)
- Deeply nested CSS (`div > div > span:nth-child(3)`)
- Auto-generated class names (`._a3bc2f`, `.css-1x2y3z`)
- Framework-internal attributes (`data-reactid`, `ng-`)

When multiple candidates exist for a selector, prefer the one that is most likely to survive a UI refactor.

#### 4. Generate script file

Write `qagent-scripts/{flow-name}.spec.ts`:

```typescript
// qagent-compiled: {"flow":"login-flow","hash":"a1b2c3d4","compiled_at":"2026-04-06T10:00:00Z"}
import { test, expect } from '@playwright/test';

test('login-flow', async ({ page }) => {
  await page.goto(process.env.QAGENT_APP_URL!);

  // Step 1: Login as user
  await page.getByRole('textbox', { name: 'Email' }).fill(process.env.QAGENT_AUTH_USER_USERNAME!);
  await page.getByRole('textbox', { name: 'Password' }).fill(process.env.QAGENT_AUTH_USER_PASSWORD!);
  await page.getByRole('button', { name: 'Sign in' }).click();

  // Step 2: Verify dashboard is visible
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
});
```

**Conventions:**
- First line: JSON comment with flow name, hash, and compile timestamp
- One `test()` block per flow
- Step intents as comments above the corresponding code
- App URL via `process.env.QAGENT_APP_URL`
- Credentials via `process.env.QAGENT_AUTH_{ROLE}_{FIELD}` (e.g., `QAGENT_AUTH_USER_PASSWORD`)
- Never hardcode secrets, URLs, or credentials
- Use Playwright's built-in auto-waiting — no manual `waitForSelector` or `sleep`
- Use `expect()` web-first assertions for verification steps

#### 5. Close browser page

Close the page after compilation, same as `/qagent:test` flow cleanup.

### Output

```
QAgent Compile — {app name} ({url})

Compiling {N} flows...
  1. login-flow .............. OK (4 steps → login-flow.spec.ts)
  2. purchase-flow ........... OK (6 steps → purchase-flow.spec.ts)
  3. settings-update ......... FAILED (step 3: could not find "Save" button)
  4. checkout-flow ........... SKIPPED (hash unchanged)

Compiled: 2/4 flows (1 failed, 1 skipped)
Scripts saved to qagent-scripts/
```

If a flow fails to compile, no script is generated for it. LLM fallback will be used during `/qagent:test`.

## `script-compiler` Subagent

### Definition

```yaml
name: script-compiler
description: Navigates a single flow in the browser, discovers selectors for each step, and returns structured compilation data for Playwright script generation.
allowed-tools: Read, Write, Bash, mcp__chrome-devtools__*, mcp__playwright__*
```

**Model:** Default (not haiku) — selector discovery requires strong reasoning about page structure and selector stability.

### Input

- Flow definition (name, role, steps with intents)
- App URL
- Resolved auth credentials
- Browser type (chrome-devtools or playwright)

### Behavior

1. Open page, navigate to app URL
2. For each step:
   - Interpret the intent (same as flow-executor)
   - Perform the action via MCP
   - Take a screenshot
   - Inspect the page to find the best selector for the target element
   - Record a compilation entry: `{ action, selector, value?, assertion? }`
3. Return the full list of compiled steps as JSON

### Output format

```json
{
  "flow": "login-flow",
  "steps": [
    {
      "intent": "Login as user",
      "actions": [
        { "type": "fill", "selector": "getByRole('textbox', { name: 'Email' })", "value": "env:QAGENT_AUTH_USER_USERNAME" },
        { "type": "fill", "selector": "getByRole('textbox', { name: 'Password' })", "value": "env:QAGENT_AUTH_USER_PASSWORD" },
        { "type": "click", "selector": "getByRole('button', { name: 'Sign in' })" }
      ]
    },
    {
      "intent": "Verify dashboard is visible",
      "actions": [
        { "type": "expect_visible", "selector": "getByRole('heading', { name: 'Dashboard' })" }
      ]
    }
  ]
}
```

Values prefixed with `env:` are converted to `process.env.VARNAME` in the generated script. Literal values (e.g., text to type in a search box) are inlined as strings.

## `/qagent:test` Integration

### New Phase 3.0.5: Script check

After choosing execution strategy (Phase 3.0) and before opening browser pages (Phase 3.1), check each flow for compiled scripts:

1. Compute hash of the flow definition: `SHA-256(JSON.stringify({name, role, steps}))` truncated to 8 hex chars
2. Check if `qagent-scripts/{flow-name}.spec.ts` exists
3. If exists, read the first line and parse the `qagent-compiled` JSON comment to extract the stored hash

#### Decision matrix

| Script exists? | Hash match? | Trigger | Action |
|---|---|---|---|
| Yes | Yes | any | **Fast path** — run script via Playwright Test |
| Yes | No | manual | Prompt: "Flow '{name}' has changed since last compile. Recompile / Run stale / LLM fallback?" |
| Yes | No | ci | Run stale script, log warning: "Stale script for '{name}' — consider recompiling" |
| No | — | manual | Prompt: "No compiled script for '{name}'. Compile now / LLM fallback?" |
| No | — | ci | LLM fallback (no prompt) |

### Fast path execution

When running a compiled script:

1. Set environment variables from resolved config:
   - `QAGENT_APP_URL` — app URL
   - `QAGENT_AUTH_{ROLE}_USERNAME` — for each auth role
   - `QAGENT_AUTH_{ROLE}_PASSWORD` — for each auth role
2. Run: `cd qagent-scripts && npx playwright test {flow-name}.spec.ts --reporter=json`
3. Parse `test-results/results.json`
4. Map Playwright results to QAgent flow format:
   - Playwright pass → flow status `"passed"`
   - Playwright fail → flow status `"failed"`, include error message and screenshot path in observation
5. Return the flow result to the orchestrator

**Important:** Script-executed flows skip the MCP browser page lifecycle (Phase 3.1/3.3). Playwright Test manages its own browser. Only LLM-fallback flows use MCP pages.

### Script failure handling

If a script fails during fast path:

**Manual mode:**
```
Script for '{name}' failed:
  {Playwright error message}

Recompile this flow? [y/n]
```
- **y** → dispatch script-compiler for this flow, regenerate script, re-run
- **n** → keep the failure result as-is

**CI mode:**
- Log the failure with Playwright error output
- Include in the test report
- No auto-recompile — CI runs should be deterministic

### Recompile during test

When the user chooses to recompile (hash mismatch or script failure):

1. Dispatch script-compiler subagent for that single flow
2. Write the new `.spec.ts` file
3. Re-run the script via fast path
4. Continue to next flow

This happens inline — no need to restart the entire test run.

## File Structure

```
qagent-scripts/                  # committed to git
├── package.json                 # @playwright/test dependency
├── playwright.config.ts         # base URL from env, JSON reporter
├── .env.example                 # lists required QAGENT_* vars
├── login-flow.spec.ts           # one file per compiled flow
├── purchase-flow.spec.ts
└── settings-update.spec.ts

# gitignored:
├── node_modules/
└── test-results/
```

## Environment Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `QAGENT_APP_URL` | `app.url` from config | Base URL for all scripts |
| `QAGENT_AUTH_{ROLE}_USERNAME` | `auth.{role}.username` (resolved) | Login credentials per role |
| `QAGENT_AUTH_{ROLE}_PASSWORD` | `auth.{role}.password` (resolved from secrets) | Login credentials per role |

Role names are uppercased: `auth.user` → `QAGENT_AUTH_USER_*`, `auth.admin` → `QAGENT_AUTH_ADMIN_*`.

## .gitignore additions

Add to the project's `.gitignore`:

```
qagent-scripts/node_modules/
qagent-scripts/test-results/
```

## Skill Inventory

| Skill | Status | Change |
|-------|--------|--------|
| `/qagent:compile` | **New** | Generates Playwright Test scripts from flows |
| `/qagent:test` | **Modified** | Hash check (Phase 3.0.5), fast path, recompile prompts |
| `/qagent:plan` | Unchanged | — |
| `/qagent:explore` | Unchanged | — |
| `/qagent:merge` | Unchanged | — |
| `/qagent:report` | Unchanged | — |

## New Subagent

| Agent | Model | Purpose |
|-------|-------|---------|
| `script-compiler` | Default (not haiku) | Navigates a flow, discovers selectors, returns compiled step data |

## Non-Goals (this iteration)

- Auto-recompile in CI — CI runs should be deterministic
- Visual regression in compiled scripts — scripts check functional behavior only
- Parallel compilation — flows are compiled sequentially (LLM shares one browser). Execution is parallel via Playwright Test workers.
- Script editing UI — users edit `.spec.ts` files directly if needed
- Migration from existing Playwright projects — QAgent generates its own scripts
