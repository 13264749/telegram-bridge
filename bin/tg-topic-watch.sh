#!/usr/bin/env bash
# tg-topic-watch.sh <queue> — per-topic queue watcher (worker).
#
# Run as a tracked background exec in a topic's Muse chat. Polls
# topics/<queue>.queue every TOPIC_WATCH_POLL seconds (default 3); when new
# lines appear it prints them and exits 0 — the exit wakes only that chat's
# agent. Polling is pure script: zero AI quota while idle.
#
# Queues: _main (private chats + forum General), or <thread_id> for a forum
# topic. Read position is kept in topics/<queue>.offset. Appends by
# tg-dispatch.sh are flock-guarded; the read+offset update below holds the
# same lock, so no message is lost or duplicated.
set -euo pipefail
DIR="${TG_BRIDGE_DIR:-$HOME/workspace/telegram_bridge}"
source "$DIR/bin/lib.sh"
QNAME="${1:?usage: tg-topic-watch.sh <queue>}"
case "$QNAME" in
  ''|*[!A-Za-z0-9_]*)
    echo "queue must match [A-Za-z0-9_]+" >&2; exit 2 ;;
esac
TOPICS="$DIR/topics"
Q="$TOPICS/$QNAME.queue"
OFF="$TOPICS/$QNAME.offset"
LOCK="$TOPICS/.lock"
POLL="${TOPIC_WATCH_POLL:-3}"
mkdir -p "$TOPICS"

while true; do
  GOT=0
  if [ -f "$Q" ]; then
    {
      flock -x 200
      total="$(wc -l < "$Q" 2>/dev/null || echo 0)"
      read_n="$(cat "$OFF" 2>/dev/null || echo 0)"
      case "$read_n" in ''|*[!0-9]*) read_n=0 ;; esac
      # wc -l emits leading spaces; strip them for the arithmetic below.
      total="$(printf '%s' "$total" | tr -d ' ')"
      if [ "$total" -gt "$read_n" ]; then
        tail -n +"$((read_n + 1))" "$Q"
        printf '%s\n' "$total" > "$OFF"
        GOT=1
      fi
    } 200>"$LOCK"
  fi
  if [ "$GOT" = "1" ]; then exit 0; fi
  sleep "$POLL"
done
