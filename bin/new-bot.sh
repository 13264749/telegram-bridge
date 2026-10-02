#!/usr/bin/env bash
# new-bot.sh — scaffold a new bot bridge instance (multi-bot support).
# Usage: new-bot.sh <bridge-dir-name> <credential-name>
# Example: new-bot.sh telegram_bridge_side custom.telegram-side
#
# Creates ~/workspace/<bridge-dir-name>/ as a full copy of this bridge
# (bin/, tests/, docs), with its own credential file, accounts.json,
# offset/outbox state. The tg CLI picks the bot's token via TG_CREDENTIAL
# (see bin/lib.sh), so each instance is fully independent: own getUpdates
# offset, own supervisor/dispatcher, own outbox queue, own Muse chat.
set -euo pipefail
NAME="${1:?usage: new-bot.sh <bridge-dir-name> <credential-name>}"
CRED="${2:?usage: new-bot.sh <bridge-dir-name> <credential-name>}"
case "$NAME" in
  ''|*[!A-Za-z0-9_]*)
    echo "bridge-dir-name must match [A-Za-z0-9_]+" >&2; exit 1 ;;
esac
SRC="$HOME/workspace/telegram_bridge"
DST="$HOME/workspace/$NAME"
[ -e "$DST" ] && { echo "exists: $DST" >&2; exit 1; }
mkdir -p "$DST"
cp -r "$SRC/bin" "$SRC/tests" "$DST/"
for f in PROTOCOL.md ROTATION.md COMMANDS_PLAN.md TOPICS.md MULTIBOT.md; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DST/"
done
# Point the copied docs at the new instance dir.
grep -rl "workspace/telegram_bridge" "$DST" 2>/dev/null \
  | xargs -r sed -i "s|workspace/telegram_bridge|workspace/$NAME|g"
printf '%s\n' "$CRED" > "$DST/credential"
chmod 600 "$DST/credential"
echo '{}' > "$DST/accounts.json"
echo 0 > "$DST/offset.txt"
touch "$DST/outbox.txt" "$DST/unknown_senders.log"
cat <<EOF
Scaffolded $DST
  vault credential: $CRED   (in $DST/credential)
  each instance has its own offset, queues, topics/ and Muse chat.

Next steps:
  1. Create the bot with @BotFather, then store its token in the
     '$CRED' connector (secure card).
  2. Fill $DST/accounts.json, e.g. {"<chat_id>": "<name>"}.
     (Unknown chat_ids are logged to unknown_senders.log on first contact.)
  3. Create a fresh Muse side chat for this bot (e.g. "טלגרם — צדדי").
  4. In that chat, start the dispatcher as a background exec:
       bash $DST/bin/tg-dispatch.sh
     and the main watcher as a background exec:
       bash $DST/bin/tg-topic-watch.sh _main
  5. Verify: TG_BRIDGE_DIR=$DST bash $DST/bin/tg-ctl.sh status
EOF
