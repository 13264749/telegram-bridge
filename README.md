# telegram-bridge

Chat with your AI agent from Telegram. One Telegram message wakes the
agent exactly once — no polling loops burning tokens, no webhooks, no
server. Everything between Telegram and your agent is plain scripts.

## How it works

```
Telegram --getUpdates--> tg-dispatch.sh --> topics/<queue>.queue --> your agent
your agent --> outbox.txt --> tg-outbox.sh --> Telegram
```

- **`bin/tg-dispatch.sh`** — the single `getUpdates` long-poller. Routes
  every message into a per-topic queue file. Never exits on messages;
  transient API errors are swallowed with backoff.
- **`bin/tg-topic-watch.sh <queue>`** — prints new queue lines and exits.
  Your agent loops over it: each exit means "new messages, handle them".
  Zero cost while idle.
- **`bin/tg-outbox.sh`** — sends queued replies, retries with backoff,
  dead-letters after final failure.
- **`bin/tg`** — standalone Telegram Bot API CLI (`getme`, `updates`,
  `send`, `create-topic`, `set-commands`). Token from `TG_TOKEN` env or
  the `token` file (chmod 600, never committed).
- **`bin/new-bot.sh`** — scaffold an independent instance for another bot.

## Quickstart (5 minutes)

```bash
# 1. Create a bot with @BotFather on Telegram, copy its token.
git clone https://github.com/13264749/telegram-bridge.git
cd telegram-bridge

# 2. Token + who may talk to the bot (your Telegram numeric chat id;
#    find it via @userinfobot).
echo '<bot-token>' > token && chmod 600 token
cp accounts.json.example accounts.json   # then edit the ids
bin/tg getme                              # verify the token

# 3. Terminal 1 — the dispatcher (Telegram → queues):
TG_BRIDGE_DIR=$PWD bin/tg-dispatch.sh

# 4. Terminal 2 — an agent (queues → Telegram).
#    Echo example (no API key needed):
TG_BRIDGE_DIR=$PWD bash examples/echo_agent.sh
#    Or the LLM example (needs LLM_API_KEY):
LLM_API_KEY=sk-... TG_BRIDGE_DIR=$PWD python3 examples/llm_agent.py
```

Message your bot on Telegram — it answers.

## Wiring your own agent

Your agent only needs to speak two files — see
[`docs/AGENT_PROTOCOL.md`](docs/AGENT_PROTOCOL.md):

- **In:** lines like `[Telegram 14:32 @me#123] hello` from
  `topics/_main.queue` (via `bin/tg-topic-watch.sh`).
- **Out:** append reply blocks to `outbox.txt`, e.g.
  ```
  [Telegram→me]
  __TG_REPLY_TO__123
  Hello!
  __TG_SEND__
  ```

## Features

- **Forum topics** — each topic gets its own queue and agent context, no
  mixing. The bot can open topics itself (`/newtopic <name>`).
  See [`docs/TOPICS.md`](docs/TOPICS.md).
- **Multi-bot** — independent instances per bot, one checkout.
  See [`docs/MULTIBOT.md`](docs/MULTIBOT.md).
- **Bot commands** — `/start`, `/help`, `/newtopic` menu.
  See [`docs/COMMANDS.md`](docs/COMMANDS.md).
- **Long conversations** — rotation suggestions when context grows.
  See [`docs/ROTATION.md`](docs/ROTATION.md).

## Tests

```bash
bash tests/test_bridge.sh   # no network; uses a fake tg CLI
```

## License

MIT — see [LICENSE](LICENSE).
