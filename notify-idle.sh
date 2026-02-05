#!/usr/bin/env bash
# Hook: Notification (idle_prompt matcher)
# Starts a 30-second background timer. If not cancelled, sends a Telegram notification.

# Consume stdin (hook payload)
cat > /dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/telegram.conf"
PID_FILE="/tmp/claude-idle-notify.pid"
DELAY=30

# Load Telegram credentials
if [[ ! -f "$CONF" ]]; then
    exit 0
fi
source "$CONF"

if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    exit 0
fi

# Kill any existing timer
if [[ -f "$PID_FILE" ]]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -n "$old_pid" ]]; then
        kill "$old_pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

# Spawn background timer
(
    sleep "$DELAY"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="Claude Code is waiting for your input." \
        > /dev/null 2>&1
    rm -f "$PID_FILE"
) &

echo $! > "$PID_FILE"
