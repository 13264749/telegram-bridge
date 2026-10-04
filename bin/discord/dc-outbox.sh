#!/usr/bin/env bash
# dc-outbox.sh — Discord outbox sender daemon (worker).
# Managed by bin/discord/dc-dispatch.sh (ensure_outbox).
#
# Queue entries in outbox.txt are separated by __TG_SEND__ lines.
# An entry may start with a routing tag line: [Discord→name]
# (name = display name from discord_accounts.json, or a numeric user_id).
# The tag is stripped before sending; the recipient never sees it.
# An optional __REPLY_TO__<message_id> line right after the tag threads
# the message as a reply to that inbound message; it is also stripped.
# An optional __THREAD__<channel_id> line routes the message into that
# Discord channel/thread (threads ARE channels in Discord). Stripped too.
# Entries without a tag go to the most recent inbound sender's DM
# (discord_last_sender.txt), falling back to the first account in
# discord_accounts.json.
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
ACCOUNTS="$DIR/discord_accounts.json"
LAST_SENDER="$DIR/discord_last_sender.txt"
DM_CACHE="$DIR/discord_dm_channels.json"
DC="${DC_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dc}"
SEP="__TG_SEND__"
POLL="${OUTBOX_POLL_INTERVAL:-2}"
touch "$OUTBOX"

# Recover a batch that was being processed when we were killed.
if [ -s "$PROCESSING" ]; then
  cat "$PROCESSING" >> "$OUTBOX"
  rm -f "$PROCESSING"
  bridge_log "OUTBOX(discord) recovered interrupted batch"
fi

while true; do
  if [ -s "$OUTBOX" ]; then
    mv "$OUTBOX" "$PROCESSING"   # atomic take-over; new appends land in a fresh file
    touch "$OUTBOX"
    OUTBOX_TMP="$PROCESSING" SEP="$SEP" ACCOUNTS="$ACCOUNTS" LAST_SENDER="$LAST_SENDER" DC="$DC" \
    DM_CACHE="$DM_CACHE" BRIDGE_DIR="$DIR" OUTBOX="$OUTBOX" DEAD="$DEAD" STATE="$STATE" \
    MAX_ATTEMPTS="${OUTBOX_MAX_ATTEMPTS:-6}" \
    BACKOFFS="${OUTBOX_BACKOFFS:-5,15,60,300,900,1800}" \
    python3 <<'PYEOF'
import hashlib, json, os, re, subprocess, time
from datetime import datetime
bridge = os.environ["BRIDGE_DIR"]
path = os.environ["OUTBOX_TMP"]; sep = os.environ["SEP"]
dc = os.environ["DC"]
outbox = os.environ["OUTBOX"]; dead = os.environ["DEAD"]; state_path = os.environ["STATE"]
log_path = os.path.join(bridge, "bridge.log")
accounts_path = os.environ["ACCOUNTS"]; last_sender_path = os.environ["LAST_SENDER"]
dm_cache_path = os.environ["DM_CACHE"]
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

def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default

def save_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    os.replace(tmp, path)

accounts = load_json(accounts_path, {})
state = load_json(state_path, {})
dm_cache = load_json(dm_cache_path, {})

TAG_RE = re.compile(r"^\[Discord→(.+?)\]\s*$")
REPLY_RE = re.compile(r"^__(?:TG_)?REPLY_TO__(\S+)\s*$")
THREAD_RE = re.compile(r"^__(?:TG_)?THREAD__(\S+)\s*$")

def dc_cli(*argv, timeout=60):
    env = dict(os.environ, TG_BRIDGE_DIR=bridge)
    if "DISCORD_TOKEN" in os.environ:
        env["DISCORD_TOKEN"] = os.environ["DISCORD_TOKEN"]
    p = subprocess.run(["python3", dc] + list(argv), capture_output=True,
                       text=True, timeout=timeout + 10, env=env)
    try:
        return json.loads(p.stdout or "{}")
    except Exception:
        return {"ok": False, "error_code": "local"}

def dm_channel(user_id):
    """Resolve a user_id to a DM channel id (cached)."""
    cid = dm_cache.get(str(user_id))
    if cid:
        return cid
    r = dc_cli("open-dm", "--user-id", str(user_id))
    if isinstance(r, dict) and r.get("id"):
        dm_cache[str(user_id)] = str(r["id"])
        save_json(dm_cache_path, dm_cache)
        return str(r["id"])
    return None

def resolve(tag):
    if tag:
        tag = tag.strip()
        if tag.isdigit() and tag in accounts:
            return ("user", tag)
        for uid, name in accounts.items():
            if name == tag:
                return ("user", uid)
    try:
        with open(last_sender_path, encoding="utf-8") as f:
            uid = f.read().strip()
        if uid in accounts:
            return ("user", uid)
    except Exception:
        pass
    if accounts:
        return ("user", next(iter(accounts)))
    return (None, None)

def name_of(uid):
    return "@" + str(accounts.get(str(uid), uid))

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
    kind, target = (("channel", thread) if thread else resolve(tag))
    channel_id = None
    if kind == "channel":
        channel_id = target
    elif kind == "user":
        channel_id = dm_channel(target)
    if not channel_id or not body:
        requeue.append(chunk)
        continue
    eid = hashlib.sha256(f"{channel_id}\n{body}".encode()).hexdigest()[:16]
    st = state.get(eid, {"attempts": 0, "next_try": 0})
    if now < st.get("next_try", 0):
        requeue.append(chunk)
        continue
    ok = False
    try:
        cmd = ["send", "--channel", str(channel_id), "--text", body]
        if reply_to:
            cmd += ["--reply-to", reply_to]
        res = dc_cli(*cmd)
        # dc send prints a JSON list; each item has "id" on success
        ok = isinstance(res, list) and all(
            isinstance(x, dict) and x.get("id") for x in res)
    except Exception:
        ok = False
    if ok:
        state.pop(eid, None)
        health("outbox", "sends", "incr")
        health("outbox", "last_send_at", "set", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        log(f"OUT(discord) {name_of(target)} ok")
    else:
        st["attempts"] = st.get("attempts", 0) + 1
        if st["attempts"] >= max_attempts:
            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            with open(dead, "a", encoding="utf-8") as f:
                f.write(f"=== {ts} -> {name_of(target)} (tag={tag}) ===\n{chunk}\n")
            health("outbox", "dead_letters", "incr")
            log(f"OUT(discord) {name_of(target)} FAILED after {max_attempts} attempts -> dead_letters")
            state.pop(eid, None)
        else:
            delay = backoffs[min(st["attempts"] - 1, len(backoffs) - 1)]
            st["next_try"] = now + delay
            state[eid] = st
            requeue.append(chunk)
            log(f"OUT(discord) {name_of(target)} attempt {st['attempts']} failed; retry in {delay}s")

if requeue:
    with open(outbox, "a", encoding="utf-8") as f:
        for c in requeue:
            f.write(c + "\n" + sep + "\n")
save_json(state_path, state)
PYEOF
  fi
  wait_for_change "$OUTBOX" "$POLL"
done
