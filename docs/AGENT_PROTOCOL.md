# Agent protocol

How to wire **your own agent** (an LLM loop, a bot framework, anything)
to the bridge. The bridge handles all Telegram I/O; your agent only talks
to two files.

## The contract

```
Telegram --getUpdates--> tg-dispatch.sh --> topics/<queue>.queue
                                              (your agent reads)
your agent --> outbox.txt --> tg-outbox.sh --> Telegram (sendMessage)

Discord --REST poll--> dc-dispatch.sh --> topics/<queue>.queue
your agent --> outbox.txt --> dc-outbox.sh --> Discord
```

One bridge instance = one transport (`new-bot.sh --source discord`
for Discord). The queue/outbox contract below is identical; only the
source tag differs (`Telegram` vs `Discord`).

- **In:** `topics/_main.queue` (private chats + forum General topic) or
  `topics/<thread_id>.queue` (a forum topic). One line per message.
- **Out:** append reply blocks to `outbox.txt`. `tg-outbox.sh` sends them
  (and deletes them on success).

## Incoming line format

```
[Telegram HH:MM @name#<message_id>] <message text>
```

- `@name` — the display name from `accounts.json` (`{"<chat_id>": "<name>"}`).
  Unknown senders are logged to `unknown_senders.log` and queued as
  `@unknown_<chat_id>` — decide your own policy for them.
- `#<message_id>` — Telegram's message id. Use it to thread replies.
- Forum **General** topic lines carry an extra suffix:
  `[Telegram HH:MM @name#<message_id> @general] <text>`
- Media without text arrives as a placeholder like `[photo]` / `[voice]`.
- Lines starting with `[SYSTEM ...]` are internal control lines —
  never forward them to Telegram.

**Reading the queue:** don't parse the file yourself. Run
`bin/tg-topic-watch.sh <queue>` — it prints new lines and exits 0
(flock-safe against the dispatcher's appends). Loop over it; each exit
means "new messages, handle them now". See `examples/echo_agent.sh`.

## Outgoing: outbox.txt format

Append one block per reply. Blocks are separated by a `__TG_SEND__` line;
everything between is the reply. Routing marker lines (all stripped before
sending, never delivered):

| Marker | Meaning |
|---|---|
| `[Telegram→name]` | reply to this account (name from `accounts.json`); omit for forum topics |
| `__TG_REPLY_TO__<message_id>` | thread the reply under that message |
| `__TG_THREAD__<thread_id>` | post into a forum topic (use `general` for the General topic) |
| `__TG_SEND__` | end of this reply block |

Example — private reply threaded under the question:

```
[Telegram→me]
__REPLY_TO__123
Hello from the other side.
__TG_SEND__
```

Example — reply inside forum topic 7:

```
__THREAD__7
__REPLY_TO__456
Noted, tracking it here.
__TG_SEND__
```

The outbox daemon (`bin/tg-outbox.sh`) picks up appended blocks within a
few seconds, sends them via `sendMessage` (long texts are auto-chunked at
4000 chars), and removes each block after a successful send. Failed blocks
are retried with backoff, then moved to `dead_letters.txt`.

## Bot commands

Register a command menu once with
`bin/tg set-commands --commands '[{"command":"start","description":"..."}]'`.
Commands arrive as plain text lines (`/start`, `/help`, `/newtopic <name>`);
handling them is your agent's job — see `docs/COMMANDS.md`.

## Rules of the road

- Never log or print the bot token. Keep it in `TG_TOKEN` / the `token`
  file (chmod 600, gitignored).
- `bridge.log` is metadata-only — don't write message content to logs.
- One incoming message = one agent turn. The plumbing is all scripts;
  keep it that way and the bridge stays cheap.
