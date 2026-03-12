#!/usr/bin/env bash
# Usage: echo '{"text":"..."}' | slack.sh <webhook_url>
# Sends a JSON payload to a Slack incoming webhook.

set -euo pipefail

WEBHOOK_URL="${1:?Usage: slack.sh <webhook_url>}"

PAYLOAD=$(cat -)

RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H 'Content-type: application/json' \
  --data-raw "$PAYLOAD" \
  "$WEBHOOK_URL")

if [ "$RESPONSE" -ne 200 ]; then
  echo "Error: Slack webhook returned HTTP $RESPONSE" >&2
  exit 1
fi

echo "Slack notification sent successfully"
