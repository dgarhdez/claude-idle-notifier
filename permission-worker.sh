#!/usr/bin/env bash
# Background worker: waits DELAY seconds, sends permission prompt to Telegram
# with Allow/Always Allow/Deny buttons, polls for reply, injects into kitty.
# Called by permission-hook.sh (backgrounded). Expects env vars:
#   SCRIPT_DIR, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TOOL_NAME, TOOL_INPUT,
#   PID_FILE, DELAY

# Survive parent exit (macOS has no setsid)
trap '' HUP

LOG="/tmp/claude-idle-notify.log"
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }

log "--- permission-worker started (delay=${DELAY}s, tool=${TOOL_NAME}) ---"

sleep "$DELAY"

# Format the permission message from tool_name + tool_input
MESSAGE=$(TOOL_NAME="$TOOL_NAME" TOOL_INPUT="$TOOL_INPUT" python3 << 'PYEOF'
import os, json

tool_name = os.environ.get("TOOL_NAME", "Unknown")
try:
    tool_input = json.loads(os.environ.get("TOOL_INPUT", "{}"))
except (json.JSONDecodeError, TypeError):
    tool_input = {}

# Format based on tool type
if tool_name == "Bash":
    cmd = tool_input.get("command", "")
    if len(cmd) > 300:
        cmd = cmd[:300] + "..."
    detail = cmd
elif tool_name in ("Edit", "Write"):
    detail = tool_input.get("file_path", str(tool_input))
elif tool_name == "Read":
    detail = tool_input.get("file_path", str(tool_input))
elif tool_name == "Glob":
    detail = tool_input.get("pattern", str(tool_input))
elif tool_name == "Grep":
    pattern = tool_input.get("pattern", "")
    path = tool_input.get("path", "")
    detail = f"{pattern}" + (f" in {path}" if path else "")
elif tool_name == "NotebookEdit":
    detail = tool_input.get("notebook_path", str(tool_input))
else:
    # Generic: show tool_input as compact JSON, truncated
    detail = json.dumps(tool_input, ensure_ascii=False)
    if len(detail) > 300:
        detail = detail[:300] + "..."

print(f"\U0001f510 Permission Request\n\n{tool_name}: {detail}")
PYEOF
)

if [[ -z "$MESSAGE" ]]; then
    MESSAGE="Permission Request: ${TOOL_NAME}"
    log "format: fallback to plain text"
fi

log "sending permission message: ${MESSAGE:0:80}..."

# Send Telegram message with inline keyboard buttons
OFFSET_FILE="/tmp/claude-idle-tg-offset"
POLLER_PID_FILE="/tmp/claude-perm-poller.pid"

export MESSAGE
SENT_MSG_ID=$(python3 2>>"$LOG" << 'PYEOF'
import os, sys, json, urllib.request, urllib.parse

token = os.environ["TELEGRAM_BOT_TOKEN"]
chat_id = os.environ["TELEGRAM_CHAT_ID"]
message = os.environ.get("MESSAGE", "Permission Request")

keyboard = [
    [
        {"text": "Allow", "callback_data": "perm_allow"},
        {"text": "Always Allow", "callback_data": "perm_always"},
        {"text": "Deny", "callback_data": "perm_deny"}
    ]
]

payload = {
    "chat_id": chat_id,
    "text": message,
    "reply_markup": json.dumps({"inline_keyboard": keyboard})
}

data = urllib.parse.urlencode(payload).encode()
url = f"https://api.telegram.org/bot{token}/sendMessage"
try:
    resp = urllib.request.urlopen(url, data, timeout=10)
    body = json.loads(resp.read())
    if body.get("ok"):
        msg_id = body["result"]["message_id"]
        print(msg_id)  # stdout: captured by SENT_MSG_ID
        print(f"send: ok (message_id={msg_id})", file=sys.stderr)
    else:
        print(f"send: telegram error: {body}", file=sys.stderr)
except Exception as e:
    print(f"send: exception: {e}", file=sys.stderr)
PYEOF
)

if [[ -z "$SENT_MSG_ID" ]]; then
    log "send failed, no message_id — aborting"
    rm -f "$PID_FILE"
    exit 1
fi
log "sent message_id=$SENT_MSG_ID"

# Poll for button tap and inject into kitty
# Reuses the same offset file as idle notifications
log "starting permission poller"

# Read last known offset
if [[ -f "$OFFSET_FILE" ]]; then
    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null)
