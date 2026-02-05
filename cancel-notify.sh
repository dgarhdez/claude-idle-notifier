#!/usr/bin/env bash
# Hook: UserPromptSubmit
# Cancels any pending idle notification timer.

# Consume stdin (hook payload)
cat > /dev/null

PID_FILE="/tmp/claude-idle-notify.pid"

if [[ -f "$PID_FILE" ]]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi
