#!/usr/bin/env bash
# tg-inbox.sh — persistent multi-account Telegram listener (worker).
# Managed by tg-supervisor.sh. Long-polls in an internal loop and exits ONLY
# when new messages arrive from an authorized account (prints them as
# [Telegram HH:MM @name#message_id] lines, exit 0).
#
# Exit codes (the supervisor acts on them):
#   0 — message(s) arrived (output = tagged lines)
#   1 — transient Telegram API failure, persistent (wake NOBODY; back off)
#   2 — fatal/config error, e.g. unreadable accounts.json or API 401
#       (wake the agent exactly once)
#
# Empty cycles loop silently. Text messages are injected verbatim; media
# arrives as placeholders ([תמונה], [הודעה קולית], ...) with captions.
#
# State: offset.txt, last_sender.txt, accounts.json, unknown_senders.log,
# health.json, bridge.log. No message content is ever logged. No AI involved.
set -euo pipefail
DIR="${TG_BRIDGE_DIR:-$HOME/telegram-bridge}"
source "$DIR/bin/lib.sh"
OFFSET_FILE="$DIR/offset.txt"
HEARTBEAT="$DIR/last_poll.txt"
ACCOUNTS="$DIR/accounts.json"
UNKNOWN="$DIR/unknown_senders.log"
LAST_SENDER="$DIR/last_sender.txt"
TG="${TG_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tg}"
INBOX_MAX_FAILURES="${INBOX_MAX_FAILURES:-10}"
INBOX_FAIL_STEP="${INBOX_FAIL_STEP:-5}"
FAILURES=0

api_failure() {
  FAILURES=$((FAILURES + 1))
  if [ "$FAILURES" -ge "$INBOX_MAX_FAILURES" ]; then
    bridge_log "ERROR tg updates failed ${FAILURES}x in a row"
    echo "ERROR: tg updates failed ${FAILURES} times in a row"
    exit 1
  fi
  BACKOFF=$(( FAILURES * INBOX_FAIL_STEP > 60 ? 60 : FAILURES * INBOX_FAIL_STEP ))
  sleep "$BACKOFF"
}

while true; do
  OFFSET="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
  if RAW="$(python3 "$TG" updates --timeout 45 --offset "$OFFSET" 2>&1)"; then
    NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '%s\n' "$NOW" > "$HEARTBEAT"
    bridge_health inbox last_poll set "$NOW"
    set +e
    OUT="$(OFFSET_FILE="$OFFSET_FILE" ACCOUNTS="$ACCOUNTS" UNKNOWN="$UNKNOWN" LAST_SENDER="$LAST_SENDER" BRIDGE_DIR="$DIR" python3 - "$RAW" <<'PYEOF'
import json, os, subprocess, sys
from datetime import datetime, timezone
raw = sys.argv[1]
bridge = os.environ["BRIDGE_DIR"]
offset_file = os.environ["OFFSET_FILE"]
unknown_log = os.environ["UNKNOWN"]
last_sender = os.environ["LAST_SENDER"]
log_path = os.path.join(bridge, "bridge.log")

def blog(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(f"{ts} {msg}\n")

def bhealth(section, key, op, val=None):
    cmd = ["python3", os.path.join(bridge, "bin", "health.py"), section, key, op]
    if val is not None:
        cmd.append(val)
    subprocess.run(cmd, env={**os.environ, "TG_BRIDGE_DIR": bridge}, check=False)

try:
    with open(os.environ["ACCOUNTS"], encoding="utf-8") as f:
        accounts = json.load(f)
except Exception as e:
    print(f"ERROR: cannot read accounts.json: {e}", file=sys.stderr)
    sys.exit(3)
try:
    data = json.loads(raw)
except Exception as e:
    print(f"ERROR: bad JSON from tg updates: {e}", file=sys.stderr)
    sys.exit(3)
if not data.get("ok"):
    if data.get("error_code") == 401:
        print(f"ERROR: telegram api unauthorized (401): {data.get('description')}", file=sys.stderr)
        sys.exit(3)
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

max_id = None
lines = []
seen_unknown = set()
last = None
count = 0
for u in data.get("result", []):
    uid = u.get("update_id")
    if isinstance(uid, int) and (max_id is None or uid > max_id):
        max_id = uid
    msg = u.get("message") or {}
    cid = (msg.get("chat") or {}).get("id")
    body = describe(msg)
    if body is None or not isinstance(cid, int):
        continue
    key = str(cid)
    if key in accounts:
        name = accounts[key]
        hhmm = datetime.fromtimestamp(msg.get("date", 0), tz).strftime("%H:%M")
        mid = msg.get("message_id")
        tag = f"[Telegram {hhmm} @{name}#{mid}]" if isinstance(mid, int) \
            else f"[Telegram {hhmm} @{name}]"
        lines.append(f"{tag} {body}")
        last = key
        count += 1
        bhealth("inbox", "messages_in", "incr")
        bhealth("inbox", "last_message_at", "set",
                datetime.now(tz).strftime("%Y-%m-%d %H:%M:%S"))
    elif key not in seen_unknown:
        seen_unknown.add(key)
        ts = datetime.now(tz).strftime("%Y-%m-%d %H:%M:%S")
        with open(unknown_log, "a", encoding="utf-8") as f:
            f.write(f"{ts} unknown chat_id={key}\n")
if max_id is not None:
    with open(offset_file, "w") as f:
        f.write(str(max_id + 1))
if last is not None:
    with open(last_sender, "w", encoding="utf-8") as f:
        f.write(last)
if count:
    blog(f"IN {count} message(s)")
if lines:
    print("\n".join(lines))
PYEOF
)"
    PYRC=$?
    set -e
    case "$PYRC" in
      0)
        FAILURES=0
        if [ -n "$OUT" ]; then
          printf '%s\n' "$OUT"
          exit 0
        fi
        # empty cycle: loop silently, nobody is woken
        ;;
      3)
        bridge_log "ERROR inbox fatal: $(printf '%s' "$OUT" | head -c 200)"
        printf '%s\n' "$OUT"
        exit 2
        ;;
      4)
        bridge_log "inbox: telegram api transient error"
        api_failure
        ;;
      *)
        bridge_log "ERROR inbox parser failed (rc=$PYRC)"
        echo "ERROR: inbox parser failed"
        exit 2
        ;;
    esac
  else
    bridge_log "inbox: tg CLI invocation failed"
    api_failure
  fi
done
