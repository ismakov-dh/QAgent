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

Discover selectors using this priority. Role-based and label-based selectors are the most resilient — they survive UI refactors, mirror how users perceive the page, and enforce accessible markup.

| Tier | Type | Playwright API | When to use |
|------|------|----------------|-------------|
| 1 | Role + accessible name | `getByRole('button', { name: 'Submit' })` | Interactive elements: buttons, links, headings, checkboxes, comboboxes, dialogs, navigation, tabs |
| 2 | Label | `getByLabel('Email')` | Form fields with visible `<label>`, `aria-label`, or `aria-labelledby` — most readable selector for inputs |
| 3 | Text content | `getByText('Save changes')` | Non-interactive, static text: paragraphs, badges, status messages |
| 4 | Placeholder | `getByPlaceholder('Search...')` | Inputs without labels (signals an accessibility gap — note it) |
| 5 | Test ID | `getByTestId('submit-btn')` | Custom components with no semantic role, dynamically generated content, or when tiers 1-4 produce ambiguous matches |
| 6 | CSS selector | `locator('#email')` or `locator('.checkout-btn')` | Only when nothing above works — unique IDs or short class selectors that aren't auto-generated |

**Why `getByRole` first, not `getByTestId`:** Test IDs are stable but invisible to users. Role-based selectors validate that the app is accessible AND find elements by how users interact with them. A `getByRole('button', { name: 'Save' })` breaks when the button disappears or becomes inaccessible — which is a real bug worth catching. A `getByTestId('save-btn')` only breaks when a developer removes the attribute.

**To discover selectors:**
- After performing the action, use `evaluate_script` to inspect the target element's attributes
- Check for `role`, `aria-label`, `aria-labelledby`, associated `<label>`, `placeholder`, `data-testid`, `id`, `class` — in that order
- For form fields, prefer `getByLabel()` — it's the most readable and validates label association
- For buttons and links, prefer `getByRole()` with `name` option
- For static text, use `getByText()` with `{ exact: true }` when the text is short or common
- When multiple candidates exist, prefer the one most likely to survive a UI refactor
- **Only use selectors you actually observed** in the DOM or accessibility snapshot. Never guess class names or attributes — if you didn't see it, don't use it.

**CRITICAL — Every selector must be unique (resolve to exactly 1 element):**

After discovering a selector candidate, **validate it resolves to exactly 1 element** by running:
```javascript
document.querySelectorAll('[data-testid="..."]').length  // for CSS
// or use evaluate_script to count matches
```

If a selector matches multiple elements:
1. **Scope it** to a parent container: `locator('nav').getByText(...)` or `locator('[data-testid="sidebar"]').getByRole(...)`
2. If scoping isn't possible, use `.first()` — but only as a last resort and note it in the output: `"note": "used .first() — multiple matches"`
3. For regex text selectors, always scope to a container

**Never use:**
- Full XPath (`/html/body/div[2]/div/form/button`)
- Deeply nested CSS (`div > div > span:nth-child(3)`)
- Auto-generated class names (`._a3bc2f`, `.css-1x2y3z`)
- Framework-internal attributes (`data-reactid`, `ng-`)
- Guessed CSS class selectors — only use classes you see in the actual DOM

### Common Selector Pitfalls

These patterns cause the majority of strict mode failures in real apps. Check for each one during selector discovery.

#### Duplicate text across page regions

Text often appears in multiple DOM nodes — sidebar labels, role badges, pagination controls (top + bottom), status badges in both table cells and filter dropdowns, tab labels as both `<button>` and heading inside the panel. **Assume any visible text could appear more than once.**

After finding a text-based selector, always validate the count. If >1, scope to the nearest unique container:
```typescript
// BAD — "Admin" appears in sidebar badge AND user profile
page.getByText('Admin')

// GOOD — scoped to specific region
page.locator('nav').getByText('Admin')
// or as last resort
page.getByText('Admin', { exact: true }).first()
```

For pagination buttons (often duplicated top + bottom), always add `.first()`:
```typescript
page.getByRole('button', { name: '2', exact: true }).first().click()
```

#### Dual-render components (hidden native + visible custom)

Many UI frameworks render form controls as BOTH a hidden native element (for form submission/accessibility) and a visible custom widget. For example, a dropdown may have:
- A hidden `<select>` with `<option>` children (native)
- A visible popover with `<div role="option">` items (custom)

This means `getByText('Option')` matches both the hidden `<option>` and the visible `<span>`, causing strict mode failure. Even `getByRole('option')` matches both — Playwright detects the implicit ARIA role on native `<option>` elements.

**Key distinction:** `getByRole('option')` matches **implicit** ARIA roles (native elements), while `locator('[role="option"]')` matches only **explicit** `role` HTML attributes (custom elements). Use the CSS attribute selector to target only the visible custom items:
```typescript
// Open the dropdown trigger
page.locator('button[role="combobox"]').first().click()
// Select an option — CSS attribute selector skips native <option> elements
page.locator('[role="option"]').filter({ hasText: 'Option text' }).click()
```

When you open a dropdown and the items do NOT have `role="option"` (e.g., checkbox-style popover menus), fall back to:
```typescript
page.getByText('Item text', { exact: true }).click()
page.keyboard.press('Escape')  // close popover
```

