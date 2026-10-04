#!/usr/bin/env bash
# echo_agent.sh — minimal example agent for the telegram bridge.
#
# Watches one queue and replies to every message with an echo.
# Usage:
#   TG_BRIDGE_DIR=/path/to/bridge TOPIC_QUEUE=_main bash examples/echo_agent.sh
set -euo pipefail
DIR="${TG_BRIDGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
QUEUE="${TOPIC_QUEUE:-_main}"
SOURCE="${BRIDGE_SOURCE:-telegram}"
if [ "$SOURCE" = "discord" ]; then OUTBOX_BIN="$DIR/bin/discord/dc-outbox.sh";
else OUTBOX_BIN="$DIR/bin/tg-outbox.sh"; fi

# Make sure the outbox daemon is running (the dispatcher usually owns this).
if ! pgrep -f "$OUTBOX_BIN" >/dev/null 2>&1; then
  TG_BRIDGE_DIR="$DIR" nohup bash "$OUTBOX_BIN" >/dev/null 2>&1 &
fi

# reply_to_outbox <source> <name> <msg_id> <thread> <text>
reply_to_outbox() {
  local source="$1" name="$2" msgid="$3" thread="$4" text="$5"
  {
    flock -x 200
    [ -n "$name" ] && printf '[%s→%s]\n' "$source" "$name"
    [ -n "$thread" ] && printf '__THREAD__%s\n' "$thread"
    [ -n "$msgid" ] && printf '__REPLY_TO__%s\n' "$msgid"
    printf '%s\n' "$text"
    printf '__TG_SEND__\n'
  } 200>"$DIR/.outbox.lock" >> "$DIR/outbox.txt"
}

while true; do
  while IFS= read -r line; do
    case "$line" in '[SYSTEM '*) continue ;; esac
    # [Source HH:MM @name#123 @general] text
    if [[ "$line" =~ ^\[([A-Za-z]+)\ [0-9:]+\ @([^#]+)#([0-9]+)([^]]*)\]\ (.*)$ ]]; then
      source="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"; msgid="${BASH_REMATCH[3]}"
      flags="${BASH_REMATCH[4]}"; text="${BASH_REMATCH[5]}"
      # route: numeric id for unknown senders, topic id for topic queues
      rname="$name"
      case "$rname" in unknown_*) rname="${rname#unknown_}" ;; esac
      thread=""
      case "$flags" in *"@general"*) thread="general" ;; esac
      if [ "$QUEUE" != "_main" ]; then thread="$QUEUE"; rname=""; fi
      case "$text" in
        /start) reply_to_outbox "$source" "$rname" "$msgid" "$thread" \
                  "Echo bot ($source). Send anything and I'll echo it back, threaded under your message." ;;
        /help)  reply_to_outbox "$source" "$rname" "$msgid" "$thread" \
                  "Commands: /start, /help. Everything else gets echoed." ;;
        *)      reply_to_outbox "$source" "$rname" "$msgid" "$thread" "echo: $text" ;;
      esac
    fi
  done < <(bash "$DIR/bin/tg-topic-watch.sh" "$QUEUE")
done
