# Claude Code Idle Notifier

Get a Telegram push notification when Claude Code has been waiting for your input — with interactive reply support.

## Features

- **Context-aware notifications**: Shows what Claude is asking, not just "waiting for input"
- **Inline keyboard buttons**: When Claude asks a multiple-choice question (AskUserQuestion), options appear as tappable buttons in Telegram
- **Reply from Telegram**: Tap a button or type free text to reply directly from your phone
- **Auto-injection**: Replies are typed into kitty terminal and submitted automatically via `kitty @ send-text` + `kitty @ send-key`

## Setup

1. **Create a Telegram bot** — message [@BotFather](https://t.me/botfather) on Telegram and follow the prompts to get a bot token.

2. **Get your chat ID** — send any message to your new bot, then run:
   ```
   curl https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
   ```
   Look for `"chat":{"id":123456789}` in the response.

3. **Configure credentials**:
   ```
   cp telegram.conf.example telegram.conf
   ```
   Edit `telegram.conf` and fill in `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`.

4. **Hooks are already configured** in `~/.claude/settings.json`. No further action needed.

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
| `notify-idle.sh` | Main hook: reads payload, starts timer, orchestrates send + poll |
| `cancel-notify.sh` | Cancel hook: kills timer + poller when user responds locally |
| `parse-transcript.py` | Extracts last prompt context & options from JSONL transcript |
| `send-and-poll.sh` | Background worker: sends Telegram message, starts poller |
| `poll-reply.sh` | Polls Telegram for button/text replies, injects into kitty |
| `telegram.conf` | Your bot token and chat ID (gitignored) |

## Testing

The default `DELAY=5` is set for quick testing. To test:

1. Let Claude ask you a question (e.g. trigger an AskUserQuestion) → wait 5s → Telegram shows buttons
2. Tap a button → text appears in Claude Code and is submitted
3. Let Claude finish normally → wait 5s → Telegram shows context message
4. Reply with free text → text appears in Claude Code and is submitted
5. Respond in Claude within 5s → no Telegram message sent

Set `DELAY=30` in `notify-idle.sh` for production use.

## Requirements

- Python 3 (for transcript parsing and JSON handling)
- [kitty](https://sw.kovidgoez.net/kitty/) terminal with remote control enabled (see kitty setup below)
- curl (for Telegram API calls)

## Kitty Setup

Add to `~/.config/kitty/kitty.conf`:
```
allow_remote_control socket-only
listen_on unix:/tmp/kitty-sock
```

Then restart kitty. The socket will be created at `/tmp/kitty-sock-<PID>` (the scripts find it dynamically via glob).
