#!/usr/bin/env python3
"""Update bridge health.json. Usage: health.py <section> <key> <set|incr> [value]"""
import fcntl
import json
import os
import sys
from datetime import datetime

bridge = os.environ.get("TG_BRIDGE_DIR", os.path.expanduser("~/workspace/telegram_bridge"))
path = os.path.join(bridge, "health.json")
section, key, op = sys.argv[1], sys.argv[2], sys.argv[3]
val = sys.argv[4] if len(sys.argv) > 4 else None

os.makedirs(bridge, exist_ok=True)
with open(path, "a+") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.seek(0)
    try:
        data = json.load(f)
    except Exception:
        data = {}
    sec = data.setdefault(section, {})
    if op == "incr":
        try:
            sec[key] = int(sec.get(key, 0) or 0) + 1
        except Exception:
            sec[key] = 1
    else:
        sec[key] = val
    data["updated_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    f.seek(0)
    f.truncate()
    json.dump(data, f, ensure_ascii=False, indent=1)
