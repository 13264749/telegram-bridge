#!/usr/bin/env bash
# tg-ctl.sh — operate the telegram bridge.
#   tg-ctl.sh status              show daemons, queue, health
#   tg-ctl.sh stop [all|supervisor|inbox|outbox]
# NOTE: starting is owned by the agent's tracked background execs
# (the supervisor's completion is what wakes the agent on new messages),
# so there is intentionally no `start` here — see the bridge docs.
set -euo pipefail
DIR="${TG_BRIDGE_DIR:-$HOME/telegram-bridge}"

pat() {
  # Bracket trick: the pattern must not literally appear in our own command
  # line, otherwise pgrep -f would match the caller itself.
  # Patterns are scoped to this bridge instance's DIR, so several bots
  # (telegram_bridge, telegram_bridge_side, ...) never see each other.
  # $2 (optional) narrows further, e.g. a watcher queue name.
  local base="$DIR/bin"
  case "$1" in
    supervisor) echo "$base/tg-superviso[r].sh" ;;
    inbox)      echo "$base/tg-inbo[x].sh" ;;
    outbox)     echo "$base/tg-outbo[x].sh" ;;
    dispatcher) echo "$base/tg-dispatc[h].sh" ;;
    dc_dispatcher) echo "$base/discord/dc-dispatc[h].sh" ;;
    dc_outbox) echo "$base/discord/dc-outbo[x].sh" ;;
    watcher)
      if [ -n "${2:-}" ]; then echo "$base/tg-topic-watc[h].sh $2";
      else echo "$base/tg-topic-watc[h].sh"; fi ;;
  esac
}

do_status() {
  for n in dispatcher dc_dispatcher watcher supervisor inbox outbox dc_outbox; do
    if pgrep -f "$(pat "$n")" >/dev/null; then s="running"; else s="DOWN"; fi
    printf '%-13s %s\n' "$n" "$s"
  done
  if [ -f "$DIR/last_poll.txt" ]; then
    lp="$(cat "$DIR/last_poll.txt")"
    echo "last_poll: $lp"
  else
    echo "last_poll: never"
  fi
  q=0
  if [ -f "$DIR/outbox.txt" ]; then q="$(grep -c . "$DIR/outbox.txt" 2>/dev/null || true)"; fi
  echo "outbox_queued_lines: $q"
  dead=0
  if [ -f "$DIR/dead_letters.txt" ]; then dead="$(grep -c '^===' "$DIR/dead_letters.txt" 2>/dev/null || true)"; fi
  echo "dead_letters: $dead"
  if [ -f "$DIR/health.json" ]; then echo "--- health.json"; cat "$DIR/health.json"; fi
  if [ -s "$DIR/unknown_senders.log" ]; then echo "--- unknown_senders (last 5)"; tail -5 "$DIR/unknown_senders.log"; fi
  if [ -f "$DIR/bridge.log" ]; then echo "--- bridge.log (last 10)"; tail -10 "$DIR/bridge.log"; fi
}

do_stop() {
  local target="${1:-all}"
  local extra="${2:-}"
  local order="dispatcher dc_dispatcher watcher supervisor inbox outbox dc_outbox"
  [ "$target" != "all" ] && order="$target"
  for n in $order; do
    if pkill -f "$(pat "$n" "$extra")"; then echo "stopped $n${extra:+ ($extra)}"; else echo "$n not running"; fi
  done
}

case "${1:-status}" in
  status) do_status ;;
  stop)   do_stop "${2:-all}" "${3:-}" ;;
  *) echo "usage: tg-ctl.sh status | stop [all|dispatcher|dc_dispatcher|watcher [queue]|supervisor|inbox|outbox|dc_outbox]" >&2; exit 1 ;;
esac
