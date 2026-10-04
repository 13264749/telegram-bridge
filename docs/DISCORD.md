# Discord transport

Run the bridge on Discord instead of (or next to) Telegram. One bridge
instance = one transport; scaffold a Discord instance with:

```bash
bin/new-bot.sh --source discord discord_bridge
```

## 1. Create the app

1. https://discord.com/developers/applications → New Application.
2. Bot → Add Bot, copy the token → paste into `<instance>/token`
   (chmod 600, never committed). Or export `DISCORD_TOKEN`.
3. If message text arrives empty, enable the **Message Content**
   privileged intent under Bot settings.
4. Invite the bot: OAuth2 → URL Generator → scopes `bot`, permissions
   `Send Messages`, `Read Message History`, `Create Public Threads`
   (for `/newtopic`), then open the URL.

Verify: `TG_BRIDGE_DIR=<instance> bin/discord/dc getme`

## 2. Configure

`discord.json` in the instance dir:

```json
{
  "channels": ["112233445566778899"],
  "queues": {"112233445566778899": "_main"},
  "discover_dms": true,
  "auto_threads": true,
  "poll_interval": 5
}
```

- `channels` — text channel ids to watch (right-click a channel → Copy ID;
  enable Developer Mode first).
- `queues` — channel id → queue name (default `_main`).
- `discover_dms` — auto-watch DM channels (they land in `_main`).
- `auto_threads` — auto-watch active threads (each gets queue
  `thread_<thread_id>`).

`discord_accounts.json`: `{"<discord_user_id>": "<name>"}` — who may talk
to the bot. Unknown users are queued as `@unknown_<id>` and logged to
`unknown_senders.log`. (Right-click a user → Copy User ID.)

## 3. Run

```bash
# terminal 1 — the dispatcher (Discord → queues)
TG_BRIDGE_DIR=$PWD bin/discord/dc-dispatch.sh

# terminal 2 — an agent (queues → Discord)
BRIDGE_SOURCE=discord TG_BRIDGE_DIR=$PWD bash examples/echo_agent.sh
# or: BRIDGE_SOURCE=discord LLM_API_KEY=sk-... TG_BRIDGE_DIR=$PWD python3 examples/llm_agent.py
```

DM the bot on Discord — it answers. Queue lines look like
`[Discord 14:32 @me#123456789] hello`; replies use `[Discord→me]`,
`__REPLY_TO__<id>`, `__THREAD__<channel_or_thread_id>` — see
`docs/AGENT_PROTOCOL.md`.

## Notes

- Polling is REST-based (`GET /channels/{id}/messages?after=`); no
  gateway, no privileged intents required except Message Content (see above).
  Rate limits are honored (`retry_after`).
- Threads **are** channels in Discord: `__THREAD__<id>` sends into one, and
  `dc create-thread --channel <id> --name <name>` opens one
  (`/newtopic <name>` in the example agents does this for you).
- Discord caps messages at 2000 chars — `dc send` chunks automatically.
- Slash commands are intentionally not used: with REST polling,
  interactions aren't visible, so the bot uses plain-text commands
  (`/start`, `/help`, `/newtopic` — see `docs/COMMANDS.md`).
- Sending a DM needs the DM channel: the outbox resolves user → channel
  via `POST /users/@me/channels` and caches it in
  `discord_dm_channels.json`.
