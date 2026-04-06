---
name: compile
description: Compile QAgent test flows into Playwright Test scripts. LLM navigates each flow once to discover selectors, then generates .spec.ts files that run in seconds.
argument-hint: [flow-names...] [--force]
allowed-tools: Read, Write, Bash, Grep, Glob, Agent, mcp__chrome-devtools__*, mcp__playwright__*
---

# QAgent Compile — Generate Playwright Scripts

You compile QAgent flow definitions into executable Playwright Test scripts. For each flow, you dispatch a script-compiler subagent that navigates the app, discovers real selectors, and returns structured data. You then generate `.spec.ts` files from that data.

## Input

Arguments: `$ARGUMENTS`
- If flow names are provided, compile only those flows (e.g., `login-flow purchase-flow`)
- If `--force` is provided, recompile all targeted flows regardless of hash match
- If a file path is provided, use it as the config file
- If no arguments, compile all flows in `qagent.json`

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
- If neither is available → **STOP** and output error. Exit with code 2.

### 1.4 Check app reachability

```bash
curl -s -o /dev/null -w "%{http_code}" -m 10 "{app_url}"
```

If not 2xx or 3xx → **STOP** with error. Exit with code 2.

## Phase 2: Scaffold

If the `qagent-scripts/` directory does not exist, generate scaffold files:

### 2.1 Create directory

```bash
mkdir -p qagent-scripts
```

### 2.2 Generate package.json

Write `qagent-scripts/package.json`:
```json
{
  "private": true,
  "dependencies": {
    "@playwright/test": "latest",
    "dotenv": "latest"
  }
}
```

Only generate if `qagent-scripts/package.json` does not already exist.

### 2.3 Generate playwright.config.ts

Write `qagent-scripts/playwright.config.ts`:
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

Only generate if `qagent-scripts/playwright.config.ts` does not already exist.

### 2.4 Generate .env.example

Write `qagent-scripts/.env.example` listing all required environment variables from the config:
```
QAGENT_APP_URL=
QAGENT_AUTH_USER_USERNAME=
QAGENT_AUTH_USER_PASSWORD=
QAGENT_AUTH_ADMIN_USERNAME=
QAGENT_AUTH_ADMIN_PASSWORD=
```

Generate variable names from `app.url` and each role in `auth`. Role names are uppercased.

### 2.5 Install dependencies

```bash
cd qagent-scripts && npm install && npx playwright install chromium
```

Only run if `qagent-scripts/node_modules/` does not exist.

## Phase 3: Compile Flows

Output:
```
QAgent Compile — {app name} ({url})

Compiling {N} flows...
```

For each flow in the config (or selected flows from arguments):

### 3.1 Compute flow hash

Compute the hash by serializing the flow's key fields and hashing:

```bash
echo -n '{"name":"{name}","role":"{role}","steps":[...]}' | shasum -a 256 | cut -c1-8
```

Use `JSON.stringify({name: flow.name, role: flow.role, steps: flow.steps})` as the input — this ensures the hash changes when the flow definition changes but not when metadata (scope, branch, etc.) changes.

### 3.2 Check if recompilation is needed

If `qagent-scripts/{flow-name}.spec.ts` exists:
- Read the first line and parse the `qagent-compiled` JSON comment
- Extract the stored `hash` value
- If the stored hash matches the computed hash AND `--force` was not passed → skip this flow:
  ```
    {n}. {flow-name} ........... SKIPPED (hash unchanged)
  ```

### 3.3 Dispatch script-compiler subagent

**Model requirement:** Use `model: "sonnet"` or `model: "opus"` when dispatching the Agent. Never use haiku — selector discovery requires strong reasoning about DOM structure, uniqueness, and stability.

Use the Agent tool to dispatch the `script-compiler` subagent with:

```
Agent tool with prompt:
"You are a QAgent script-compiler. Navigate this flow and discover selectors:

Flow: {flow JSON — name, role, steps}
App URL: {app_url}
Auth: username={username}, password={password}
Browser: {chrome-devtools|playwright} MCP tools available

Follow the script-compiler instructions exactly. Return the compiled steps JSON."
```

### 3.4 Generate .spec.ts file

From the subagent's returned JSON, generate the Playwright Test script.

**Build the script string:**

Line 1 — header comment:
```typescript
// qagent-compiled: {"flow":"{flow-name}","hash":"{hash}","compiled_at":"{ISO timestamp}"}
```

