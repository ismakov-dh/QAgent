---
name: report
description: Re-send the results of the last QAgent test run to a specified output channel. Use after a test run to send results to Slack, Telegram, etc.
argument-hint: [channel]
allowed-tools: Read, Bash, Write
---

# Re-Report QAgent Results

Re-send the last test run's results to a specified channel.

## Input

`$ARGUMENTS` = the reporter channel name (e.g., `slack`, `telegram`, `json`, `console`)

If no argument provided, default to `console`.

## Steps

1. **Find the last run**
   - Read `qagent-reports/latest.json`
   - If it doesn't exist, look for the most recent `qagent-plan-*.json` file in `qagent-reports/`
   - If no reports found, error: "No QAgent reports found. Run `/qagent:test` first."

2. **Load config for reporter settings**
   - Read `qagent.json` to get reporter configurations (webhook URLs, bot tokens, etc.)
   - Config discovery order: (1) current working directory, (2) nearest ancestor directory containing `.git`
   - Resolve any `secret:` references needed for the reporter:
     - `"provider": "file"` → read from `{secrets.path}/{KEY}`
     - `"provider": "env"` → read env var `$KEY`
     - No provider → fall back to env var `$KEY`

3. **Dispatch reporter subagent**
   - Pass the completed plan and the specific reporter config for the requested channel
   - The reporter subagent handles formatting and delivery
   - For `console`: reporter outputs formatted text to stdout
   - For `json`: reporter saves full report to configured path
   - For `slack`: reporter sends summary to Slack webhook using `${CLAUDE_PLUGIN_ROOT}/scripts/reporters/slack.sh`
   - For `telegram`: reporter sends summary to Telegram using `${CLAUDE_PLUGIN_ROOT}/scripts/reporters/telegram.sh`

4. **Confirm delivery**
   - Output confirmation: "Results sent to {channel}."
   - If delivery failed, output the error from the reporter
