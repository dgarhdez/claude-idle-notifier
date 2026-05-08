#!/usr/bin/env bash
set -euo pipefail

# ─── Claude Idle Notifier — Setup Script ─────────────────────────────────────
# Configures Telegram bot credentials, Claude Code hooks, and kitty terminal.
# Safe to run multiple times (idempotent).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/telegram.conf"
SETTINGS_JSON="$HOME/.claude/settings.json"
KITTY_CONF="$HOME/.config/kitty/kitty.conf"

# ─── Colors ───────────────────────────────────────────────────────────────────
bold='\033[1m'
green='\033[0;32m'
yellow='\033[0;33m'
red='\033[0;31m'
reset='\033[0m'

info()  { printf "${bold}%s${reset}\n" "$*"; }
ok()    { printf "${green}✓${reset} %s\n" "$*"; }
warn()  { printf "${yellow}⚠${reset} %s\n" "$*"; }
err()   { printf "${red}✗${reset} %s\n" "$*"; }

# ─── 1. Check prerequisites ──────────────────────────────────────────────────
info "Checking prerequisites..."

missing=0
for cmd in python3 curl; do
    if ! command -v "$cmd" &>/dev/null; then
        err "$cmd is required but not found"
        missing=1
    else
        ok "$cmd found"
    fi
done

if ! command -v kitty &>/dev/null; then
    warn "kitty not found — reply injection won't work without it"
    warn "Install kitty: https://sw.kovidgoez.net/kitty/"
else
    ok "kitty found"
fi

if [[ $missing -eq 1 ]]; then
    err "Missing required dependencies. Aborting."
    exit 1
fi

echo ""

# ─── 2. Collect bot token ────────────────────────────────────────────────────
info "Telegram Bot Configuration"

existing_token=""
existing_chat_id=""
if [[ -f "$CONF" ]]; then
    existing_token=$(bash -c "source '$CONF' && echo \"\$TELEGRAM_BOT_TOKEN\"" 2>/dev/null || true)
    existing_chat_id=$(bash -c "source '$CONF' && echo \"\$TELEGRAM_CHAT_ID\"" 2>/dev/null || true)
fi

# Token
if [[ -n "$existing_token" ]]; then
    masked="${existing_token:0:8}...${existing_token: -4}"
    printf "Existing bot token found: %s\n" "$masked"
    read -rp "Keep existing token? [Y/n] " keep_token
    if [[ "$keep_token" =~ ^[Nn] ]]; then
        existing_token=""
    fi
fi

