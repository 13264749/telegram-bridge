#!/usr/bin/env bash
# tg-dispatch.sh — single getUpdates consumer + per-topic queue router.
#
# This is THE telegram consumer for a bridge instance. It long-polls in an
# internal loop and NEVER exits on messages: each message from an authorized
# account is appended (flock-protected) as a tagged line to a per-topic queue
# file under topics/:
#   topics/_main.queue        — private chats + the forum's General topic
#   topics/<thread_id>.queue  — forum topic <thread_id>
# A per-topic watcher (tg-topic-watch.sh, run as a tracked exec in that
# topic's Muse chat) prints new lines and exits, waking only that chat's
# agent. One Muse chat per topic = no context mixing.
#
# Tagged line format (same as the legacy inbox):
#   [Telegram HH:MM @name#message_id] <body>
# Group General-topic messages get an extra " @general" suffix:
#   [Telegram HH:MM @name#message_id @general] <body>
#
# Exit codes:
#   2 — fatal/config error (bad accounts.json, API 401): prints
#       [DISPATCHER ERROR] and exits, waking the agent exactly once.
# Transient Telegram API failures NEVER exit: silent backoff, keep polling.
#
# Forum setup: the forum supergroup's chat_id must be in $DIR/forum_chat_id
# (first line). Group messages from any other chat are logged to
# unknown_senders.log and ignored. The bot must be admin of the forum group
# (or have privacy mode disabled), otherwise it never sees topic messages.
#
# Env for tests: TG_DISPATCH_ONESHOT=1 processes a single poll cycle, then
# exits 0.
#
# State: offset.txt, last_sender.txt, accounts.json, forum_chat_id,
# topics/, unknown_senders.log, health.json, bridge.log.
# No message content is ever logged. No AI involved.
set -euo pipefail
DIR="${TG_BRIDGE_DIR:-$HOME/telegram-bridge}"
source "$DIR/bin/lib.sh"
mkdir -p "$DIR/run" "$DIR/topics"
LOCKDIR="$DIR/run/dispatch.lock"

if mkdir "$LOCKDIR" 2>/dev/null; then
  echo $$ > "$LOCKDIR/pid"
else
  OLDPID="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    echo "another dispatcher is already running (pid $OLDPID); exiting"
    exit 0
  fi
  bridge_log "DISPATCHER taking over stale lock (was pid ${OLDPID:-unknown})"
  echo $$ > "$LOCKDIR/pid"
fi
release_lock() { rm -rf "$LOCKDIR"; }
trap release_lock EXIT
trap 'exit 0' TERM INT

bridge_log "DISPATCHER started (pid $$)"

# Keep the outbox daemon alive (detached; survives our restarts).
ensure_outbox() {
  pgrep -f "$DIR/bin/tg-outbo[x].sh" >/dev/null && return 0
  (
    flock -n 9 || exit 0
    pgrep -f "$DIR/bin/tg-outbo[x].sh" >/dev/null && exit 0
    bridge_log "DISPATCHER starting tg-outbox.sh"
    setsid nohup bash "$DIR/bin/tg-outbox.sh" >>"$DIR/outbox_daemon.log" 2>&1 &
    echo $! > "$DIR/run/outbox.pid"
  ) 9>"$DIR/run/outbox.lock"
}
ensure_outbox

OFFSET_FILE="$DIR/offset.txt"
HEARTBEAT="$DIR/last_poll.txt"
ACCOUNTS="$DIR/accounts.json"
FORUM="$DIR/forum_chat_id"
UNKNOWN="$DIR/unknown_senders.log"
LAST_SENDER="$DIR/last_sender.txt"
TG="${TG_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tg}"
TOPICS="$DIR/topics"
QLOCK="$TOPICS/.lock"
MAX_FAILURES="${DISPATCH_MAX_FAILURES:-10}"
FAIL_STEP="${DISPATCH_FAIL_STEP:-5}"
FAILURES=0
ONESHOT="${TG_DISPATCH_ONESHOT:-0}"

api_failure() {
  FAILURES=$((FAILURES + 1))
  BACKOFF=$(( FAILURES * FAIL_STEP > 60 ? 60 : FAILURES * FAIL_STEP ))
  bridge_log "DISPATCHER tg updates failed ${FAILURES}x in a row; backoff ${BACKOFF}s"
  sleep "$BACKOFF"
}

while true; do
  ensure_outbox
  OFFSET="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
  if RAW="$(python3 "$TG" updates --timeout 45 --offset "$OFFSET" 2>&1)"; then
    FAILURES=0
    NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '%s\n' "$NOW" > "$HEARTBEAT"
    bridge_health inbox last_poll set "$NOW"
    set +e
    OFFSET_FILE="$OFFSET_FILE" ACCOUNTS="$ACCOUNTS" FORUM="$FORUM" UNKNOWN="$UNKNOWN" \
    LAST_SENDER="$LAST_SENDER" BRIDGE_DIR="$DIR" TOPICS="$TOPICS" QLOCK="$QLOCK" \
    python3 - "$RAW" <<'PYEOF'
import fcntl, json, os, subprocess, sys
from datetime import datetime, timezone
raw = sys.argv[1]
bridge = os.environ["BRIDGE_DIR"]
offset_file = os.environ["OFFSET_FILE"]
unknown_log = os.environ["UNKNOWN"]
last_sender = os.environ["LAST_SENDER"]
topics_dir = os.environ["TOPICS"]
qlock = os.environ["QLOCK"]
log_path = os.path.join(bridge, "bridge.log")
forum_path = os.environ["FORUM"]

