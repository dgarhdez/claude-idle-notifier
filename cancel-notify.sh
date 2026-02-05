#!/usr/bin/env bash
# Hook: UserPromptSubmit
# Cancels any pending idle notification timer and reply poller.

# Consume stdin (hook payload)
cat > /dev/null

PID_FILE="/tmp/claude-idle-notify.pid"
POLLER_PID_FILE="/tmp/claude-idle-poller.pid"

# Kill the main background process group (timer + send-and-poll)
if [[ -f "$PID_FILE" ]]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

# Kill any lingering poller
if [[ -f "$POLLER_PID_FILE" ]]; then
    poller_pid=$(cat "$POLLER_PID_FILE" 2>/dev/null)
    if [[ -n "$poller_pid" ]]; then
        kill "$poller_pid" 2>/dev/null
    fi
    rm -f "$POLLER_PID_FILE"
fi
