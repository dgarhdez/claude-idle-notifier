# Claude Code Idle Notifier

Get a Telegram push notification when Claude Code has been waiting for your input for 30 seconds.

## Setup

1. **Create a Telegram bot** — message [@BotFather](https://t.me/BotFather) on Telegram and follow the prompts to get a bot token.

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

- When Claude finishes and waits for input, a 30-second background timer starts.
- If you respond within 30 seconds, the timer is cancelled.
- If 30 seconds pass with no response, you get a Telegram notification.

## Testing

Edit `notify-idle.sh` and change `DELAY=30` to `DELAY=5`, then let Claude finish a response and wait. You should receive a notification after 5 seconds. Change it back to 30 when done.
