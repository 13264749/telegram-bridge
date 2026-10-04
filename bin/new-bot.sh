#!/usr/bin/env bash
# new-bot.sh — scaffold a new bot bridge instance (multi-bot support).
# Usage: new-bot.sh <bridge-dir-name> [destination-parent-dir]
# Example: new-bot.sh telegram_bridge_side
#
# Creates <parent>/<bridge-dir-name>/ as a full copy of this bridge
# (bin/, tests/, docs/, examples/), with its own token file, accounts.json
# and offset/outbox state. Each instance is fully independent: own
# getUpdates offset, own dispatcher, own outbox queue, own agent.
set -euo pipefail
NAME="${1:?usage: new-bot.sh <bridge-dir-name> [parent-dir]}"
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
echo '{}' > "$DST/accounts.json"
echo 0 > "$DST/offset.txt"
touch "$DST/outbox.txt" "$DST/unknown_senders.log"
cat <<EOF
Scaffolded $DST
  each instance has its own token, offset, queues, topics/ and agent.

Next steps:
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
