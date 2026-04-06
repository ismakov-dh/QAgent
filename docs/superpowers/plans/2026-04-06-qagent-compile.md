# QAgent Compile Skill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `/qagent:compile` skill that generates Playwright Test scripts from flow definitions, plus integrate a fast-path script runner into `/qagent:test` with hash-based staleness detection and self-healing recompilation.

**Architecture:** New `compile` skill dispatches `script-compiler` subagent per flow. Subagent navigates the app via MCP, discovers selectors, returns structured data. Compile skill generates `.spec.ts` files. Test skill checks for scripts before dispatching LLM subagents — runs scripts via `npx playwright test` when available.

**Tech Stack:** Claude Code plugin (SKILL.md, agents/*.md), Playwright Test (`@playwright/test`), TypeScript, MCP browser tools

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `agents/script-compiler.md` | Create | Subagent — navigates a flow, discovers selectors, returns compiled step data |
| `skills/compile/SKILL.md` | Create | New skill — orchestrates compilation of flows into Playwright scripts |
| `skills/test/SKILL.md` | Modify | Add Phase 3.0.5 (script check), fast path execution, recompile prompts |
| `.gitignore` | Modify | Add `qagent-scripts/node_modules/` and `qagent-scripts/test-results/` |

---

## Task 1: Create `script-compiler` subagent

**Files:**
- Create: `agents/script-compiler.md`

- [ ] **Step 1: Create the subagent file**

Write `agents/script-compiler.md` with the following content:

```markdown
---
name: script-compiler
description: Navigates a single flow in the browser, discovers selectors for each step, and returns structured compilation data for Playwright script generation.
allowed-tools: Read, Write, Bash, mcp__chrome-devtools__*, mcp__playwright__*
---

# Script Compiler

You navigate a web application flow step by step, discover the best selectors for each interactive element, and return structured data that will be used to generate a Playwright Test script.

## Input

You receive:
- **Flow definition**: JSON object with `name`, `role`, `steps[]` (each with `intent`)
- **App URL**: The base URL of the web app
- **Auth credentials**: Username/password (already resolved from secrets) for the flow's role
- **Browser type**: `chrome-devtools` or `playwright` — which MCP tools to use

## Process

1. Open a browser page to the app URL
2. For each step in the flow:
   a. Interpret the natural language `intent`
   b. Perform the action via MCP browser tools (navigate, click, fill, etc.)
   c. Take a screenshot to see the current page state
   d. **Discover the best selector** for the element you acted on (see Selector Strategy below)
   e. Record a compilation entry with: action type, selector, input value (if any), assertion (if any)
3. Return the full list of compiled steps as JSON

## Selector Strategy

Discover selectors using this priority (most stable first):

| Priority | Type | Playwright API | When to use |
|----------|------|----------------|-------------|
| 1 | `data-testid` / `data-test-id` | `getByTestId('submit-btn')` | Always prefer if present on the element |
| 2 | Role + accessible name | `getByRole('button', { name: 'Submit' })` | Semantic elements with labels or accessible names |
| 3 | Text content | `getByText('Save changes')` | Visible, stable text that uniquely identifies the element |
| 4 | `id` attribute | `locator('#email')` | Unique IDs that don't look auto-generated |
| 5 | Short CSS selector | `locator('.checkout-btn')` | Only if none of the above work |

**To discover selectors:**
- After performing the action, use `evaluate_script` to inspect the target element's attributes
- Check for `data-testid`, `data-test-id`, `role`, `aria-label`, `id`, `class` in that order
- For text-based selectors, use the visible text content of the element
- When multiple candidates exist, prefer the one most likely to survive a UI refactor

**Never use:**
- Full XPath (`/html/body/div[2]/div/form/button`)
- Deeply nested CSS (`div > div > span:nth-child(3)`)
- Auto-generated class names (`._a3bc2f`, `.css-1x2y3z`)
- Framework-internal attributes (`data-reactid`, `ng-`)

## Handling credentials in output

- For values that are credentials (username, password), use the `env:` prefix: `"value": "env:QAGENT_AUTH_USER_USERNAME"`
- For the app URL, use `"value": "env:QAGENT_APP_URL"`
- For literal values (text to type in a search box, etc.), use the value directly: `"value": "search query"`

## Output Format

Return a JSON object with the compiled steps:

```json
{
  "flow": "login-flow",
  "steps": [
    {
      "intent": "Login as user",
      "actions": [
        { "type": "goto", "selector": null, "value": "env:QAGENT_APP_URL" },
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

### Action types

| Type | Playwright code | When to use |
|------|----------------|-------------|
| `goto` | `page.goto(value)` | Navigating to a URL |
| `fill` | `page.{selector}.fill(value)` | Typing into an input field |
| `click` | `page.{selector}.click()` | Clicking a button, link, or element |
| `check` | `page.{selector}.check()` | Checking a checkbox |
| `select` | `page.{selector}.selectOption(value)` | Selecting from a dropdown |
| `press_key` | `page.keyboard.press(value)` | Pressing a keyboard key |
| `expect_visible` | `expect(page.{selector}).toBeVisible()` | Asserting an element is visible |
| `expect_text` | `expect(page.{selector}).toHaveText(value)` | Asserting element has specific text |
| `expect_url` | `expect(page).toHaveURL(value)` | Asserting the page URL |

## Important

- Take a screenshot after each step — you need to see the page to discover selectors
- Never output credential values in your response — use `env:` prefixes
- If you cannot find a reliable selector for an element, note it in the output: `"selector": null, "note": "could not find stable selector"`
- If a step fails (element not found, action errors), stop and return what you have with an error: `"error": "description of what went wrong"`
```

- [ ] **Step 2: Verify the file**

```bash
head -5 agents/script-compiler.md
```

Expected: YAML frontmatter with `name: script-compiler`.

- [ ] **Step 3: Commit**

```bash
git add agents/script-compiler.md
git commit -m "feat: add script-compiler subagent for Playwright script generation"
```

---

## Task 2: Create `/qagent:compile` skill

**Files:**
- Create: `skills/compile/SKILL.md`

- [ ] **Step 1: Create the skill directory**

```bash
mkdir -p skills/compile
```

- [ ] **Step 2: Write the SKILL.md**

Write `skills/compile/SKILL.md` with the following content:

```markdown
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
    "@playwright/test": "latest"
  }
}
```

Only generate if `qagent-scripts/package.json` does not already exist.

### 2.3 Generate playwright.config.ts

Write `qagent-scripts/playwright.config.ts`:
```typescript
import { defineConfig } from '@playwright/test';

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

### 3.5 Handle compilation failure

If the subagent returns an error or the flow cannot be navigated:

```
  {n}. {flow-name} ........... FAILED ({error description})
```

Do not generate a script file for this flow. It will use LLM fallback during `/qagent:test`.

### 3.6 Close browser page

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
```

- [ ] **Step 3: Verify the file**

```bash
head -6 skills/compile/SKILL.md
```

Expected: YAML frontmatter with `name: compile`.

- [ ] **Step 4: Commit**

```bash
git add skills/compile/SKILL.md
git commit -m "feat: add /qagent:compile skill — generates Playwright Test scripts"
```

---

## Task 3: Add Phase 3.0.5 to `/qagent:test` — script check and fast path

**Files:**
- Modify: `skills/test/SKILL.md`

The new Phase 3.0.5 goes between the existing Phase 3.0 (Choose execution strategy, ends with "Output the chosen strategy" block) and Phase 3.1 (Open a dedicated browser page).

- [ ] **Step 1: Insert Phase 3.0.5 after Phase 3.0**

In `skills/test/SKILL.md`, after the line:
```
Execution: {sequential|parallel} ({reason})
```
(which is the end of Phase 3.0's output block), insert the following new section:

```markdown
### 3.0.5 Script check (compiled fast path)

Before opening browser pages, check each flow for compiled Playwright Test scripts. Compiled scripts run via `npx playwright test` and are much faster than LLM-driven execution.

For each flow in the plan:

**1. Compute flow hash:**
Serialize the flow's key fields: `JSON.stringify({name: flow.name, role: flow.role, steps: flow.steps})`. Hash with SHA-256, truncate to 8 hex chars.

**2. Check for compiled script:**
Look for `qagent-scripts/{flow-name}.spec.ts`. If it exists, read the first line and parse the `qagent-compiled` JSON comment to extract the stored hash.

**3. Decide execution path:**

| Script exists? | Hash match? | Trigger | Action |
|---|---|---|---|
| Yes | Yes | any | **Fast path** — run script via Playwright Test |
| Yes | No | manual | Prompt: "Flow '{name}' has changed since last compile. Recompile / Run stale / LLM fallback?" |
| Yes | No | ci | Run stale script, log warning: "⚠ Stale script for '{name}' — consider recompiling" |
| No | — | manual | Prompt: "No compiled script for '{name}'. Compile now / LLM fallback?" |
| No | — | ci | LLM fallback (no prompt) |

**Fast path execution:**

1. Set environment variables from resolved config:
   - `QAGENT_APP_URL` — app URL
   - `QAGENT_AUTH_{ROLE}_USERNAME` — for each auth role (role name uppercased)
   - `QAGENT_AUTH_{ROLE}_PASSWORD` — for each auth role
2. Run:
   ```bash
   cd qagent-scripts && QAGENT_APP_URL="{url}" QAGENT_AUTH_USER_USERNAME="{user}" QAGENT_AUTH_USER_PASSWORD="{pass}" npx playwright test {flow-name}.spec.ts --reporter=json
   ```
3. Parse `qagent-scripts/test-results/results.json`
4. Map Playwright results to QAgent flow format:
   - Playwright pass → flow `status: "passed"`, each test step → step `status: "passed"`
   - Playwright fail → flow `status: "failed"`, include error message and screenshot path in `observation`
5. Return the flow result to the plan

**Script-executed flows skip the MCP browser page lifecycle (Phases 3.1/3.3).** Playwright Test manages its own browser. Only LLM-fallback flows need MCP pages.

**Script failure in manual mode:**
```
Script for '{name}' failed:
  {Playwright error message}

Recompile this flow? [y/n]
```
- **y** → dispatch `script-compiler` subagent for this flow, regenerate `.spec.ts`, re-run via fast path
- **n** → keep the failure result as-is

**Script failure in CI mode:**
Log the failure with Playwright error output. Include in the test report. No auto-recompile.

**Recompile during test:**
When the user chooses to recompile (hash mismatch or script failure):
1. Dispatch `script-compiler` subagent for that single flow (same as `/qagent:compile` Phase 3.3)
2. Write the new `.spec.ts` file
3. Re-run the script via fast path
4. Continue to next flow

After all script checks are resolved, proceed to Phase 3.1 for any remaining LLM-fallback flows.
```

- [ ] **Step 2: Verify the insertion**

Read `skills/test/SKILL.md` and verify Phase 3.0.5 appears between Phase 3.0 and Phase 3.1.

- [ ] **Step 3: Commit**

```bash
git add skills/test/SKILL.md
git commit -m "feat: add script check and fast path to /qagent:test (Phase 3.0.5)"
```

---

## Task 4: Update .gitignore

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add qagent-scripts entries**

Append to the existing `.gitignore`:

```
# QAgent compiled scripts (build artifacts)
qagent-scripts/node_modules/
qagent-scripts/test-results/
```

- [ ] **Step 2: Verify the file**

Read `.gitignore` to confirm the new entries are present alongside existing entries.

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore qagent-scripts/node_modules and test-results"
```

---

## Task 5: Verify and push

**Files:**
- All modified/created files

- [ ] **Step 1: Verify new files exist**

```bash
ls -la agents/script-compiler.md skills/compile/SKILL.md
```

Expected: Both files exist.

- [ ] **Step 2: Verify YAML frontmatter**

```bash
head -5 agents/script-compiler.md
head -6 skills/compile/SKILL.md
```

Expected: Both start with `---` and have `name:`, `description:`, `allowed-tools:` fields.

- [ ] **Step 3: Verify git status is clean**

```bash
git status
```

Expected: nothing to commit, working tree clean

- [ ] **Step 4: Push to remote**

```bash
git push origin main
```

Expected: Push succeeds.
