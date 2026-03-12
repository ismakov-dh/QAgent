#!/usr/bin/env bash
# Usage: echo "message text" | telegram.sh <bot_token> <chat_id>
# Sends a message via Telegram Bot API.

set -euo pipefail

BOT_TOKEN="${1:?Usage: telegram.sh <bot_token> <chat_id>}"
CHAT_ID="${2:?Usage: telegram.sh <bot_token> <chat_id>}"

MESSAGE=$(cat -)

RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d parse_mode="Markdown" \
  --data-urlencode text="$MESSAGE")

if [ "$RESPONSE" -ne 200 ]; then
  echo "Error: Telegram API returned HTTP $RESPONSE" >&2
  exit 1
fi

echo "Telegram notification sent successfully"