def blog(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(f"{ts} {msg}\n")

def bhealth(section, key, op, val=None):
    cmd = ["python3", os.path.join(bridge, "bin", "health.py"), section, key, op]
    if val is not None:
        cmd.append(val)
    subprocess.run(cmd, env={**os.environ, "TG_BRIDGE_DIR": bridge}, check=False)

def enqueue(queue, line):
    os.makedirs(topics_dir, exist_ok=True)
    qpath = os.path.join(topics_dir, f"{queue}.queue")
    with open(qlock, "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(qpath, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)

try:
    with open(os.environ["ACCOUNTS"], encoding="utf-8") as f:
        accounts = json.load(f)
except Exception as e:
    print(f"[DISPATCHER ERROR] cannot read accounts.json: {e}")
    sys.exit(3)
try:
    with open(forum_path, encoding="utf-8") as f:
        forum_id = f.read().strip().split()[0]
except Exception:
    forum_id = ""
try:
    data = json.loads(raw)
except Exception as e:
    print(f"[DISPATCHER ERROR] bad JSON from tg updates: {e}")
    sys.exit(3)
if not data.get("ok"):
    if data.get("error_code") == 401:
        print(f"[DISPATCHER ERROR] telegram api unauthorized (401): {data.get('description')}")
        sys.exit(3)
    blog(f"WARN: telegram api transient: {str(data)[:200]}")
    print(f"WARN: telegram api transient: {str(data)[:200]}", file=sys.stderr)
    sys.exit(4)
try:
    from zoneinfo import ZoneInfo
    tz = ZoneInfo("Asia/Jerusalem")
except Exception:
    tz = timezone.utc

MEDIA = (("photo", "תמונה"), ("voice", "הודעה קולית"), ("video", "וידאו"),
         ("video_note", "סרטון עגול"), ("document", "קובץ"), ("sticker", "סטיקר"),
         ("audio", "אודיו"), ("location", "מיקום"), ("contact", "איש קשר"))

def describe(msg):
    text = msg.get("text")
    if text:
        return text
    for key, label in MEDIA:
        if key in msg:
            extra = ""
            sub = msg.get(key) or {}
            if key == "document" and sub.get("file_name"):
                extra = f" {sub['file_name']}"
            elif key == "sticker" and sub.get("emoji"):
                extra = f" {sub['emoji']}"
            elif key == "voice" and sub.get("duration"):
                extra = f" ({sub['duration']} שניות)"
            cap = msg.get("caption")
            tail = f" {cap}" if cap else ""
            return f"[{label}{extra}]{tail}"
    return None

def unknown(key, why):
    ts = datetime.now(tz).strftime("%Y-%m-%d %H:%M:%S")
    with open(unknown_log, "a", encoding="utf-8") as f:
        f.write(f"{ts} unknown {why}={key}\n")

max_id = None
count = 0
seen_unknown = set()
for u in data.get("result", []):
    uid = u.get("update_id")
    if isinstance(uid, int) and (max_id is None or uid > max_id):
        max_id = uid
    msg = u.get("message") or {}
    chat = msg.get("chat") or {}
    cid = chat.get("id")
    body = describe(msg)
    if body is None or not isinstance(cid, int):
        continue
    mid = msg.get("message_id")
    mids = f"#{mid}" if isinstance(mid, int) else ""
    hhmm = datetime.fromtimestamp(msg.get("date", 0), tz).strftime("%H:%M")
    if chat.get("type") != "private":
        # Forum/group message: only our configured forum group is accepted.
        if not forum_id or str(cid) != forum_id:
            if str(cid) not in seen_unknown:
                seen_unknown.add(str(cid))
                unknown(cid, "group chat_id")
            continue
        sender = (msg.get("from") or {}).get("id")
        key = str(sender) if isinstance(sender, int) else ""
        if key not in accounts:
            if key not in seen_unknown:
                seen_unknown.add(key)
                unknown(key or "?", "group sender")
            continue
        name = accounts[key]
        thread = msg.get("message_thread_id")
        if isinstance(thread, int) and thread != 1:
            queue, suffix = str(thread), ""
        else:
            queue, suffix = "_main", " @general"
        enqueue(queue, f"[Telegram {hhmm} @{name}{mids}{suffix}] {body}")
    else:
        key = str(cid)
        if key not in accounts:
            if key not in seen_unknown:
                seen_unknown.add(key)
                unknown(key, "chat_id")
            continue
        name = accounts[key]
        enqueue("_main", f"[Telegram {hhmm} @{name}{mids}] {body}")
        with open(last_sender, "w") as f:
            f.write(key)
    count += 1
    bhealth("inbox", "messages_in", "incr")
    bhealth("inbox", "last_message_at", "set",
            datetime.now(tz).strftime("%Y-%m-%d %H:%M:%S"))
if max_id is not None:
    with open(offset_file, "w") as f:
        f.write(str(max_id + 1))
if count:
    blog(f"DISPATCH {count} message(s) queued")
PYEOF
    RC=$?
    set -e
    case "$RC" in
      0) ;;
      3) exit 2 ;;      # fatal: wake the agent once
      *) api_failure ;; # transient: silent backoff, keep polling
    esac
  else
    api_failure
  fi
  if [ "$ONESHOT" = "1" ]; then exit 0; fi
done
