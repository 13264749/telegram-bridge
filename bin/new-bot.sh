#!/usr/bin/env bash
# new-bot.sh — scaffold a new bot bridge instance (multi-bot / multi-source).
# Usage: new-bot.sh [--source telegram|discord] <bridge-dir-name> [parent-dir]
# Example: new-bot.sh discord_bridge --source discord
#
# Creates <parent>/<bridge-dir-name>/ as a full copy of this bridge
# (bin/, tests/, docs/, examples/), with its own token file, accounts,
# and offset/outbox state. Each instance is fully independent: own
# transport, own dispatcher, own outbox queue, own agent.
set -euo pipefail
SOURCE="telegram"
if [ "${1:-}" = "--source" ]; then
  SOURCE="${2:?--source needs telegram|discord}"
  shift 2
fi
case "$SOURCE" in telegram|discord) ;; *)
  echo "--source must be telegram or discord" >&2; exit 1 ;; esac
NAME="${1:?usage: new-bot.sh [--source telegram|discord] <bridge-dir-name> [parent-dir]}"
PARENT="${2:-$HOME}"
case "$NAME" in
  ''|*[!A-Za-z0-9_]*)
    echo "bridge-dir-name must match [A-Za-z0-9_]+" >&2; exit 1 ;;
esac
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="$PARENT/$NAME"
[ -e "$DST" ] && { echo "exists: $DST" >&2; exit 1; }
mkdir -p "$DST"
cp -r "$SRC/bin" "$SRC/tests" "$DST/"
cp -r "$SRC/docs" "$SRC/examples" "$DST/"
: > "$DST/token"
chmod 600 "$DST/token"
if [ "$SOURCE" = "discord" ]; then
  echo '{}' > "$DST/discord_accounts.json"
  cat > "$DST/discord.json" <<'JSONEOF'
{
  "channels": [],
  "queues": {},
  "discover_dms": true,
  "auto_threads": true,
  "poll_interval": 5
}
JSONEOF
else
  echo '{}' > "$DST/accounts.json"
fi
echo 0 > "$DST/offset.txt"
touch "$DST/outbox.txt" "$DST/unknown_senders.log"
cat <<EOF
Scaffolded $DST
  each instance has its own token, offset, queues, topics/ and agent.

Next steps (SOURCE=$SOURCE):
EOF
if [ "$SOURCE" = "discord" ]; then
cat <<EOF
  1. Create the app/bot in the Discord Developer Portal and write its token
     into $DST/token (chmod 600, never commit it). See docs/DISCORD.md.
  2. Fill $DST/discord_accounts.json, e.g. {"123456789": "me"}, and list
     channel ids to watch in $DST/discord.json.
     (Unknown user_ids are logged to unknown_senders.log on first contact.)
  3. Start the dispatcher (terminal 1):
       TG_BRIDGE_DIR=$DST bash $DST/bin/discord/dc-dispatch.sh
  4. Start your agent (terminal 2), e.g.:
       TG_BRIDGE_DIR=$DST python3 $DST/examples/llm_agent.py
  5. Verify: TG_BRIDGE_DIR=$DST bash $DST/bin/tg-ctl.sh status
EOF
else
cat <<EOF
  1. Create the bot with @BotFather and write its token into $DST/token
     (chmod 600, never commit it).
  2. Fill $DST/accounts.json, e.g. {"123456789": "me"}.
     (Unknown chat_ids are logged to unknown_senders.log on first contact.)
  3. Start the dispatcher (terminal 1):
       TG_BRIDGE_DIR=$DST bash $DST/bin/tg-dispatch.sh
  4. Start your agent (terminal 2), e.g.:
       TG_BRIDGE_DIR=$DST python3 $DST/examples/llm_agent.py
  5. Verify: TG_BRIDGE_DIR=$DST bash $DST/bin/tg-ctl.sh status
EOF
fi
