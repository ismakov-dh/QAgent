# QAgent

Automated UI and behavior testing for web apps — Claude orchestrates browser interactions, verifies state changes, and evolves test cases from failures.

A [Claude Code](https://claude.ai/claude-code) plugin.

## Install

In Claude Code, run:

```
/plugin marketplace add ismakov-dh/QAgent
/plugin install qagent@qagent
```

Or for local development/testing:

```bash
claude --plugin-dir /path/to/QAgent
```

### Browser MCP server

QAgent needs a browser to work. You need at least one of these:

**Chrome DevTools MCP** (recommended for local dev) — connect Claude Code to your browser via [Chrome DevTools MCP](https://github.com/anthropics/chrome-devtools-mcp).

**Playwright MCP** (recommended for CI) — add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"]
    }
  }
}
```

Uses [Microsoft Playwright MCP](https://github.com/microsoft/playwright-mcp).

## Quick start

1. Create a `qagent.json` in your project root:

```json
{
  "app": {
    "name": "My App",
    "url": "https://staging.example.com",
    "description": "What the app does"
  },
  "flows": [
    {
      "name": "login-flow",
      "role": "user",
      "steps": [
        { "action": "login" },
        { "action": "verify", "expect": "dashboard is visible" }
      ]
    }
  ]
}
```

2. Run tests:

```
/qagent:test
```

QAgent will load the config, open a browser, execute each flow step by step, take screenshots, and report results.

3. For faster runs, compile flows into Playwright scripts:

```
/qagent:compile
```

This navigates each flow once (LLM-driven), discovers real selectors, and generates `.spec.ts` files in `qagent-scripts/`. Subsequent `/qagent:test` runs execute these scripts directly — seconds instead of minutes.

## Skills

| Skill | Purpose |
|-------|---------|
| `/qagent:test` | Run tests — compiled scripts (fast) or LLM-driven (flexible), with auto-fallback |
| `/qagent:compile` | Compile flows into Playwright Test scripts — LLM discovers selectors once, scripts run in seconds |
| `/qagent:plan` | Generate a test plan without executing — preview what will be tested |
| `/qagent:explore` | Live brainstorming — open the app, explore interactively, discover test cases together |
| `/qagent:merge` | Merge test cases from a feature branch into the main test suite |
| `/qagent:report` | Re-send last run results to a specific channel (slack, telegram, json) |

## How it works

1. **Load config** — reads `qagent.json` for app URL, auth, flows, and settings
2. **Resolve changelog** — auto-detects changes from git history (or manual input)
3. **Generate plan** — config flows + inferred flows from changelog (regression tests for bug fixes, smoke tests for new features)
4. **Check for compiled scripts** — if a flow has a matching `.spec.ts` file (hash check), run it via Playwright Test (fast path). Otherwise fall back to LLM-driven execution.
5. **Execute flows** — compiled scripts run in parallel via Playwright Test workers; LLM flows open isolated browser pages per flow
6. **Learn from failures** — proposes new/updated test cases based on what went wrong
7. **Report** — console output + optional Slack, Telegram, or JSON reports

## Compiled scripts

`/qagent:compile` generates Playwright Test scripts from your flow definitions. The LLM navigates each flow once, discovers stable selectors (preferring `data-testid` > `role` > `text` > `id` > CSS), and writes `.spec.ts` files.

```
/qagent:compile                        # compile all flows
/qagent:compile login-flow             # compile specific flow
/qagent:compile --force                # recompile even if unchanged
```

Scripts are saved to `qagent-scripts/` and committed to git. When you edit a flow in `qagent.json`, `/qagent:test` detects the hash mismatch and asks to recompile. If a script fails at runtime, you're prompted to recompile or fall back to LLM.

Credentials are never hardcoded — scripts use `process.env.QAGENT_AUTH_*` variables, set automatically from your config's resolved secrets at runtime.

## Auth & secrets

Credentials use the `secret:KEY` prefix — never hardcoded:

```json
{
  "auth": {
    "user": {
      "username": "testuser@example.com",
      "password": "secret:USER_PASSWORD"
    }
  }
}
```

Resolved from env vars by default. For Docker, use file-based secrets:

```json
{
  "secrets": {
    "provider": "file",
    "path": "/var/run/secrets/qagent"
  }
}
```

## Changelog auto-detection

When no changelog is provided, QAgent derives it from git — commits and changed files since the branch diverged from main. Supports multiple sources including cross-repo:

```json
{
  "changelog": {
    "sources": [
      { "type": "git", "path": "." },
      { "type": "git", "path": "../backend" },
      { "type": "url", "url": "https://api.example.com/changelog.json" }
    ]
  }
}
```

## Branch-aware test management

Test cases discovered on feature branches carry metadata (`scope`, `branch`, `discovered_by`). Before merging:

```
/qagent:merge main
```

This deduplicates against main's test suite, asks about feature-scoped flows, and produces a clean merge.

## CI

Set `trigger: "ci"` or rely on auto-detection (`CI=true` env var). In CI mode:

- Compiled scripts run first (fast, parallel) — stale scripts run with warnings
- Flows without scripts fall back to LLM execution automatically
- Changelog auto-detected from git
- Learning loop writes proposals to a staging file (or auto-accepts)
- No auto-recompile — CI runs are deterministic
- Exit code 0 = pass, 1 = test failure, 2 = infrastructure error

## Full config reference

See [`templates/qagent-example.json`](templates/qagent-example.json) for all available options.

## License

MIT