else
    # Drain all existing updates so we only see new ones
    LATEST=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=-1" \
        | python3 -c "import sys,json; r=json.load(sys.stdin).get('result',[]); print(r[-1]['update_id']+1 if r else '')" 2>/dev/null)
    if [[ -n "$LATEST" ]]; then
        OFFSET="$LATEST"
    else
        OFFSET=""
    fi
fi

echo $$ > "$POLLER_PID_FILE"

MAX_WAIT=300  # 5 minutes max
ELAPSED=0
POLL_TIMEOUT=30  # long-poll 30s per request

while (( ELAPSED < MAX_WAIT )); do
    OFFSET_PARAM=""
    if [[ -n "$OFFSET" ]]; then
        OFFSET_PARAM="&offset=$OFFSET"
    fi

    RESP_FILE=$(mktemp /tmp/claude-perm-resp.XXXXXX)
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=${POLL_TIMEOUT}&allowed_updates=%5B%22callback_query%22%5D${OFFSET_PARAM}" > "$RESP_FILE"

    REPLY_TEXT=$(TG_CHAT_ID="$TELEGRAM_CHAT_ID" RESP_FILE="$RESP_FILE" SENT_MSG_ID="$SENT_MSG_ID" python3 << 'PYEOF'
import os, sys, json

chat_id = os.environ["TG_CHAT_ID"]
sent_msg_id = int(os.environ["SENT_MSG_ID"])

with open(os.environ["RESP_FILE"]) as f:
    response = json.load(f)

results = response.get("result", [])

for update in results:
    uid = update["update_id"]

    cq = update.get("callback_query")
    if cq:
        cq_chat = str(cq.get("message", {}).get("chat", {}).get("id", ""))
        cq_from = str(cq.get("from", {}).get("id", ""))
        cq_msg_id = cq.get("message", {}).get("message_id")
        if (cq_chat == chat_id or cq_from == chat_id) and cq_msg_id == sent_msg_id:
            data = cq.get("data", "")
            if data.startswith("perm_"):
                cq_id = cq.get("id", "")
                print(f"{uid + 1}|{data}|{cq_id}")
                sys.exit(0)

# No relevant reply — update offset
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

    # If we got a permission button tap, handle it
    if [[ -n "$REPLY" ]]; then
        # Answer callback query
        if [[ -n "$CALLBACK_ID" ]]; then
            # Map callback_data to human-readable label
            case "$REPLY" in
                perm_allow)  LABEL="Allow" ;;
                perm_always) LABEL="Always Allow" ;;
                perm_deny)   LABEL="Deny" ;;
                *)           LABEL="$REPLY" ;;
            esac
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/answerCallbackQuery" \
                -d callback_query_id="$CALLBACK_ID" \
                -d text="Sent: $LABEL" \
                > /dev/null 2>&1
        fi

        # Map callback_data to keypress for Claude Code permission dialog
        # Permission prompts: y=Allow, a=Always Allow, n=Deny
        case "$REPLY" in
            perm_allow)  KEYPRESS="y" ;;
            perm_always) KEYPRESS="a" ;;
            perm_deny)   KEYPRESS="n" ;;
            *)           KEYPRESS="" ;;
        esac

        if [[ -n "$KEYPRESS" ]]; then
            log "permission reply: $REPLY -> keypress '$KEYPRESS'"

            # Target the correct kitty window (not just most-recent)
            KITTY_SOCK=$(ls -t /tmp/kitty-sock-* 2>/dev/null | head -1)
            if [[ -n "$KITTY_WINDOW_ID" ]]; then
                MATCH="id:$KITTY_WINDOW_ID"
            else
                MATCH="recent:0"
            fi
            log "kitty match: $MATCH"

            if [[ -S "$KITTY_SOCK" ]]; then
                printf '%s' "$KEYPRESS" | kitty @ --to unix:"$KITTY_SOCK" send-text --match "$MATCH" --stdin
                kitty @ --to unix:"$KITTY_SOCK" send-key --match "$MATCH" Return
                log "injected '$KEYPRESS' + Return via $KITTY_SOCK"
            else
                printf '%s' "$KEYPRESS" | kitty @ send-text --match "$MATCH" --stdin
                kitty @ send-key --match "$MATCH" Return
                log "injected '$KEYPRESS' + Return (no socket, fallback)"
            fi
        fi

        # Clean up
        rm -f "$POLLER_PID_FILE"
        rm -f "$PID_FILE"
        exit 0
    fi

    ELAPSED=$((ELAPSED + POLL_TIMEOUT))
done

# Timed out — clean up
log "permission poller timed out"
rm -f "$POLLER_PID_FILE"
rm -f "$PID_FILE"
