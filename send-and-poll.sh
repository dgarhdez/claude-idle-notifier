#!/usr/bin/env bash
# Background worker: waits DELAY seconds, sends Telegram message, starts poller.
# Called by notify-idle.sh via setsid. Expects env vars:
#   SCRIPT_DIR, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TRANSCRIPT_PATH, PID_FILE, DELAY

sleep "$DELAY"

# Parse transcript for context and options
PARSED=""
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    PARSED=$(python3 "$SCRIPT_DIR/parse-transcript.py" "$TRANSCRIPT_PATH" 2>/dev/null)
fi
if [[ -z "$PARSED" ]]; then
    PARSED='{"context": "Claude Code is waiting for your input.", "options": []}'
fi

# Save parsed JSON to temp file for safe access from python
export PARSED_FILE=$(mktemp /tmp/claude-idle-parsed.XXXXXX)
printf "%s" "$PARSED" > "$PARSED_FILE"

# Increment notification counter
COUNTER_FILE="/tmp/claude-idle-notify-counter"
if [[ -f "$COUNTER_FILE" ]]; then
    COUNT=$(( $(cat "$COUNTER_FILE" 2>/dev/null) + 1 ))
else
    COUNT=1
fi
echo "$COUNT" > "$COUNTER_FILE"
export NOTIFY_COUNT="$COUNT"

# Send Telegram message using python (avoids shell quoting issues with JSON)
python3 << 'PYEOF'
import os, json, urllib.request, urllib.parse
from datetime import datetime

token = os.environ["TELEGRAM_BOT_TOKEN"]
chat_id = os.environ["TELEGRAM_CHAT_ID"]
count = os.environ.get("NOTIFY_COUNT", "?")

with open(os.environ["PARSED_FILE"]) as f:
    parsed = json.load(f)

context = parsed.get("context", "Claude Code is waiting for your input.")
options = parsed.get("options", [])

timestamp = datetime.now().strftime("%H:%M:%S")
header = f"\U0001f514 #{count} \u2022 {timestamp}\n\n"
text = header + context

payload = {"chat_id": chat_id, "text": text}

if options:
    keyboard = [[{"text": opt["label"], "callback_data": opt["callback_data"]}] for opt in options]
    payload["reply_markup"] = json.dumps({"inline_keyboard": keyboard})

data = urllib.parse.urlencode(payload).encode()
url = f"https://api.telegram.org/bot{token}/sendMessage"
try:
    urllib.request.urlopen(url, data, timeout=10)
except Exception:
    pass
PYEOF

# Extract options JSON for the poller
OPTIONS_JSON=$(python3 -c "
import json, os
with open(os.environ['PARSED_FILE']) as f:
    print(json.dumps(json.load(f).get('options', [])))
" 2>/dev/null)
rm -f "$PARSED_FILE"

if [[ -z "$OPTIONS_JSON" ]]; then
    OPTIONS_JSON="[]"
fi

# Start polling for replies
bash "$SCRIPT_DIR/poll-reply.sh" "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" "$OPTIONS_JSON" &

rm -f "$PID_FILE"
