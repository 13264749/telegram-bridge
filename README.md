# telegram-bridge

DIY Telegram bridge: chat with an AI agent from Telegram. One Telegram
message = exactly one agent turn — the same cost as a normal chat message.
Everything between you and the agent is plain scripts; no AI in the loop.

## How it works

```
Telegram --getUpdates--> tg-dispatch.sh --topics/<queue>.queue--> tg-topic-watch.sh
   (single consumer,      (flock-guarded, 0 quota)                (tracked exec in
    never exits on                                        the topic's chat; exits
    messages)                                            only on new lines)
```

- **`bin/tg-dispatch.sh`** — the single `getUpdates` long-poller. Routes every
  message from an authorized account into a per-topic queue file
  (`topics/_main.queue` for private chats + the forum's General topic,
  `topics/<thread_id>.queue` for forum topics). Never exits on messages —
  only on fatal/config errors. Also keeps the outbox daemon alive.
- **`bin/tg-topic-watch.sh <queue>`** — runs as a tracked background process
  in each topic's chat. Polls the queue file every few seconds; prints new
  lines and exits, waking only that chat's agent. Zero quota while idle.
  One chat per topic = no context mixing.
- **`bin/tg-outbox.sh`** — sends queued replies. Queue entries are separated
  by `__TG_SEND__` lines and may carry routing markers (all stripped before
  sending):
  - `[Telegram→name]` — route to an account from `accounts.json`
  - `__TG_REPLY_TO__<message_id>` — thread the reply under a message
  - `__TG_THREAD__<thread_id|general>` — post into a forum topic
- **`bin/tg-ctl.sh`** — `status` / `stop` (per-instance aware).
- **`bin/new-bot.sh`** — scaffold an independent bridge instance for an
  additional bot (own token, offset, queues, chat).
- **`bin/rotation_check.py`** — suggests a chat rotation when the transcript
  grows past a threshold (message count or age).

## Requirements

- A Telegram bot token (via [@BotFather](https://t.me/BotFather)).
- A `tg` CLI speaking the Telegram Bot API with subcommands
  `getme` / `updates` / `send` / `create-topic` / `set-commands`
  (override path with `TG_BIN`). The reference setup keeps the token in a
  vault and selects it per instance via `TG_CREDENTIAL` / a `credential` file.
- `accounts.json`: `{"<chat_id>": "<name>", ...}` (see `accounts.json.example`).

## Forum topics (optional)

1. Create a private supergroup, enable Topics, add the bot as admin with
   topic-management rights (bots cannot flip the Topics switch themselves).
2. Write `/start` in General, note the group chat id from
   `unknown_senders.log`, save it to `forum_chat_id`.
3. Say "open topic <name>" (or `/newtopic <name>`) — the agent creates the
   forum topic, a chat for it, and starts its watcher.

## Tests

```bash
bash tests/test_bridge.sh   # no network; uses a fake tg CLI
```

## Docs

- `PROTOCOL.md` — the conversation agent's runbook
- `TOPICS.md` — forum topics design
- `MULTIBOT.md` — running several bots
- `ROTATION.md` — chat rotation policy
- `COMMANDS_PLAN.md` — bot command menu plan

## License

MIT — see [LICENSE](LICENSE).