After opening any dropdown, inspect what role the items have (`role="option"`, `role="menuitemcheckbox"`, plain text) and choose the selector accordingly.

#### Non-link, non-button clickable elements

Cards, list items, and queue entries are often custom components — not `<a>` or `<button>`. Standard role-based selectors won't find them.

Fallback chain:
1. Check for `<a>` links: `page.locator('a[href*="/expected-path/"]')`
2. If no links, find unique text content in each item (IDs, titles): `page.getByText(/^ITEM-\d+/).first()`
3. If no unique text, use `data-testid` on the card container
4. As last resort, use `page.evaluate()` to click via DOM query

#### Disabled buttons with prerequisites

Before generating a click action on a submit/finalize button, check if it is `disabled`. If disabled, there is likely a prerequisite action (e.g., a validation step, a required field, a pre-check button). Discover and add the prerequisite as a preceding step, then wait for the target button to become enabled:
```typescript
await page.getByRole('button', { name: 'Run validation' }).click();
await expect(page.getByRole('button', { name: 'Submit' })).toBeEnabled();
await page.getByRole('button', { name: 'Submit' }).click();
```

#### Navigate each flow — never guess selectors

For each flow you compile, you MUST:
1. Actually navigate the flow step by step in the browser
2. At each step, take a screenshot/snapshot and discover the exact selectors that work
3. Validate each selector resolves to exactly 1 element
4. Only then record the compiled step

Never batch-discover selectors from a single page load or guess selectors based on naming conventions. If you didn't see it in the DOM at the step you're compiling, don't use it.

## Assertions and Waiting

Generated scripts must use Playwright's built-in auto-waiting and web-first assertions. Never add manual waits.

**Web-first assertions auto-retry** — they keep polling the DOM until the condition is met or timeout is reached:
```typescript
// GOOD — auto-retries until visible (up to timeout)
await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
await expect(page.getByTestId('total')).toHaveText('$99.00');
await expect(page.getByRole('listitem')).toHaveCount(5);
```

**Non-retrying assertions do NOT auto-retry** — the value is already resolved before the assertion runs:
```typescript
// BAD — resolves textContent() once, then asserts (no retry on stale value)
const text = await page.getByTestId('total').textContent();
expect(text).toBe('$99.00');

// GOOD — web-first equivalent
await expect(page.getByTestId('total')).toHaveText('$99.00');
```

**Rule:** If asserting something about the DOM, always use `await expect(locator)` — never `expect(await locator.something())`.

**Never use `page.waitForTimeout()`:**
```typescript
// BAD — arbitrary sleep, flaky in CI
await page.waitForTimeout(2000);

// GOOD — wait for the specific condition
await expect(page.getByRole('button', { name: 'Submit' })).toBeEnabled();
await page.waitForURL('**/dashboard');
await page.waitForLoadState('networkidle');
```

**Waiting for navigation:** After clicks that trigger navigation, use `waitForURL()` or assert on an element that only exists on the target page. Do not add sleeps.

**Soft assertions** — use `expect.soft()` only when you want to check multiple things without stopping on first failure:
```typescript
await expect.soft(page.getByText('Name')).toBeVisible();
await expect.soft(page.getByText('Email')).toBeVisible();
```
Use sparingly — hard assertions (default) are better because they stop the test at the first real problem.

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
        { "type": "fill", "selector": "getByLabel('Email')", "value": "env:QAGENT_AUTH_USER_USERNAME" },
        { "type": "fill", "selector": "getByLabel('Password')", "value": "env:QAGENT_AUTH_USER_PASSWORD" },
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
| `wait_for_url` | `page.waitForURL(value)` | Waiting for navigation to complete |
| `expect_visible` | `expect(page.{selector}).toBeVisible()` | Asserting element is visible (web-first, auto-retries) |
| `expect_hidden` | `expect(page.{selector}).not.toBeVisible()` | Asserting element disappeared (e.g., loading spinner) |
| `expect_text` | `expect(page.{selector}).toHaveText(value)` | Asserting element has specific text (web-first) |
| `expect_enabled` | `expect(page.{selector}).toBeEnabled()` | Asserting a button/input is enabled (use before clicking disabled buttons) |
| `expect_url` | `expect(page).toHaveURL(value)` | Asserting the page URL (web-first) |
| `expect_count` | `expect(page.{selector}).toHaveCount(value)` | Asserting number of matching elements |

**All `expect_*` actions are web-first assertions** — they auto-retry until the condition is met or timeout expires. Never resolve a value first and assert on the resolved value.

## Important

- Take a screenshot after each step — you need to see the page to discover selectors
- Never output credential values in your response — use `env:` prefixes
- If you cannot find a reliable selector for an element, note it in the output: `"selector": null, "note": "could not find stable selector"`
- If a step fails (element not found, action errors), stop and return what you have with an error: `"error": "description of what went wrong"`
- After opening any dropdown/popover, inspect what role the items have before choosing a selector strategy
- For every selector, assume text could be duplicated elsewhere on the page until you verify the count
- Prefer `getByRole()` and `getByLabel()` over `getByTestId()` — role/label selectors validate accessibility and survive refactors
- Never generate `page.waitForTimeout()` — use web-first assertions or `waitForURL()` instead
- All assertions must be web-first (`await expect(locator)`) — never `expect(await locator.textContent())`
- Generated tests should be isolated — no shared mutable state between independent tests
