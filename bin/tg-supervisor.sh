#!/usr/bin/env bash
# tg-supervisor.sh — process supervisor for the Telegram bridge.
# 100% script, no AI, no usage quota: it keeps the outbox daemon alive and
# re-runs the inbox listener whenever it exits silently.
#
# QUOTA CONTRACT: the agent is woken ONLY when a real user message arrives
# (the supervisor prints it and exits — that completion is the wake-up),
# or exactly once on a fatal/config error. Transient Telegram API failures
# are swallowed: logged to bridge.log and retried with growing backoff,
# never waking the agent. A user message therefore costs exactly one agent
# turn — the same as a normal message in the app.
#
# Run it as the agent's tracked background exec. If the supervisor itself
# dies, its completion wakes the agent, which restarts it.
#
# Duplicate guard: atomic mkdir lockdir + pid staleness check (no file
# descriptors, so child processes can never hold the lock open).
# A TERM/INT trap kills the inbox child so it can't keep polling orphaned;
# the outbox child is deliberately left running and gets adopted by the
# next supervisor.
#
# NOTE: a full VM restart kills everything including the supervisor; only an
# external trigger (e.g. an hourly cron backstop) can recover from that.
set -euo pipefail
DIR="${TG_BRIDGE_DIR:-$HOME/telegram-bridge}"
source "$DIR/bin/lib.sh"
mkdir -p "$DIR/run"
LOCKDIR="$DIR/run/supervisor.lock"

if mkdir "$LOCKDIR" 2>/dev/null; then
  echo $$ > "$LOCKDIR/pid"
else
  OLDPID="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    echo "another supervisor is already running (pid $OLDPID); exiting"
    exit 0
  fi
  bridge_log "SUPERVISOR taking over stale lock (was pid ${OLDPID:-unknown})"
  echo $$ > "$LOCKDIR/pid"
fi
release_lock() { rm -rf "$LOCKDIR"; }
trap release_lock EXIT

INBOX_PID=""
on_term() {
  if [ -n "$INBOX_PID" ]; then kill "$INBOX_PID" 2>/dev/null || true; fi
  exit 0
}
trap on_term TERM INT

bridge_log "SUPERVISOR started (pid $$)"

ensure_outbox() {
  pgrep -f "$DIR/bin/tg-outbo[x].sh" >/dev/null && return 0
  (
    flock -n 9 || exit 0
    pgrep -f "$DIR/bin/tg-outbo[x].sh" >/dev/null && exit 0
    bridge_log "SUPERVISOR starting tg-outbox.sh"
    setsid nohup bash "$DIR/bin/tg-outbox.sh" >>"$DIR/outbox_daemon.log" 2>&1 &
    echo $! > "$DIR/run/outbox.pid"
  ) 9>"$DIR/run/outbox.lock"
}

ERR_BACKOFFS="${SUPERVISOR_BACKOFFS:-60,300,900,3600}"
ERR_N=0

while true; do
  ensure_outbox
  OUTFILE="$(mktemp)"
  set +e
  bash "$DIR/bin/tg-inbox.sh" >"$OUTFILE" 2>&1 &
  INBOX_PID=$!
  wait "$INBOX_PID"
  RC=$?
  set -e
  INBOX_PID=""
  OUT="$(cat "$OUTFILE")"; rm -f "$OUTFILE"
  case "$OUT" in
    "[Telegram "*)
      # Real user message(s): print and exit — this wakes the agent.
      # Rotation check is script-side (zero quota): appends a one-line
      # [SYSTEM rotate-suggest] proposal flag when the rotation criteria
      # (see bin/rotation_check.py) are met. The agent proposes it to the
      # user in the chat; it is never sent to Telegram.
      SUGGEST="$(python3 "$DIR/bin/rotation_check.py" 2>/dev/null || true)"
      if [ -n "$SUGGEST" ]; then
        OUT="$OUT
$SUGGEST"
      fi
      printf '%s\n' "$OUT"
      exit "$RC" ;;
  esac
  if [ "$RC" -eq 1 ]; then
    # Transient API failure: stay quiet, back off, keep trying. No wake-up.
    ERR_N=$((ERR_N + 1))
    IFS=',' read -ra BO <<< "$ERR_BACKOFFS"
    LAST=$(( ${#BO[@]} - 1 ))
    IDX=$((ERR_N - 1)); [ "$IDX" -gt "$LAST" ] && IDX=$LAST
    DELAY="${BO[$IDX]}"
    bridge_log "SUPERVISOR transient inbox failure #${ERR_N}; retry in ${DELAY}s (no agent wake-up)"
    sleep "$DELAY"
  elif [ "$RC" -eq 0 ]; then
    bridge_log "SUPERVISOR tg-inbox.sh exited silently (rc=0); restarting"
    sleep 2
  else
    # Fatal/config error: wake the agent exactly once.
    [ -n "$OUT" ] && printf '%s\n' "$OUT"
    bridge_log "SUPERVISOR fatal inbox error (rc=$RC); exiting to alert agent"
    exit "$RC"
  fi
done
