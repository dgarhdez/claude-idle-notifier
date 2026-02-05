#!/usr/bin/env bash
# Poll Telegram for a reply (button tap or free text) and inject it into kitty.
# Usage: poll-reply.sh <bot_token> <chat_id> <options_json>
#   options_json: JSON array of {"label":"...","callback_data":"0"} or "[]"
# Runs until a reply is received or 5 minutes elapse.

BOT_TOKEN="$1"
CHAT_ID="$2"
OPTIONS_JSON="$3"
OFFSET_FILE="/tmp/claude-idle-tg-offset"
POLLER_PID_FILE="/tmp/claude-idle-poller.pid"

echo $$ > "$POLLER_PID_FILE"

# Save options to a temp file for safe passing to python
export OPTIONS_FILE=$(mktemp /tmp/claude-idle-options.XXXXXX)
printf '%s' "$OPTIONS_JSON" > "$OPTIONS_FILE"
trap 'rm -f "$OPTIONS_FILE"' EXIT

# Read last known offset (to skip old updates)
if [[ -f "$OFFSET_FILE" ]]; then
    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null)
else
    # Drain all existing updates so we only see new ones
    LATEST=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=-1" \
        | python3 -c "import sys,json; r=json.load(sys.stdin).get('result',[]); print(r[-1]['update_id']+1 if r else '')" 2>/dev/null)
    if [[ -n "$LATEST" ]]; then
        OFFSET="$LATEST"
    else
        OFFSET=""
    fi
fi

MAX_WAIT=300  # 5 minutes max
ELAPSED=0
POLL_TIMEOUT=30  # long-poll 30s per request

while (( ELAPSED < MAX_WAIT )); do
    OFFSET_PARAM=""
    if [[ -n "$OFFSET" ]]; then
        OFFSET_PARAM="&offset=$OFFSET"
    fi

    # Save response to temp file to avoid shell quoting issues
    export RESP_FILE=$(mktemp /tmp/claude-idle-resp.XXXXXX)
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=${POLL_TIMEOUT}&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D${OFFSET_PARAM}" > "$RESP_FILE"

    # Parse updates using python with file-based I/O (safe from quoting)
    REPLY_TEXT=$(TG_CHAT_ID="$CHAT_ID" python3 << 'PYEOF'
import os, sys, json

chat_id = os.environ["TG_CHAT_ID"]

with open(os.environ.get("RESP_FILE", "/dev/null")) as f:
    response = json.load(f)

with open(os.environ.get("OPTIONS_FILE", "/dev/null")) as f:
    options = json.load(f)

results = response.get("result", [])
cb_map = {opt["callback_data"]: opt["label"] for opt in options}

for update in results:
    uid = update["update_id"]

    # Check callback_query (button press)
    cq = update.get("callback_query")
    if cq:
        cq_chat = str(cq.get("message", {}).get("chat", {}).get("id", ""))
        cq_from = str(cq.get("from", {}).get("id", ""))
        if cq_chat == chat_id or cq_from == chat_id:
            data = cq.get("data", "")
            label = cb_map.get(data, data)
            cq_id = cq.get("id", "")
            print(f"{uid + 1}|{label}|{cq_id}")
            sys.exit(0)

    # Check message (free text)
    msg = update.get("message")
    if msg:
        if str(msg.get("chat", {}).get("id", "")) == chat_id:
            text = msg.get("text", "")
            if text:
                print(f"{uid + 1}|{text}|")
                sys.exit(0)

# No relevant reply found — just update offset
if results:
    last_uid = results[-1]["update_id"]
    print(f"{last_uid + 1}||")
PYEOF
    )

    rm -f "$RESP_FILE"

    if [[ -z "$REPLY_TEXT" ]]; then
        ELAPSED=$((ELAPSED + POLL_TIMEOUT))
        continue
    fi

    NEW_OFFSET=$(echo "$REPLY_TEXT" | cut -d'|' -f1)
    REPLY=$(echo "$REPLY_TEXT" | cut -d'|' -f2)
    CALLBACK_ID=$(echo "$REPLY_TEXT" | cut -d'|' -f3)

    # Save offset for next time
    if [[ -n "$NEW_OFFSET" ]]; then
        echo "$NEW_OFFSET" > "$OFFSET_FILE"
        OFFSET="$NEW_OFFSET"
    fi

    # If we got a reply, handle it
    if [[ -n "$REPLY" ]]; then
        # Answer callback query if it was a button press
        if [[ -n "$CALLBACK_ID" ]]; then
            curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/answerCallbackQuery" \
                -d callback_query_id="$CALLBACK_ID" \
                -d text="Sent: $REPLY" \
                > /dev/null 2>&1
        fi

        # Inject reply into kitty via unix socket (kitty appends PID to socket name)
        KITTY_SOCK=$(ls -t /tmp/kitty-sock-* 2>/dev/null | head -1)
        if [[ -S "$KITTY_SOCK" ]]; then
            printf '%s' "$REPLY" | kitty @ --to unix:"$KITTY_SOCK" send-text --match recent:0 --stdin
            kitty @ --to unix:"$KITTY_SOCK" send-key --match recent:0 Return
        else
            # Fallback: try without explicit socket (works if run inside kitty)
            printf '%s' "$REPLY" | kitty @ send-text --match recent:0 --stdin
            kitty @ send-key --match recent:0 Return
        fi

        # Clean up
        rm -f "$POLLER_PID_FILE"
        exit 0
    fi

    ELAPSED=$((ELAPSED + POLL_TIMEOUT))
done

# Timed out — clean up
rm -f "$POLLER_PID_FILE"
