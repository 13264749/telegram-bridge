#!/usr/bin/env bash
# dc-dispatch.sh — Discord poller + per-topic queue router.
#
# The Discord half of a bridge instance whose transport is Discord
# (scaffolded with new-bot.sh --source discord). Polls the watched
# channels via REST (GET /channels/{id}/messages?after=...) and appends
# each message from an authorized user as a tagged line to a per-topic
# queue file under topics/:
#   topics/_main.queue        — DMs (+ anything mapped there)
#   topics/<queue>.queue      — per discord.json queue mapping / threads
#
# Tagged line format:
#   [Discord HH:MM @name#message_id] <body>
#
# A per-topic watcher (tg-topic-watch.sh — transport-agnostic) prints new
# lines and exits, waking the topic's agent. Replies go through
# bin/discord/dc-outbox.sh.
#
# Never exits on transient errors (backoff, honors Discord retry_after);
# exits 2 on fatal/config errors (bad token/401), printing
# [DISPATCHER ERROR] to wake the agent exactly once.
#
# Config: discord.json in the bridge dir:
#   {"channels": ["<id>"], "queues": {"<id>": "<queue>"},
#    "discover_dms": true, "auto_threads": true, "poll_interval": 5}
# State: discord_cursors.json, discord_last_sender.txt,
# discord_accounts.json, unknown_senders.log, health.json, bridge.log.
# Env for tests: DC_DISPATCH_ONESHOT=1 processes a single poll cycle.
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
  bridge_log "DISPATCHER(discord) taking over stale lock (was pid ${OLDPID:-unknown})"
  echo $$ > "$LOCKDIR/pid"
fi
release_lock() { rm -rf "$LOCKDIR"; }
trap release_lock EXIT
trap 'exit 0' TERM INT

bridge_log "DISPATCHER(discord) started (pid $$)"

# Keep the Discord outbox daemon alive (detached; survives our restarts).
ensure_outbox() {
  pgrep -f "$DIR/bin/discord/dc-outbo[x].sh" >/dev/null && return 0
  (
    flock -n 9 || exit 0
    pgrep -f "$DIR/bin/discord/dc-outbo[x].sh" >/dev/null && exit 0
    bridge_log "DISPATCHER(discord) starting dc-outbox.sh"
    setsid nohup bash "$DIR/bin/discord/dc-outbox.sh" >>"$DIR/outbox_daemon.log" 2>&1 &
    echo $! > "$DIR/run/outbox.pid"
  ) 9>"$DIR/run/outbox.lock"
}
ensure_outbox

DC="${DC_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dc}"
ONESHOT="${DC_DISPATCH_ONESHOT:-0}"

while true; do
  ensure_outbox
  set +e
  TG_BRIDGE_DIR="$DIR" DC_BIN="$DC" DC_DISPATCH_ONESHOT="$ONESHOT" \
  python3 - <<'PYEOF'
import fcntl, json, os, subprocess, sys, time
from datetime import datetime

bridge = os.environ["TG_BRIDGE_DIR"]
dc = os.environ["DC_BIN"]
oneshot = os.environ.get("DC_DISPATCH_ONESHOT") == "1"
cfg_path = os.path.join(bridge, "discord.json")
cursors_path = os.path.join(bridge, "discord_cursors.json")
accounts_path = os.path.join(bridge, "discord_accounts.json")
unknown_log = os.path.join(bridge, "unknown_senders.log")
last_sender = os.path.join(bridge, "discord_last_sender.txt")
topics_dir = os.path.join(bridge, "topics")
qlock = os.path.join(topics_dir, ".lock")
log_path = os.path.join(bridge, "bridge.log")
me_path = os.path.join(bridge, "discord_me.json")

def blog(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_path, "a", encoding="utf-8") as f:
        f.write("%s %s\n" % (ts, msg))

def dc_call(*argv, timeout=30):
    p = subprocess.run([dc] + list(argv), capture_output=True, text=True,
                       timeout=timeout + 10,
                       env=dict(os.environ, TG_BRIDGE_DIR=bridge))
    try:
        return json.loads(p.stdout or "{}")
    except Exception:
        return {"ok": False, "error_code": "local",
                "description": (p.stderr or "")[:200]}

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

