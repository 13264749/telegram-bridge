#!/usr/bin/env python3
"""llm_agent.py — example agent: answer Telegram messages with an LLM.

Reads the queue via bin/tg-topic-watch.sh, calls an OpenAI-compatible
chat-completions API, appends replies to outbox.txt (see
docs/AGENT_PROTOCOL.md for the full contract).

Env:
  TG_BRIDGE_DIR   bridge dir (default: repo root)
  TOPIC_QUEUE     queue to watch (default: _main)
  LLM_API_KEY     (required)
  LLM_BASE_URL    (default: https://api.openai.com/v1)
  LLM_MODEL       (default: gpt-4o-mini)
  SYSTEM_PROMPT   (default: "You are a helpful assistant chatting on Telegram. Be concise.")
  HISTORY_LIMIT   recent exchanges kept per sender (default: 40)
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import urllib.request

DIR = os.environ.get("TG_BRIDGE_DIR",
                     os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QUEUE = os.environ.get("TOPIC_QUEUE", "_main")
SOURCE = os.environ.get("BRIDGE_SOURCE", "telegram")
BIN = os.path.join(DIR, "bin")
OUTBOX_BIN = os.path.join(BIN, "discord", "dc-outbox.sh") if SOURCE == "discord" \
    else os.path.join(BIN, "tg-outbox.sh")
API_KEY = os.environ.get("LLM_API_KEY", "")
BASE_URL = os.environ.get("LLM_BASE_URL", "https://api.openai.com/v1").rstrip("/")
MODEL = os.environ.get("LLM_MODEL", "gpt-4o-mini")
SYSTEM_PROMPT = os.environ.get(
    "SYSTEM_PROMPT",
    "You are a helpful assistant chatting on Telegram. Be concise.")
HISTORY_LIMIT = int(os.environ.get("HISTORY_LIMIT", "40"))

LINE_RE = re.compile(r"^\[(\w+) \d\d:\d\d @([^#]+)#(\d+)([^]]*)\] (.*)$")
histories = {}


def chat(messages):
    body = json.dumps({"model": MODEL, "messages": messages}).encode("utf-8")
    req = urllib.request.Request(
        BASE_URL + "/chat/completions", data=body, method="POST",
        headers={"Authorization": "Bearer " + API_KEY,
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data["choices"][0]["message"]["content"]


def outbox_append(block):
    path = os.path.join(DIR, "outbox.txt")
    lock = os.path.join(DIR, ".outbox.lock")
    with open(lock, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(block)
        fcntl.flock(lf, fcntl.LOCK_UN)


def reply(source, name, msg_id, thread, text):
    lines = []
    if name:
        lines.append("[%s→%s]" % (source, name))
    if thread:
        lines.append("__THREAD__%s" % thread)
    if msg_id:
        lines.append("__REPLY_TO__%s" % msg_id)
    lines.append(text)
    lines.append("__TG_SEND__")
    outbox_append("\n".join(lines) + "\n")


def route_for(name, flags):
    rname = name
    if rname.startswith("unknown_"):
        rname = rname[len("unknown_"):]
    thread = ""
    if "@general" in flags:
        thread = "general"
    if QUEUE != "_main":
        thread = QUEUE
        rname = ""
    return rname, thread


def handle_newtopic(source, name, msg_id, thread, text):
    topic = text[len("/newtopic"):].strip()
    if not topic:
        reply(source, name, msg_id, thread, "Usage: /newtopic <name>")
        return
    env = dict(os.environ, TG_BRIDGE_DIR=DIR)
    if source == "Discord":
        dc = os.path.join(BIN, "discord", "dc")
        cfg = {}
        try:
            with open(os.path.join(DIR, "discord.json"), encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception:
            pass
        channels = [str(c) for c in cfg.get("channels", [])]
        if not channels:
            reply(source, name, msg_id, thread,
                  "No channels configured in discord.json.")
            return
        try:
            out = subprocess.run(
                [dc, "create-thread", "--channel", channels[0], "--name", topic],
                capture_output=True, text=True, timeout=60, env=env)
            data = json.loads(out.stdout or "{}")
            tid = data.get("id")
        except Exception as exc:
            reply(source, name, msg_id, thread, "Failed to create thread: %s" % exc)
            return
        if not tid:
            reply(source, name, msg_id, thread, "Failed to create thread.")
            return
        reply(source, name, msg_id, thread,
              "Thread '%s' created. Start its agent with: "
              "TOPIC_QUEUE=thread_%s python3 examples/llm_agent.py" % (topic, tid))
        return
    # Telegram
    forum_file = os.path.join(DIR, "forum_chat_id")
    if not os.path.isfile(forum_file):
        reply(source, name, msg_id, thread,
              "No forum group configured yet (see docs/TOPICS.md).")
        return
    forum = open(forum_file).read().strip()
    tg = os.path.join(BIN, "tg")
    try:
        out = subprocess.run(
            [tg, "create-topic", "--chat-id", forum, "--name", topic],
            capture_output=True, text=True, timeout=60, env=env)
        data = json.loads(out.stdout or "{}")
        tid = (data.get("result") or {}).get("message_thread_id")
    except Exception as exc:
        reply(source, name, msg_id, thread, "Failed to create topic: %s" % exc)
        return
    if not tid:
        reply(source, name, msg_id, thread,
              "Failed to create topic: %s" % (data.get("description") or "API error") +
              " — is the bot admin with Manage Topics?")
        return
    reply(source, name, msg_id, thread,
          "Topic '%s' created (id %s). Start its agent with: "
          "TOPIC_QUEUE=%s python3 examples/llm_agent.py" % (topic, tid, tid))


def handle_line(line):
    if line.startswith("[SYSTEM "):
        return
    m = LINE_RE.match(line)
    if not m:
        return
    source, name, msg_id, flags, text = (m.group(1), m.group(2), m.group(3),
                                        m.group(4), m.group(5))
    rname, thread = route_for(name, flags)
    if text == "/start":
        reply(source, rname, msg_id, thread,
              "Hi! I'm an LLM on %s. Send me anything, or try /help." % source)
        return
    if text == "/help":
        reply(source, rname, msg_id, thread,
              "Commands: /start, /help, /newtopic <name>. "
              "Anything else goes to the model.")
        return
    if text.startswith("/newtopic"):
        handle_newtopic(source, rname, msg_id, thread, text)
        return
    hist = histories.setdefault(name, [])
    hist.append({"role": "user", "content": text})
    hist = hist[-HISTORY_LIMIT:]
    histories[name] = hist
    try:
        answer = chat([{"role": "system", "content": SYSTEM_PROMPT}] + hist)
    except Exception as exc:
        reply(source, rname, msg_id, thread, "Model error: %s" % exc)
        return
    hist.append({"role": "assistant", "content": answer})
    histories[name] = hist[-HISTORY_LIMIT:]
    reply(source, rname, msg_id, thread, answer)


def main():
    if not API_KEY:
        print("error: LLM_API_KEY is not set", file=sys.stderr)
        sys.exit(2)
    # Make sure the outbox daemon is running (the dispatcher usually owns it).
    try:
        subprocess.run(["pgrep", "-f", OUTBOX_BIN], check=True,
                       capture_output=True)
    except subprocess.CalledProcessError:
        env = dict(os.environ, TG_BRIDGE_DIR=DIR)
        subprocess.Popen([OUTBOX_BIN], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    watcher = [os.path.join(BIN, "tg-topic-watch.sh"), QUEUE]
    env = dict(os.environ, TG_BRIDGE_DIR=DIR)
    while True:
        proc = subprocess.run(watcher, capture_output=True, text=True, env=env)
        for line in proc.stdout.splitlines():
            handle_line(line)


if __name__ == "__main__":
    main()
