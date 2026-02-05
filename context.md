# Claude Idle Notifier — Full Context

## What This Is

A set of scripts in `~/claude-idle-notifier/` that hook into Claude Code's hook system to:
1. Detect when Claude is idle (waiting for user input)
2. After a delay, send a Telegram notification with context about what Claude is asking
3. If Claude asked an AskUserQuestion, show the options as **inline keyboard buttons** in Telegram
4. Poll for a Telegram reply (button tap or free text)
5. Inject the reply back into the kitty terminal via `kitty @ send-text`

## Current State (as of 2026-02-05)

### Fully working — e2e verified
All components tested end-to-end and working:

- `parse-transcript.py` — extracts AskUserQuestion options or text context from JSONL transcripts
- `notify-idle.sh` — reads hook payload, extracts `transcript_path`, kills old timers/pollers, spawns background worker
- `send-and-poll.sh` — sleeps DELAY, parses transcript, sends Telegram message with inline keyboard, increments a counter, adds timestamp header (`🔔 #N • HH:MM:SS`)
- `poll-reply.sh` — long-polls Telegram `getUpdates`, handles both `callback_query` (button taps) and `message` (free text), answers callback queries, maps callback_data indices back to option labels, injects reply into kitty and presses Enter
- `cancel-notify.sh` — kills main PID + poller PID on UserPromptSubmit
- **kitty remote control** — socket at `/tmp/kitty-sock-<PID>` (kitty appends PID to socket name). Scripts find it dynamically via `ls -t /tmp/kitty-sock-*`
- **Reply injection** — uses `kitty @ send-text` for the text, then `kitty @ send-key Return` to submit (single `\n` or `\r` in send-text does NOT work as Enter — must use send-key separately)

## File Layout

```
~/claude-idle-notifier/
├── notify-idle.sh          # Hook entry point (Notification, idle_prompt matcher)
├── cancel-notify.sh        # Hook entry point (UserPromptSubmit)
├── send-and-poll.sh        # Background worker: sleep → parse → send Telegram → start poller
├── parse-transcript.py     # Extract AskUserQuestion or text from JSONL transcript
├── poll-reply.sh           # Poll Telegram for reply → inject into kitty
├── telegram.conf           # TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID (gitignored)
├── telegram.conf.example   # Template
├── .gitignore              # Ignores telegram.conf
├── README.md               # Documentation
└── context.md              # This file
```

## Hook Configuration

`~/.claude/settings.json`:
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /Users/dgh/.claude/statusline-command.sh"
  },
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/claude-idle-notifier/notify-idle.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/claude-idle-notifier/cancel-notify.sh"
          }
        ]
      }
    ]
  }
}
```

## Hook Payload Format (stdin to notify-idle.sh)

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/dgh/.claude/projects/.../session-id.jsonl",
  "cwd": "/Users/dgh",
  "permission_mode": "default",
  "hook_event_name": "Notification",
  "message": "Claude has been idle and needs your input",
  "title": "Claude Code",
  "notification_type": "idle_prompt"
}
```

## Transcript JSONL Format (what parse-transcript.py reads)

Each line is a JSON object. Assistant messages with AskUserQuestion look like:
```json
{
  "message": {
    "role": "assistant",
    "content": [
      {
        "type": "tool_use",
        "name": "AskUserQuestion",
        "input": {
          "questions": [{
            "question": "Which approach do you prefer?",
            "header": "Approach",
            "options": [
              {"label": "Option A", "description": "First approach"},
              {"label": "Option B", "description": "Second approach"}
            ],
            "multiSelect": false
          }]
        }
      }
    ]
  }
}
```

Non-AskUserQuestion assistant messages have `{"type": "text", "text": "..."}` blocks.

## Telegram Inline Keyboard Format

```json
{
  "chat_id": "708546499",
  "text": "🔔 #1 • 21:45:03\n\nClaude is asking:\n\nWhich approach do you prefer?",
  "reply_markup": "{\"inline_keyboard\":[[{\"text\":\"Option A\",\"callback_data\":\"0\"}],[{\"text\":\"Option B\",\"callback_data\":\"1\"}]]}"
}
```

