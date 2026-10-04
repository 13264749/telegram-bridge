#!/usr/bin/env bash
# Shared helpers for the telegram bridge scripts. Source it after setting DIR:
#   DIR="${TG_BRIDGE_DIR:-$HOME/telegram-bridge}"
#   source "$DIR/bin/lib.sh"
BRIDGE_DIR="${TG_BRIDGE_DIR:-$HOME/telegram-bridge}"

# Bot token: TG_TOKEN env wins; otherwise read the `token` file in the
# bridge dir (chmod 600, never committed). The tg CLI reads the same
# sources, so every child process talks to this bot.
if [ -z "${TG_TOKEN:-}" ] && [ -f "$BRIDGE_DIR/token" ]; then
  TG_TOKEN="$(tr -d '[:space:]' < "$BRIDGE_DIR/token")"
fi
export TG_TOKEN

# bridge_log <message> — metadata-only event log (never message content).
bridge_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$BRIDGE_DIR/bridge.log"
}

# bridge_health <section> <key> <set|incr> [value]
bridge_health() {
  TG_BRIDGE_DIR="$BRIDGE_DIR" python3 "$BRIDGE_DIR/bin/health.py" "$@"
}
