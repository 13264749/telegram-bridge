#!/usr/bin/env bash
# tg-outbox.sh — multi-account outbox sender daemon (worker).
# Managed by tg-supervisor.sh.
#
# Queue entries in outbox.txt are separated by __TG_SEND__ lines.
# An entry may start with a routing tag line: [Telegram→name]
# (name = display name from accounts.json, or a numeric chat_id).
# The tag is stripped before sending; the recipient never sees it.
# An optional __TG_REPLY_TO__<message_id> line right after the tag threads
# the message as a reply to that inbound message; it is also stripped.
# An optional __TG_THREAD__<thread_id|general> line routes the message into
# a forum topic of the group in $DIR/forum_chat_id (general = the group's
# General topic, sent without message_thread_id). Both markers are stripped
# before sending; the recipient never sees them.
# Entries without a tag go to the most recent inbound sender
# (last_sender.txt), falling back to the first account in accounts.json.
#
# Resilience: failed sends retry with exponential backoff (configurable via
# OUTBOX_BACKOFFS / OUTBOX_MAX_ATTEMPTS). After the final attempt the entry
# moves to dead_letters.txt. The in-progress batch lives in
# .outbox_processing inside the bridge dir, so a kill mid-batch is recovered
# on the next start instead of losing messages.
# No AI is involved here.
set -euo pipefail
DIR="${TG_BRIDGE_DIR:-$HOME/telegram-bridge}"
source "$DIR/bin/lib.sh"
OUTBOX="$DIR/outbox.txt"
PROCESSING="$DIR/.outbox_processing"
DEAD="$DIR/dead_letters.txt"
STATE="$DIR/outbox_state.json"
ACCOUNTS="$DIR/accounts.json"
LAST_SENDER="$DIR/last_sender.txt"
TG="${TG_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tg}"
SEP="__TG_SEND__"
POLL="${OUTBOX_POLL_INTERVAL:-2}"
touch "$OUTBOX"

# Recover a batch that was being processed when we were killed.
if [ -s "$PROCESSING" ]; then
  cat "$PROCESSING" >> "$OUTBOX"
  rm -f "$PROCESSING"
  bridge_log "OUTBOX recovered interrupted batch"
fi

while true; do
  if [ -s "$OUTBOX" ]; then
    mv "$OUTBOX" "$PROCESSING"   # atomic take-over; new appends land in a fresh file
    touch "$OUTBOX"
    OUTBOX_TMP="$PROCESSING" SEP="$SEP" ACCOUNTS="$ACCOUNTS" LAST_SENDER="$LAST_SENDER" TG="$TG" \
    BRIDGE_DIR="$DIR" OUTBOX="$OUTBOX" DEAD="$DEAD" STATE="$STATE" \
    MAX_ATTEMPTS="${OUTBOX_MAX_ATTEMPTS:-6}" \
    BACKOFFS="${OUTBOX_BACKOFFS:-5,15,60,300,900,1800}" \
    python3 <<'PYEOF'
import hashlib, json, os, re, subprocess, time
from datetime import datetime
bridge = os.environ["BRIDGE_DIR"]
path = os.environ["OUTBOX_TMP"]; sep = os.environ["SEP"]
tg = os.environ["TG"]
outbox = os.environ["OUTBOX"]; dead = os.environ["DEAD"]; state_path = os.environ["STATE"]
log_path = os.path.join(bridge, "bridge.log")
accounts_path = os.environ["ACCOUNTS"]; last_sender_path = os.environ["LAST_SENDER"]
max_attempts = int(os.environ["MAX_ATTEMPTS"])
backoffs = [float(x) for x in os.environ["BACKOFFS"].split(",") if x.strip()]

def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(f"{ts} {msg}\n")

def health(section, key, op, val=None):
    cmd = ["python3", os.path.join(bridge, "bin", "health.py"), section, key, op]
    if val is not None:
        cmd.append(val)
    subprocess.run(cmd, env={**os.environ, "TG_BRIDGE_DIR": bridge}, check=False)

try:
    with open(accounts_path, encoding="utf-8") as f:
        accounts = json.load(f)
except Exception:
    accounts = {}
try:
    with open(state_path, encoding="utf-8") as f:
        state = json.load(f)
except Exception:
    state = {}