if [[ -z "$existing_token" ]]; then
    echo "Create a bot via @BotFather on Telegram if you haven't already."
    echo "Paste the bot token (format: 123456:ABC-DEF...):"
    while true; do
        read -rp "> " bot_token
        # Basic format check: digits:alphanumeric
        if [[ "$bot_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            # Verify via getMe
            printf "Verifying token... "
            response=$(curl -sf "https://api.telegram.org/bot${bot_token}/getMe" 2>/dev/null || true)
            if [[ -n "$response" ]] && echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok')" 2>/dev/null; then
                bot_name=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null)
                ok "Valid! Bot: @${bot_name}"
                break
            else
                err "Token rejected by Telegram API. Check the token and try again."
            fi
        else
            err "Invalid format. Token should look like: 123456789:ABCdefGHI-jklMNOpqrSTUvwx"
        fi
    done
else
    bot_token="$existing_token"
fi

echo ""

# ─── 3. Auto-detect chat ID ──────────────────────────────────────────────────
if [[ -n "$existing_chat_id" ]]; then
    printf "Existing chat ID found: %s\n" "$existing_chat_id"
    read -rp "Keep existing chat ID? [Y/n] " keep_chat
    if [[ "$keep_chat" =~ ^[Nn] ]]; then
        existing_chat_id=""
    fi
fi

if [[ -z "$existing_chat_id" ]]; then
    info "Detecting your chat ID..."
    echo "Draining old messages..."

    # Drain old updates so we only see new ones
    drain_response=$(curl -sf "https://api.telegram.org/bot${bot_token}/getUpdates" 2>/dev/null || true)
    if [[ -n "$drain_response" ]]; then
        # Get the highest update_id and set offset past it
        drain_offset=$(echo "$drain_response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
updates = d.get('result', [])
if updates:
    print(max(u['update_id'] for u in updates) + 1)
else:
    print('')
" 2>/dev/null || true)
    fi

    echo ""
    echo "Now send any message to your bot on Telegram."
    echo "Waiting up to 120 seconds..."
    echo ""

    chat_id=""
    end_time=$(( $(date +%s) + 120 ))
    while [[ $(date +%s) -lt $end_time ]]; do
        offset_param=""
        if [[ -n "${drain_offset:-}" ]]; then
            offset_param="&offset=${drain_offset}"
        fi
        poll_response=$(curl -sf "https://api.telegram.org/bot${bot_token}/getUpdates?timeout=5${offset_param}" 2>/dev/null || true)
        if [[ -n "$poll_response" ]]; then
            chat_id=$(echo "$poll_response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
updates = d.get('result', [])
for u in updates:
    msg = u.get('message', {})
    chat = msg.get('chat', {})
    cid = chat.get('id')
    if cid:
        print(cid)
        break
" 2>/dev/null || true)
            if [[ -n "$chat_id" ]]; then
                ok "Detected chat ID: $chat_id"
                break
            fi
        fi
    done

    if [[ -z "$chat_id" ]]; then
        warn "Timed out waiting for a message."
        echo "Enter your chat ID manually (find it by messaging the bot and running:"
        echo "  curl https://api.telegram.org/bot<TOKEN>/getUpdates"
        echo "Look for \"chat\":{\"id\":123456789})"
        read -rp "> " chat_id
        if [[ -z "$chat_id" ]]; then
            err "No chat ID provided. Aborting."
            exit 1
        fi
    fi
else
    chat_id="$existing_chat_id"
fi

echo ""

# ─── 4. Write telegram.conf ──────────────────────────────────────────────────
info "Writing telegram.conf..."

if [[ -f "$CONF" ]]; then
    cp "$CONF" "${CONF}.bak"
    ok "Backed up existing telegram.conf to telegram.conf.bak"
fi

cat > "$CONF" <<EOF
# Telegram Bot credentials (generated by install.sh)
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
EOF

ok "telegram.conf written"
echo ""

# ─── 5. Merge hooks into settings.json ───────────────────────────────────────
info "Configuring Claude Code hooks..."

mkdir -p "$(dirname "$SETTINGS_JSON")"

if [[ -f "$SETTINGS_JSON" ]]; then
    cp "$SETTINGS_JSON" "${SETTINGS_JSON}.bak"
    ok "Backed up settings.json"
fi

python3 - "$SETTINGS_JSON" "$SCRIPT_DIR" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
script_dir = sys.argv[2]

# Load existing settings or start fresh
settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

hooks = settings.setdefault("hooks", {})

notify_cmd = f"bash {script_dir}/notify-idle.sh"
cancel_cmd = f"bash {script_dir}/cancel-notify.sh"

# --- Notification hook ---
notification_list = hooks.get("Notification", [])

# Find existing idle_prompt entry (match by matcher, or by command containing notify-idle)
found_notify = False
for entry in notification_list:
    if entry.get("matcher") == "idle_prompt":
        # Update command to use absolute path
        entry["hooks"] = [{"type": "command", "command": notify_cmd}]
        found_notify = True
        break

if not found_notify:
    notification_list.append({
        "matcher": "idle_prompt",
        "hooks": [{"type": "command", "command": notify_cmd}]
    })

hooks["Notification"] = notification_list

# --- UserPromptSubmit hook ---
submit_list = hooks.get("UserPromptSubmit", [])

# Find existing cancel-notify entry
found_cancel = False
for entry in submit_list:
    entry_hooks = entry.get("hooks", [])
    for h in entry_hooks:
        cmd = h.get("command", "")
        if "cancel-notify" in cmd:
            h["command"] = cancel_cmd
            found_cancel = True
            break
    if found_cancel:
        break

if not found_cancel:
    submit_list.append({
        "hooks": [{"type": "command", "command": cancel_cmd}]
    })

hooks["UserPromptSubmit"] = submit_list

# --- PermissionRequest hook ---
perm_cmd = f"bash {script_dir}/permission-hook.sh"
permission_list = hooks.get("PermissionRequest", [])

# Find existing permission-hook entry
found_perm = False
for entry in permission_list:
    entry_hooks = entry.get("hooks", [])
    for h in entry_hooks:
        cmd = h.get("command", "")
        if "permission-hook" in cmd:
            h["command"] = perm_cmd
            found_perm = True
            break
    if found_perm:
        break

if not found_perm:
    permission_list.append({
        "hooks": [{"type": "command", "command": perm_cmd}]
    })

hooks["PermissionRequest"] = permission_list

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("OK")
PYEOF

ok "Claude Code hooks configured in $SETTINGS_JSON"
echo ""

# ─── 6. Configure kitty ──────────────────────────────────────────────────────
info "Configuring kitty terminal..."

if ! command -v kitty &>/dev/null; then
    warn "kitty not installed — skipping kitty configuration"
    warn "Install kitty and re-run this script, or configure manually:"
    echo "  Add to ~/.config/kitty/kitty.conf:"
    echo "    allow_remote_control socket-only"
    echo "    listen_on unix:/tmp/kitty-sock"
else
    mkdir -p "$(dirname "$KITTY_CONF")"

    kitty_changed=0

    if [[ -f "$KITTY_CONF" ]]; then
        # Check for existing allow_remote_control
        if grep -q '^allow_remote_control' "$KITTY_CONF"; then
            current_value=$(grep '^allow_remote_control' "$KITTY_CONF" | tail -1 | awk '{print $2}')
            if [[ "$current_value" == "socket-only" ]]; then
                ok "allow_remote_control already set to socket-only"
            else
                warn "allow_remote_control is set to '$current_value' (expected 'socket-only')"
                warn "Please change it manually in $KITTY_CONF if reply injection doesn't work"
            fi
        else
            cp "$KITTY_CONF" "${KITTY_CONF}.bak"
            printf '\n# Remote control (needed for claude-idle-notifier reply injection)\nallow_remote_control socket-only\n' >> "$KITTY_CONF"
            ok "Added allow_remote_control socket-only"
            kitty_changed=1
        fi

        # Check for existing listen_on
        if grep -q '^listen_on' "$KITTY_CONF"; then
            current_listen=$(grep '^listen_on' "$KITTY_CONF" | tail -1 | awk '{print $2}')
            if [[ "$current_listen" == "unix:/tmp/kitty-sock" ]]; then
                ok "listen_on already configured"
            else
                warn "listen_on is set to '$current_listen' (expected 'unix:/tmp/kitty-sock')"
                warn "Please check $KITTY_CONF if reply injection doesn't work"
            fi
        else
            if [[ $kitty_changed -eq 0 ]]; then
                cp "$KITTY_CONF" "${KITTY_CONF}.bak"
            fi
            printf 'listen_on unix:/tmp/kitty-sock\n' >> "$KITTY_CONF"
            ok "Added listen_on unix:/tmp/kitty-sock"
            kitty_changed=1
        fi
    else
        cat > "$KITTY_CONF" <<'KITTYEOF'
# Remote control (needed for claude-idle-notifier reply injection)
allow_remote_control socket-only
listen_on unix:/tmp/kitty-sock
KITTYEOF
        ok "Created $KITTY_CONF with remote control settings"
        kitty_changed=1
    fi
fi

echo ""

# ─── 7. Summary ──────────────────────────────────────────────────────────────
info "Setup complete!"
echo ""
echo "  telegram.conf    — bot token + chat ID saved"
echo "  settings.json    — Claude Code hooks configured"
if command -v kitty &>/dev/null; then
    echo "  kitty.conf       — remote control configured"
fi
echo ""

if [[ "${kitty_changed:-0}" -eq 1 ]]; then
    warn "Restart kitty for the socket changes to take effect."
    echo ""
fi

echo "To test: let Claude Code go idle for 5 seconds and check Telegram."
echo "Change DELAY=5 to DELAY=30 in notify-idle.sh for production use."
