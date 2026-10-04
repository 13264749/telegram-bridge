# Forum topics

Give each conversation its own Telegram **forum topic** and its own agent
context — no mixing between threads.

## How it works

`tg-dispatch.sh` is the single `getUpdates` consumer. It sorts every
message by `message_thread_id`:

- private chats and the forum's **General** topic → `topics/_main.queue`
- each forum topic `<thread_id>` → `topics/<thread_id>.queue`

Run one agent (one `tg-topic-watch.sh <queue>` loop) per queue you care
about. Replies carry `__TG_THREAD__<thread_id>` (or `__TG_THREAD__general`)
so they land back in the right topic — see `docs/AGENT_PROTOCOL.md`.

## One-time setup (Telegram app — bots can't do this part)

1. Create a private supergroup and **enable Topics** in its settings
   (there is no Bot API for this switch).
2. Add your bot as admin with the **Manage Topics** permission.
3. Write `/start` in the General topic, then read `unknown_senders.log`
   for the group's chat id and save it to a `forum_chat_id` file.

## Opening a topic

Via the API (needs Manage Topics admin right):

```bash
bin/tg create-topic --chat-id "$(cat forum_chat_id)" --name "Shopping"
# → {"ok":true,"result":{"message_thread_id":7,...}}
```

Then start an agent loop for queue `7`:

```bash
TG_BRIDGE_DIR=$PWD TOPIC_QUEUE=7 bash examples/echo_agent.sh
```

or wire your own agent per `docs/AGENT_PROTOCOL.md`.

## Commands

`/newtopic <name>` (see `docs/COMMANDS.md`) automates the whole flow:
create the topic, start its agent loop, confirm to the user.
