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

   **Resolve changelog:**
   - If `changelog` is a string → use as-is
   - If `changelog` is an object with `sources` → resolve each source:
     - `type: "git"` → detect default branch (`git symbolic-ref refs/remotes/origin/HEAD`, fall back to `main`/`master`). If none exist, error and exit. Find merge-base, collect commits + changed files. Path is relative to `qagent.json` directory, not CWD.
     - `type: "url"` → `curl -s -m 10 "{url}"`. If fails, log warning and skip.
     - `type: "text"` → use `content` as-is.
   - If `changelog` is omitted → default to git auto-detect from current repo
   - If all sources fail → warn "No changelog available — flow inference will be limited to config flows only" and use empty string
   - Combine all sources into one changelog string for plan generation

2. **Validate secrets**
   - Find all `secret:KEY` references in the config
   - Check the configured secrets provider:
     - `"provider": "file"` → check files exist at `{path}/{KEY}`
     - `"provider": "env"` → check env vars exist
     - No provider configured → check env vars as fallback
   - List any unresolvable secrets but do NOT output their values
   - If secrets are missing → **STOP** and output error listing the unresolved keys (same behavior as `/qagent:test` — plan generation validates that the config is runnable)

3. **Detect trigger**
   - If `trigger` is set in config and is not `"auto"` → use it
   - If env var `CI=true` or `QAGENT_CI=true` → `"ci"`
   - Otherwise → `"manual"`

4. **Generate test plan**

   Create a plan JSON object:
   ```json
   {
     "app": "<app name>",
     "url": "<app url>",
     "trigger": "<manual|ci>",
     "changelog_summary": "<changelog text>",
     "generated_at": "<ISO timestamp>",
     "flows": []
   }
   ```

   **Config flows:** For each flow in `qagent.json` → `flows[]`, add it to the plan with `source: "config"`, converting each step's `action`/`target`/`expect` into a natural language `intent`. Assign sequential IDs (`flow-1`, `flow-2`, ...) and step IDs (`s1`, `s2`, ...).

   **Inferred flows** (if `inference` is not `false`):
   - Parse the resolved changelog for bug fixes → generate 1 regression test flow per fix
   - Parse the changelog for new features → generate 1 smoke test flow per feature
   - Cap at `limits.max_inferred_flows` (default 5)
   - Each inferred flow must include `reasoning` explaining why it was generated
   - Mark as `source: "inferred"`

   All steps start with `status: "pending"`.

5. **Output the plan**

   Print the plan as formatted JSON to stdout. Also save to `qagent-reports/qagent-plan-draft.json`.

   Display a human-readable summary:
   ```
   QAgent Test Plan — {app name} ({url})

   Flows to execute:
   1. {flow-name} ({source}) — {step count} steps
      {reasoning if inferred}
   2. ...

   Total: {N} flows ({M} from config, {K} inferred)
   ```
