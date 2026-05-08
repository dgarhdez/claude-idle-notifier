# Claude Code Idle Notifier

Get a Telegram push notification when Claude Code has been waiting for your input — with interactive reply support.

## Features

- **Context-aware notifications**: Shows what Claude is asking, not just "waiting for input"
- **Inline keyboard buttons**: When Claude asks a multiple-choice question (AskUserQuestion), options appear as tappable buttons in Telegram
- **Reply from Telegram**: Tap a button or type free text to reply directly from your phone
- **Auto-injection**: Replies are typed into kitty terminal and submitted automatically via `kitty @ send-text` + `kitty @ send-key`
- **Permission request notifications**: When Claude shows a permission dialog (e.g., "Allow `git add .`?") and you don't respond within 30s, get a Telegram message with Allow/Always Allow/Deny buttons

## Setup

1. **Create a Telegram bot** — message [@BotFather](https://t.me/botfather) on Telegram, use `/newbot`, and copy the token it gives you.

2. **Run the installer**:
   ```
   ./install.sh
   ```
   The script will:
   - Validate your bot token against the Telegram API
   - Auto-detect your chat ID (it asks you to send a message to the bot)
   - Write `telegram.conf` with your credentials
   - Add the notification hooks to `~/.claude/settings.json`
   - Configure kitty for remote control (needed for reply injection)

   The installer is idempotent — safe to run again if you need to change settings.

3. **Restart kitty** if the installer modified `kitty.conf`.

## How It Works

```
Claude idle → notify-idle.sh → [sleep DELAY] → send Telegram msg with buttons
                                              → poll-reply.sh (background)
                                                  → getUpdates / answerCallbackQuery
                                                  → kitty @ send-text "reply"
                                                  → kitty @ send-key Return
User responds in Claude → cancel-notify.sh → kills timer + poller
```

1. When Claude finishes and waits for input, a background timer starts (default 5s).
2. If you respond within the delay, the timer is cancelled — no notification sent.
3. After the delay, `parse-transcript.py` reads the conversation transcript to extract context:
   - If Claude asked an **AskUserQuestion**, the question text and options are extracted
   - Otherwise, the last assistant text is shown (truncated to 200 chars)
4. A Telegram message is sent with the context. If options exist, they appear as **inline keyboard buttons**.
5. A background poller watches for your reply (button tap or free text) for up to 5 minutes.
6. When you reply, the text is injected into kitty via `kitty @ send-text` and submitted.

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Interactive setup script — configures everything |
| `notify-idle.sh` | Main hook: reads payload, starts timer, orchestrates send + poll |
| `cancel-notify.sh` | Cancel hook: kills timer + poller when user responds locally |
| `parse-transcript.py` | Extracts last prompt context & options from JSONL transcript |
| `send-and-poll.sh` | Background worker: sends Telegram message, starts poller |
| `poll-reply.sh` | Polls Telegram for button/text replies, injects into kitty |
| `permission-hook.sh` | Permission hook: reads tool info, spawns background worker |
| `permission-worker.sh` | Sends permission prompt to Telegram, polls for Allow/Deny |
| `telegram.conf` | Your bot token and chat ID (gitignored) |

## Testing

The default `DELAY=5` is set for quick testing. To test:

1. Let Claude ask you a question (e.g. trigger an AskUserQuestion) → wait 5s → Telegram shows buttons
2. Tap a button → text appears in Claude Code and is submitted
3. Let Claude finish normally → wait 5s → Telegram shows context message
4. Reply with free text → text appears in Claude Code and is submitted
5. Respond in Claude within 5s → no Telegram message sent

**Permission requests** (DELAY=30 by default in `permission-hook.sh`):

1. Let Claude trigger a permission prompt (e.g., a bash command) → don't answer for 30s → Telegram shows Allow/Always Allow/Deny buttons
2. Tap "Allow" → Claude continues
3. Repeat, answering in terminal within 30s → Telegram message still sent but harmless

Set `DELAY=30` in `notify-idle.sh` for production use.

## Requirements

- Python 3 (for transcript parsing and JSON handling)
- [kitty](https://sw.kovidgoez.net/kitty/) terminal with remote control enabled
- curl (for Telegram API calls)

## Manual Kitty Setup

If you didn't use `install.sh`, add to `~/.config/kitty/kitty.conf`:
```
allow_remote_control socket-only
listen_on unix:/tmp/kitty-sock
```

Then restart kitty. The socket will be created at `/tmp/kitty-sock-<PID>` (the scripts find it dynamically via glob).