TAG_RE = re.compile(r"^\[Telegram→(.+?)\]\s*$")
REPLY_RE = re.compile(r"^__(?:TG_)?REPLY_TO__(\S+)\s*$")
THREAD_RE = re.compile(r"^__(?:TG_)?THREAD__(general|\S+)\s*$")
FORUM_FILE = os.path.join(bridge, "forum_chat_id")

def forum_chat_id():
    try:
        with open(FORUM_FILE, encoding="utf-8") as f:
            return f.read().strip().split()[0] or None
    except Exception:
        return None

def resolve(tag):
    if tag:
        tag = tag.strip()
        if tag.isdigit() and tag in accounts:
            return tag
        for cid, name in accounts.items():
            if name == tag:
                return cid
    try:
        with open(last_sender_path, encoding="utf-8") as f:
            cid = f.read().strip()
        if cid in accounts:
            return cid
    except Exception:
        pass
    return next(iter(accounts)) if accounts else None

def name_of(cid):
    return "@" + str(accounts.get(str(cid), cid))

with open(path, encoding="utf-8") as f:
    content = f.read()
os.remove(path)
chunks = [c.strip("\n") for c in content.split(sep)]
chunks = [c for c in chunks if c.strip()]
now = time.time()
requeue = []
for chunk in chunks:
    lines = chunk.split("\n")
    m = TAG_RE.match(lines[0].strip())
    if m:
        tag, rest = m.group(1), lines[1:]
    else:
        tag, rest = None, lines
    reply_to = None
    thread = None
    while rest:
        rm = REPLY_RE.match(rest[0].strip())
        tm = THREAD_RE.match(rest[0].strip())
        if rm:
            reply_to = rm.group(1)
        elif tm:
            thread = tm.group(1)
        else:
            break
        rest = rest[1:]
    body = "\n".join(rest).strip()
    if thread:
        target = forum_chat_id()
        if not target:
            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            with open(dead, "a", encoding="utf-8") as f:
                f.write(f"=== {ts} -> thread {thread} (no forum_chat_id configured) ===\n{chunk}\n")
            health("outbox", "dead_letters", "incr")
            log(f"OUT thread {thread} FAILED: forum_chat_id not configured -> dead_letters")
            continue
        thread_id = None if thread == "general" else thread
    else:
        target = resolve(tag)
        thread_id = None
    if not target or not body:
        requeue.append(chunk)
        continue
    eid = hashlib.sha256(f"{target}\n{body}".encode()).hexdigest()[:16]
    st = state.get(eid, {"attempts": 0, "next_try": 0})
    if now < st.get("next_try", 0):
        requeue.append(chunk)
        continue
    ok = False
    try:
        cmd = ["python3", tg, "send", "--chat-id", str(target), "--text", body]
        if reply_to:
            cmd += ["--reply-to", reply_to]
        if thread_id:
            cmd += ["--thread-id", thread_id]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        res = json.loads(r.stdout)
        ok = r.returncode == 0 and all(isinstance(x, dict) and x.get("ok") for x in res)
    except Exception:
        ok = False
    if ok:
        state.pop(eid, None)
        health("outbox", "sends", "incr")
        health("outbox", "last_send_at", "set", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        log(f"OUT {name_of(target)} ok")
    else:
        st["attempts"] = st.get("attempts", 0) + 1
        if st["attempts"] >= max_attempts:
            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            with open(dead, "a", encoding="utf-8") as f:
                f.write(f"=== {ts} -> {name_of(target)} (tag={tag}) ===\n{chunk}\n")
            state.pop(eid, None)
            health("outbox", "dead_letters", "incr")
            log(f"OUT {name_of(target)} FAILED after {st['attempts']} attempts -> dead_letters")
        else:
            wait = backoffs[min(st["attempts"] - 1, len(backoffs) - 1)]
            st["next_try"] = now + wait
            state[eid] = st
            requeue.append(chunk)
            log(f"OUT {name_of(target)} failed (attempt {st['attempts']}), retry in {wait:g}s")
with open(state_path, "w", encoding="utf-8") as f:
    json.dump(state, f)
if requeue:
    with open(outbox, "a", encoding="utf-8") as f:
        for chunk in requeue:
            f.write(chunk + "\n" + sep + "\n")
PYEOF
  fi
  sleep "$POLL"
done