Line 2-3 — imports:
```typescript
import { test, expect } from '@playwright/test';
```

Then the test block. For each step in the compiled output:
- Add a comment: `// Step {n}: {intent}`
- For each action in the step:
  - `goto` → `await page.goto({value});` (convert `env:VAR` to `process.env.VAR!`)
  - `fill` → `await page.{selector}.fill({value});`
  - `click` → `await page.{selector}.click();`
  - `check` → `await page.{selector}.check();`
  - `select` → `await page.{selector}.selectOption({value});`
  - `press_key` → `await page.keyboard.press({value});`
  - `expect_visible` → `await expect(page.{selector}).toBeVisible();`
  - `expect_text` → `await expect(page.{selector}).toHaveText({value});`
  - `expect_url` → `await expect(page).toHaveURL({value});`

For values with `env:` prefix, convert to `process.env.VARNAME!`.
For literal string values, wrap in quotes.

Write the file to `qagent-scripts/{flow-name}.spec.ts`.

Output:
```
  {n}. {flow-name} ........... OK ({step-count} steps → {flow-name}.spec.ts)
```

### 3.5 Selector validation

After receiving the compiled steps from the subagent, validate every selector before generating the script.

For each action that has a selector:
1. Use `evaluate_script` on the still-open browser page to count how many elements match the selector
2. If count = 1 → selector is valid
3. If count = 0 → selector is broken. Ask the subagent to re-discover this selector, or mark the step with a warning.
4. If count > 1 → **strict mode violation**. The selector is ambiguous. Fix it:
   - Try scoping to a parent container (e.g., `locator('main').getByText(...)`)
   - If scoping doesn't help, append `.first()` and add a note: `"note": "used .first() — {count} matches"`
   - Update the selector in the compiled output before generating the script

This prevents Playwright's strict mode errors at runtime. Every selector in the generated script must resolve to exactly 1 element.

### 3.6 Generate .spec.ts file (smoke-run validated)

Generate the `.spec.ts` file from the validated compiled output (same as previous 3.4).

After writing the file, **immediately run it once** as a smoke test:

```bash
cd qagent-scripts && QAGENT_APP_URL="{url}" QAGENT_AUTH_USER_USERNAME="{user}" QAGENT_AUTH_USER_PASSWORD="{pass}" npx playwright test {flow-name}.spec.ts --reporter=json 2>&1
```

Check the result:
- **Pass** → script is valid. Output:
  ```
    {n}. {flow-name} ........... OK ({step-count} steps → {flow-name}.spec.ts) ✓ smoke-run passed
  ```
- **Fail** → analyze the error and auto-fix:
  - **Strict mode error** (matched N elements) → add `.first()` to the offending selector, or scope it to a container. Re-run.
  - **Timeout** (element not found) → the selector doesn't match anything on the page. Re-discover it via the subagent or mark the flow as failed.
  - **Other error** → log the error, mark the flow as failed compilation.
  - Max 2 auto-fix attempts per flow. If still failing after 2 retries, mark as FAILED.

Output on smoke-run failure after retries:
```
  {n}. {flow-name} ........... FAILED (smoke-run: {error description})
```

### 3.7 Handle compilation failure

If the subagent returns an error, the flow cannot be navigated, or the smoke-run fails after retries:

```
  {n}. {flow-name} ........... FAILED ({error description})
```

Do not generate a script file for this flow (delete any partial `.spec.ts`). It will use LLM fallback during `/qagent:test`.

### 3.8 Close browser page

After each flow, close the browser page used by the subagent (same cleanup as `/qagent:test`).

## Phase 4: Summary

```
Compiled: {success}/{total} flows ({failed} failed, {skipped} skipped)
Scripts saved to qagent-scripts/
```

## Important Rules

- **NEVER** log or output secret values
- Secret values in generated scripts must use `process.env.QAGENT_*` — never hardcoded
- Only generate scaffold files if they don't already exist
- Skip flows with matching hash unless `--force` is passed
- If a flow fails to compile, skip it — don't block other flows
- **Do NOT add `qagent-scripts/` to `.gitignore`.** The compiled scripts must be committed to git — they are reviewable, version-controlled test artifacts. Only `qagent-scripts/node_modules/` and `qagent-scripts/test-results/` should be gitignored. If `.gitignore` needs updating, add only those two entries, never a blanket `qagent-scripts/`.
