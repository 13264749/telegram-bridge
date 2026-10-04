#!/usr/bin/env bash
# echo_agent.sh — minimal example agent for the telegram bridge.
#
# Watches one queue and replies to every message with an echo.
# Usage:
#   TG_BRIDGE_DIR=/path/to/bridge TOPIC_QUEUE=_main bash examples/echo_agent.sh
set -euo pipefail
DIR="${TG_BRIDGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
QUEUE="${TOPIC_QUEUE:-_main}"

# Make sure the outbox daemon is running (the dispatcher usually owns this).
if ! pgrep -f "tg-outbox.sh" >/dev/null 2>&1; then
  TG_BRIDGE_DIR="$DIR" nohup bash "$DIR/bin/tg-outbox.sh" >/dev/null 2>&1 &
fi

# reply_to_outbox <name> <msg_id> <thread> <text>
reply_to_outbox() {
  local name="$1" msgid="$2" thread="$3" text="$4"
  {
    flock -x 200
    [ -n "$name" ] && printf '[Telegram→%s]\n' "$name"
    [ -n "$thread" ] && printf '__TG_THREAD__%s\n' "$thread"
    [ -n "$msgid" ] && printf '__TG_REPLY_TO__%s\n' "$msgid"
    printf '%s\n' "$text"
    printf '__TG_SEND__\n'
  } 200>"$DIR/.outbox.lock" >> "$DIR/outbox.txt"
}

while true; do
  while IFS= read -r line; do
    case "$line" in '[SYSTEM '*) continue ;; esac
    # [Telegram HH:MM @name#123 @general] text
    if [[ "$line" =~ ^\[Telegram\ [0-9:]+\ @([^#]+)#([0-9]+)([^]]*)\]\ (.*)$ ]]; then
      name="${BASH_REMATCH[1]}"; msgid="${BASH_REMATCH[2]}"
      flags="${BASH_REMATCH[3]}"; text="${BASH_REMATCH[4]}"
      # route: numeric id for unknown senders, topic id for topic queues
      rname="$name"
      case "$rname" in unknown_*) rname="${rname#unknown_}" ;; esac
      thread=""
      case "$flags" in *"@general"*) thread="general" ;; esac
      if [ "$QUEUE" != "_main" ]; then thread="$QUEUE"; rname=""; fi
      case "$text" in
        /start) reply_to_outbox "$rname" "$msgid" "$thread" \
                  "Echo bot. Send anything and I'll echo it back, threaded under your message." ;;
        /help)  reply_to_outbox "$rname" "$msgid" "$thread" \
                  "Commands: /start, /help. Everything else gets echoed." ;;
        *)      reply_to_outbox "$rname" "$msgid" "$thread" "echo: $text" ;;
      esac
    fi
  done < <(bash "$DIR/bin/tg-topic-watch.sh" "$QUEUE")
done
