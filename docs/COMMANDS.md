# Bot commands

Give users a `/` menu in the Telegram app. Commands arrive at your agent
as plain text lines — handling them is agent logic, zero bridge changes.

## Register the menu (once)

```bash
bin/tg set-commands --commands '[
  {"command":"start","description":"What this bot is"},
  {"command":"help","description":"What this bot can do"},
  {"command":"newtopic","description":"Open a new forum topic"}
]'
```

## Suggested handling

| Text | Behavior |
|---|---|
| `/start` | short intro: what the bot is, who may use it, how to open a topic |
| `/help` | capabilities list: chat, topics, threaded replies |
| `/newtopic <name>` | create the forum topic (`bin/tg create-topic`), start an agent loop for its queue (see `docs/TOPICS.md`), confirm to the user |

On API errors (usually: bot is not admin, or lacks the Manage Topics
right), tell the user what's missing instead of failing silently.

The `examples/llm_agent.py` agent implements `/start` and `/help`
out of the box.
