#!/usr/bin/env python3
"""Decide whether to suggest a conversation-chat rotation.

Called by tg-supervisor.sh on every message wake-up (script-side, zero quota).
Prints a single [SYSTEM rotate-suggest] line and exits 0 when the rotation
criteria are met and no suggestion was made recently; otherwise prints
nothing and exits 1.

Criteria (env-overridable):
  ROTATE_AFTER_MESSAGES (default 400) — inbound messages since last rotation
  ROTATE_AFTER_DAYS (default 56)      — days since last rotation
  ROTATE_SUGGEST_COOLDOWN_DAYS (default 14) — min days between suggestions

State: $TG_BRIDGE_DIR/rotation.json (auto-created on first run).
Message count source: health.json -> inbox.messages_in (incremented per message).
"""
import json
import os
import sys
from datetime import date, datetime

bridge = os.environ.get("TG_BRIDGE_DIR", os.path.expanduser("~/workspace/telegram_bridge"))
rot_path = os.path.join(bridge, "rotation.json")
health_path = os.path.join(bridge, "health.json")
log_path = os.path.join(bridge, "bridge.log")

AFTER_MESSAGES = int(os.environ.get("ROTATE_AFTER_MESSAGES", "400"))
AFTER_DAYS = int(os.environ.get("ROTATE_AFTER_DAYS", "56"))
COOLDOWN_DAYS = int(os.environ.get("ROTATE_SUGGEST_COOLDOWN_DAYS", "14"))


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def messages_in():
    try:
        return int(load_json(health_path).get("inbox", {}).get("messages_in") or 0)
    except Exception:
        return 0


def parse_day(s):
    try:
        y, m, d = (int(x) for x in str(s).split("-"))
        return date(y, m, d)
    except Exception:
        return None


def save(rot):
    try:
        with open(rot_path, "w", encoding="utf-8") as f:
            json.dump(rot, f, ensure_ascii=False, indent=1)
    except Exception:
        pass


def blog(msg):
    try:
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(f"{ts} {msg}\n")
    except Exception:
        pass


today = date.today()
rot = load_json(rot_path)
started = parse_day(rot.get("started_at"))
if started is None:
    started = today
    rot["started_at"] = today.isoformat()
    rot.setdefault("messages_at_start", messages_in())
    rot.setdefault("suggested_at", None)

try:
    at_start = int(rot.get("messages_at_start") or 0)
except Exception:
    at_start = 0
msgs = max(0, messages_in() - at_start)
days = max(0, (today - started).days)

if msgs >= AFTER_MESSAGES or days >= AFTER_DAYS:
    sug = parse_day(rot.get("suggested_at"))
    if sug is None or (today - sug).days >= COOLDOWN_DAYS:
        rot["suggested_at"] = today.isoformat()
        save(rot)
        blog(f"ROTATION suggested ({msgs} messages / {days} days since rotation)")
        print(f"[SYSTEM rotate-suggest] {msgs} הודעות / {days} ימים מאז רוטציה "
              f"(סף: {AFTER_MESSAGES} הודעות / {AFTER_DAYS} ימים). "
              f"הצע ליוני רוטציית צ'אט — פרטים ב־telegram_bridge/ROTATION.md.")
        sys.exit(0)

save(rot)  # persist first-run initialization
sys.exit(1)