`callback_data` is the numeric index; `poll-reply.sh` maps it back to the label text.

## Data Flow

```
Claude idle
  → hook fires notify-idle.sh (stdin = JSON payload with transcript_path)
  → kills old timer/poller PIDs
  → exports env vars
  → spawns: bash send-and-poll.sh &
      → sleep $DELAY (5s for testing, 30s for prod)
      → python3 parse-transcript.py $transcript_path → JSON with context + options
      → python3 sends Telegram message (with inline_keyboard if options)
      → bash poll-reply.sh $token $chat_id $options_json &
          → long-polls getUpdates (30s timeout, 5min max)
          → on callback_query: answerCallbackQuery + map data→label
          → on message: extract text
          → kitty @ --to unix:/tmp/kitty-sock-<PID> send-text --match recent:0 --stdin
          → kitty @ --to unix:/tmp/kitty-sock-<PID> send-key --match recent:0 Return
  → saves PID to /tmp/claude-idle-notify.pid

User responds locally in Claude
  → hook fires cancel-notify.sh
  → kills PID from /tmp/claude-idle-notify.pid
  → kills PID from /tmp/claude-idle-poller.pid
```

## Temp Files

| File | Purpose |
|------|---------|
| `/tmp/claude-idle-notify.pid` | PID of background send-and-poll.sh |
| `/tmp/claude-idle-poller.pid` | PID of poll-reply.sh |
| `/tmp/claude-idle-tg-offset` | Last processed Telegram update_id (persists across notifications) |
| `/tmp/claude-idle-notify-counter` | Notification counter for message headers |
| `/tmp/claude-idle-parsed.XXXXXX` | Temporary: parsed transcript JSON |
| `/tmp/claude-idle-options.XXXXXX` | Temporary: options JSON for poller |
| `/tmp/claude-idle-resp.XXXXXX` | Temporary: Telegram API response |
| `/tmp/kitty-sock-<PID>` | Kitty remote control unix socket (PID appended by kitty) |

## kitty.conf Changes

Added to `~/.config/kitty/kitty.conf`:
```
# Remote control (needed for claude-idle-notifier reply injection)
allow_remote_control socket-only
listen_on unix:/tmp/kitty-sock
```

- `socket-only` means only connections via the unix socket are allowed (no TTY-based control), which is more secure.
- **Important**: kitty appends its PID to the socket name, so the actual path is `/tmp/kitty-sock-<PID>`. The scripts find it dynamically via `ls -t /tmp/kitty-sock-*`.
- Kitty must be **restarted** after adding these lines for the socket to be created.

## Key Design Decisions

- **Python for JSON handling**: Shell is terrible at JSON. All JSON parsing goes through python3 (available on macOS).
- **Temp files for data passing**: Avoids shell quoting nightmares when passing JSON between bash and python. Environment variables + temp files instead of inline string interpolation.
- **Counter + timestamp in messages**: Each Telegram notification shows `🔔 #N • HH:MM:SS` so you can tell which message is new.
- **No setsid on macOS**: `setsid` doesn't exist on macOS. Background processes are killed individually via two PID files (main + poller).
- **Offset persistence**: `/tmp/claude-idle-tg-offset` tracks the last consumed Telegram update_id so the poller only sees new messages.
- **DELAY=5 currently**: Set for testing. Change to 30 in `notify-idle.sh` for production.

## Known Issues / Edge Cases

- If the poller is running and the user taps a button from an OLD notification (not the latest), the poller will still pick it up and inject it. This is generally fine since old buttons still map to valid option labels.
- The notification counter resets on reboot (stored in /tmp). Not a real problem.
- `parse-transcript.py` reads the full transcript file via a deque (last 50 lines). For very long sessions this is fine since deque caps memory.
- If no kitty socket is found, falls back to `kitty @` without `--to` flag (will fail in background processes but works if run inside kitty directly).
- `send-text` with `\n` or `\r` does NOT press Enter in the terminal. Must use `send-key Return` as a separate call.

## Production Checklist

- Change `DELAY=5` to `DELAY=30` in `notify-idle.sh` for production use (currently set to 5s for testing).
