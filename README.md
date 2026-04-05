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
      "args": ["@anthropic-ai/playwright-mcp"]
    }
  }
}
```

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

## Skills

| Skill | Purpose |
|-------|---------|
| `/qagent:test` | Run tests — execute flows, verify state changes, propose new test cases from failures |
| `/qagent:plan` | Generate a test plan without executing — preview what will be tested |
| `/qagent:explore` | Live brainstorming — open the app, explore interactively, discover test cases together |
| `/qagent:merge` | Merge test cases from a feature branch into the main test suite |
| `/qagent:report` | Re-send last run results to a specific channel (slack, telegram, json) |

## How it works

1. **Load config** — reads `qagent.json` for app URL, auth, flows, and settings
2. **Resolve changelog** — auto-detects changes from git history (or manual input)
3. **Generate plan** — config flows + inferred flows from changelog (regression tests for bug fixes, smoke tests for new features)
4. **Execute flows** — opens isolated browser pages per flow, dispatches subagents to perform each step
5. **Learn from failures** — proposes new/updated test cases based on what went wrong
6. **Report** — console output + optional Slack, Telegram, or JSON reports

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

- Changelog auto-detected from git
- Learning loop writes proposals to a staging file (or auto-accepts)
- Exit code 0 = pass, 1 = test failure, 2 = infrastructure error

## Full config reference

See [`templates/qagent-example.json`](templates/qagent-example.json) for all available options.

## License

MIT
