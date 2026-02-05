#!/usr/bin/env bash
# Hook: Notification (idle_prompt matcher)
# Parses the hook payload for transcript context, starts a background timer,
# and sends a rich Telegram notification with inline keyboard buttons.
# Spawns a reply poller that injects Telegram replies back into kitty.

# Read hook payload from stdin
INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/telegram.conf"
PID_FILE="/tmp/claude-idle-notify.pid"
DELAY=5

# Load Telegram credentials
if [[ ! -f "$CONF" ]]; then
    exit 0
fi
source "$CONF"

if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    exit 0
fi

# Extract transcript_path from hook payload
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

# Kill any existing timer/poller
if [[ -f "$PID_FILE" ]]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -n "$old_pid" ]]; then
        kill "$old_pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

POLLER_PID_FILE="/tmp/claude-idle-poller.pid"
if [[ -f "$POLLER_PID_FILE" ]]; then
    poller_pid=$(cat "$POLLER_PID_FILE" 2>/dev/null)
    if [[ -n "$poller_pid" ]]; then
        kill "$poller_pid" 2>/dev/null
    fi
    rm -f "$POLLER_PID_FILE"
fi

# Export everything the background process needs
export SCRIPT_DIR TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TRANSCRIPT_PATH PID_FILE DELAY

# Spawn background worker
# (On macOS, setsid is not available; use direct background instead.
#  cancel-notify.sh kills both the main PID and the poller PID separately.)
bash "$SCRIPT_DIR/send-and-poll.sh" &

echo $! > "$PID_FILE"
