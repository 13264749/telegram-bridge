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
# Discord transport: DISCORD_TOKEN env, else the same `token` file
# (a Discord instance's token file holds the Discord bot token).
if [ -z "${DISCORD_TOKEN:-}" ]; then
  if [ -n "${TG_TOKEN:-}" ]; then
    DISCORD_TOKEN="$TG_TOKEN"
  elif [ -f "$BRIDGE_DIR/token" ]; then
    DISCORD_TOKEN="$(tr -d '[:space:]' < "$BRIDGE_DIR/token")"
  fi
fi
export DISCORD_TOKEN

# wait_for_change <file> [timeout] — block until <file> is modified.
# Uses inotifywait when available (instant wake, zero CPU); falls back to
# sleep. Callers must re-check their condition after return: an event can
# be missed between the check and the wait starting (then the timeout
# covers it — worst case = the old polling latency).
wait_for_change() {
  local file="$1" timeout_s="${2:-3}"
  if [ -f "$file" ] && command -v inotifywait >/dev/null 2>&1; then
    inotifywait -qq -e modify --timeout "$timeout_s" "$file" 2>/dev/null || true
  else
    sleep "$timeout_s"
  fi
}

# bridge_log <message> — metadata-only event log (never message content).
bridge_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$BRIDGE_DIR/bridge.log"
}

# bridge_health <section> <key> <set|incr> [value]
bridge_health() {
  TG_BRIDGE_DIR="$BRIDGE_DIR" python3 "$BRIDGE_DIR/bin/health.py" "$@"
}
