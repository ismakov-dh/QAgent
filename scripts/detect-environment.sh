#!/usr/bin/env bash
# Usage: detect-environment.sh
# Outputs the detected browser provider: chrome-devtools, playwright, or none.
# Checks for MCP tool availability by looking at Claude Code's tool list.

set -euo pipefail

# Check for Chrome DevTools MCP tools
if claude --print-tools 2>/dev/null | grep -q "mcp__chrome-devtools__"; then
  echo "chrome-devtools"
  exit 0
fi

# Check for Playwright MCP tools
if claude --print-tools 2>/dev/null | grep -q "mcp__playwright__"; then
  echo "playwright"
  exit 0
fi

echo "none"
exit 1
