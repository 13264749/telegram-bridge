# Long conversations

Telegram chats never end, but LLM context windows do. Two knobs:

## Suggest, don't force

`bin/rotation_check.py` watches `health.json` (message count) and the
chat's age, and prints `[SYSTEM rotate-suggest]` when a threshold is
crossed (defaults: 400 inbound messages or 56 days, 14-day cooldown
between suggestions). Your agent decides what to do with that line —
the reference behavior: mention it to the user in chat, never act
unilaterally.

## Rotate = summarize and restart

When the user agrees (or on your own policy):

1. Ask the model to summarize the conversation into a compact brief.
2. Start a fresh agent loop with the brief as its system context.
3. Archive or discard the old queue offset — the watcher resumes from
   the new offset; nothing is lost or duplicated.

`examples/llm_agent.py` keeps a rolling window of the last N exchanges
(`HISTORY_LIMIT`, default 40) as the simple built-in version of this.
