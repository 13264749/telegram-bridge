# Multi-bot

Run several independent bots from one checkout. Each instance has its own
token, `getUpdates` offset, queues, outbox and agent — they never touch
each other's state.

## Scaffold a new instance

```bash
bin/new-bot.sh <instance-dir-name> [parent-dir]   # default parent: $HOME
```

This copies `bin/`, `tests/`, `docs/`, `examples/` to
`<parent>/<instance-dir-name>/` and creates:

- `token` — empty, chmod 600. Paste the new bot's token here
  (from [@BotFather](https://t.me/BotFather)).
- `accounts.json` — `{}`. Fill with `{"<chat_id>": "<name>"}`.
- `offset.txt`, `outbox.txt`, `unknown_senders.log` — fresh state.

Token selection: `TG_TOKEN` env wins; otherwise the `token` file in the
instance dir (`bin/lib.sh`). `TG_BIN` can point every script at a custom
`tg` CLI; default is the instance's own `bin/tg`.

## Run it

```bash
TG_BRIDGE_DIR=$HOME/my_side_bot bash $HOME/my_side_bot/bin/tg-dispatch.sh &
TG_BRIDGE_DIR=$HOME/my_side_bot python3 $HOME/my_side_bot/examples/llm_agent.py &
```

Check health: `TG_BRIDGE_DIR=$HOME/my_side_bot bash $HOME/my_side_bot/bin/tg-ctl.sh status`
Stop: `TG_BRIDGE_DIR=$HOME/my_side_bot bash $HOME/my_side_bot/bin/tg-ctl.sh stop`