def enqueue(queue, line):
    if not queue.replace("_", "").isalnum():
        queue = "_main"
    qpath = os.path.join(topics_dir, queue + ".queue")
    os.makedirs(topics_dir, exist_ok=True)
    with open(qlock, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        with open(qpath, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        fcntl.flock(lf, fcntl.LOCK_UN)

# --- config (fatal if missing/unparsable) ---
cfg = load_json(cfg_path, None)
if not isinstance(cfg, dict):
    print("[DISPATCHER ERROR] discord: missing or invalid discord.json", flush=True)
    blog("DISPATCHER(discord) FATAL: bad discord.json")
    sys.exit(2)

# --- who am I (skip own messages) ---
me = load_json(me_path, {})
if not me.get("id"):
    r = dc_call("getme")
    if isinstance(r, dict) and r.get("id"):
        me = {"id": str(r["id"]), "username": r.get("username", "")}
        save_json(me_path, me)
    elif r.get("error_code") == 401:
        print("[DISPATCHER ERROR] discord: unauthorized (401) — bad token", flush=True)
        blog("DISPATCHER(discord) FATAL: 401")
        sys.exit(2)
    else:
        blog("DISPATCHER(discord) getme failed: %s" % str(r)[:120])
        sys.exit(0 if oneshot else 1)
my_id = str(me.get("id", ""))

accounts = load_json(accounts_path, {})
cursors = load_json(cursors_path, {})
poll_interval = int(cfg.get("poll_interval", 5))

# --- channel set ---
watch = {}  # channel_id -> queue
for cid in cfg.get("channels", []):
    watch[str(cid)] = cfg.get("queues", {}).get(str(cid), "_main")

if cfg.get("discover_dms", True):
    r = dc_call("dm-channels")
    if isinstance(r, list):
        for ch in r:
            cid = str(ch.get("id", ""))
            if cid and ch.get("type") == 1:  # DM
                watch.setdefault(cid, "_main")
    elif isinstance(r, dict) and r.get("error_code") == 401:
        print("[DISPATCHER ERROR] discord: unauthorized (401) — bad token", flush=True)
        sys.exit(2)

if cfg.get("auto_threads", True):
    for cid in list(watch):
        r = dc_call("list-threads", "--channel", cid)
        if isinstance(r, dict) and isinstance(r.get("threads"), list):
            for th in r["threads"]:
                tid = str(th.get("id", ""))
                if tid:
                    watch.setdefault(tid, "thread_" + tid)

# --- poll ---
now = datetime.now().strftime("%Y-%m-%d %H:%M:%S %Z")
with open(os.path.join(bridge, "last_poll.txt"), "w") as f:
    f.write(now + "\n")

had_fatal = False
for cid, queue in sorted(watch.items()):
    after = cursors.get(cid)
    argv = ["messages", "--channel", cid, "--limit", "50"]
    if after:
        argv += ["--after", after]
    r = dc_call(*argv)
    if isinstance(r, dict) and not r.get("ok", True):
        if r.get("error_code") == 401:
            print("[DISPATCHER ERROR] discord: unauthorized (401) — bad token", flush=True)
            had_fatal = True
            break
        ra = r.get("retry_after")
        if ra:
            blog("DISPATCHER(discord) 429, sleeping %ss" % ra)
            time.sleep(float(ra) + 0.5)
        else:
            blog("DISPATCHER(discord) poll failed for %s: %s" % (cid, str(r)[:120]))
        continue
    if not isinstance(r, list):
        continue
    # messages come newest-first; handle oldest-first
    for m in reversed(r):
        mid = str(m.get("id", ""))
        author = m.get("author") or {}
        uid = str(author.get("id", ""))
        if not mid or not uid:
            continue
        if uid == my_id or author.get("bot"):
            cursors[cid] = mid
            continue
        name = accounts.get(uid)
        if name is None:
            name = "unknown_%s" % uid
            with open(unknown_log, "a", encoding="utf-8") as f:
                f.write("%s discord:%s\n" % (datetime.now().strftime("%Y-%m-%d %H:%M"), uid))
        content = (m.get("content") or "").replace("\n", " ").strip()
        if not content:
            content = "[attachment]" if m.get("attachments") else "[no text]"
        hhmm = datetime.now().strftime("%H:%M")
        enqueue(queue, "[Discord %s @%s#%s] %s" % (hhmm, name, mid, content))
        with open(last_sender, "w") as f:
            f.write(uid)
        cursors[cid] = mid

save_json(cursors_path, cursors)
sys.exit(2 if had_fatal else 0)
PYEOF
  RC=$?
  set -e
  if [ "$RC" = "2" ]; then exit 2; fi
  if [ "$ONESHOT" = "1" ]; then exit "$RC"; fi
  if [ "$RC" != "0" ]; then
    bridge_log "DISPATCHER(discord) cycle failed rc=$RC; backoff 15s"
    sleep 15
  else
    sleep "${DC_POLL_INTERVAL:-5}"
  fi
done
