#!/usr/bin/env bash
# Hook: PreToolUse
# Fires before every tool use. We only care about Bash (permission dialogs).
# Spawns a background worker that waits DELAY seconds, then sends the permission
# prompt to Telegram with Allow/Always Allow/Deny buttons.
# Exits immediately with no output — tool proceeds normally through permission check.

# Read hook payload from stdin
INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/telegram.conf"
PID_FILE="/tmp/claude-perm-notify.pid"
DELAY=30

# Only handle Bash tool (main source of permission dialogs)
TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

echo "$(date '+%H:%M:%S') permission hook fired (tool=$TOOL_NAME)" >> /tmp/claude-idle-notify.log

# Load Telegram credentials
if [[ ! -f "$CONF" ]]; then
    exit 0
fi
source "$CONF"

if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    exit 0
fi

TOOL_INPUT=$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('tool_input',{})))" 2>/dev/null)

# Kill any existing permission worker
if [[ -f "$PID_FILE" ]]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -n "$old_pid" ]]; then
        kill "$old_pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

# Also kill any existing permission poller
POLLER_PID_FILE="/tmp/claude-perm-poller.pid"
if [[ -f "$POLLER_PID_FILE" ]]; then
    poller_pid=$(cat "$POLLER_PID_FILE" 2>/dev/null)
    if [[ -n "$poller_pid" ]]; then
        kill "$poller_pid" 2>/dev/null
    fi
    rm -f "$POLLER_PID_FILE"
fi

# Export everything the background process needs
# KITTY_WINDOW_ID is set by kitty for the shell → inherited by Claude → inherited by hook
export SCRIPT_DIR TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TOOL_NAME TOOL_INPUT PID_FILE DELAY KITTY_WINDOW_ID

# Spawn background worker and exit immediately (tool proceeds to normal permission check)
bash "$SCRIPT_DIR/permission-worker.sh" &
disown

echo $! > "$PID_FILE"
