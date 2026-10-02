#!/usr/bin/env bash
# Shared helpers for the telegram bridge scripts. Source it after setting DIR:
#   DIR="${TG_BRIDGE_DIR:-$HOME/workspace/telegram_bridge}"
#   source "$DIR/bin/lib.sh"
BRIDGE_DIR="${TG_BRIDGE_DIR:-$HOME/workspace/telegram_bridge}"

# Per-bot credential selection: a `credential` file in the bridge dir names
# the Secure Vault connector holding this bot's token
# (e.g. custom.telegram-side). Exported so the tg CLI and every child
# process use the right bot. Default (no file): custom.telegram.
if [ -z "${TG_CREDENTIAL:-}" ] && [ -f "$BRIDGE_DIR/credential" ]; then
  TG_CREDENTIAL="$(tr -d '[:space:]' < "$BRIDGE_DIR/credential")"
fi
export TG_CREDENTIAL="${TG_CREDENTIAL:-custom.telegram}"

# bridge_log <message> — metadata-only event log (never message content).
bridge_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$BRIDGE_DIR/bridge.log"
}

# bridge_health <section> <key> <set|incr> [value]
bridge_health() {
  TG_BRIDGE_DIR="$BRIDGE_DIR" python3 "$BRIDGE_DIR/bin/health.py" "$@"
}
