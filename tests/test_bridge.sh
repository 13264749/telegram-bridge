#!/usr/bin/env bash
# tests/test_bridge.sh — bridge test suite. Uses a fake tg CLI:
# no network, no real Telegram sends.
set -euo pipefail
# Portable paths: the suite runs from a checkout anywhere.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=/tmp/tgtest_bridge
rm -rf "$T"; mkdir -p "$T/bin" "$T/run"
export TG_BRIDGE_DIR="$T"
cp "$SRC/bin/"*.sh "$SRC/bin/"*.py "$T/bin/"

# ---- fake tg CLI ----
cat > "$T/bin/fake-tg" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[0] == "updates":
    mode = os.environ.get("FAKE_MODE", "messages")
    if mode == "fail":
        print(json.dumps({"ok": False, "description": "boom"}))
    elif mode == "empty":
        print(json.dumps({"ok": True, "result": []}))
    else:
        with open(os.environ["FAKE_UPDATES"], encoding="utf-8") as f:
            print(f.read())
elif args[0] == "send":
    cid = args[args.index("--chat-id") + 1]
    text = args[args.index("--text") + 1]
    rt = args[args.index("--reply-to") + 1] if "--reply-to" in args else "-"
    th = args[args.index("--thread-id") + 1] if "--thread-id" in args else "-"
    extra = f" thread={th}" if th != "-" else ""
    with open(os.environ["TG_BRIDGE_DIR"] + "/sends.log", "a", encoding="utf-8") as f:
        f.write(f"SEND chat_id={cid} reply_to={rt} text={text}{extra}\n")
    if "FAIL_ALWAYS" in text:
        print(json.dumps([{"ok": False, "description": "injected failure"}]))
    else:
        print(json.dumps([{"ok": True}]))
EOF
chmod +x "$T/bin/fake-tg"
export TG_BIN="$T/bin/fake-tg"

pass=0; fail=0
check() { # check <name> <condition-command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "PASS $name";
  else fail=$((fail+1)); echo "FAIL $name"; fi
}
check_grep() { # check_grep <name> <file> <pattern>
  local name="$1" file="$2" pat="$3"
  if grep -q "$pat" "$file" 2>/dev/null; then pass=$((pass+1)); echo "PASS $name";
  else fail=$((fail+1)); echo "FAIL $name"; fi
}

B="$SRC/bin"
printf '%s' '{"111": "ראשי", "222": "משני"}' > "$T/accounts.json"
echo 0 > "$T/offset.txt"

# ---- 1. inbox: tagging + media placeholders + unknown sender ----
cat > "$T/updates1.json" <<'EOF'
{"ok": true, "result": [
  {"update_id": 100, "message": {"message_id": 1001, "chat": {"id": 111}, "text": "היי", "date": 1758790000}},
  {"update_id": 101, "message": {"message_id": 1002, "chat": {"id": 222}, "photo": [{"file_id": "x"}], "caption": "תראה", "date": 1758790060}},
  {"update_id": 102, "message": {"message_id": 1003, "chat": {"id": 111}, "voice": {"duration": 7}, "date": 1758790120}},
  {"update_id": 103, "message": {"message_id": 1004, "chat": {"id": 111}, "sticker": {"emoji": "👍"}, "date": 1758790180}},
  {"update_id": 104, "message": {"message_id": 1005, "chat": {"id": 999}, "text": "זר", "date": 1758790240}}
]}
EOF
export FAKE_UPDATES="$T/updates1.json" FAKE_MODE=messages
OUT="$("$B/tg-inbox.sh")"
check "inbox exits 0 on messages" true
echo "$OUT" | grep -q '@ראשי#1001] היי' && echo "$OUT" | grep -q '@משני#1002] \[תמונה\] תראה' \
  && echo "$OUT" | grep -q '@ראשי#1003] \[הודעה קולית (7 שניות)\]' \
  && echo "$OUT" | grep -q '@ראשי#1004] \[סטיקר 👍\]' \
  && { pass=$((pass+1)); echo "PASS inbox tagging+media+msgid"; } \
  || { fail=$((fail+1)); echo "FAIL inbox tagging+media+msgid"; echo "$OUT"; }
check_grep "unknown sender logged" "$T/unknown_senders.log" "unknown chat_id=999"
check "offset advanced to 105" test "$(cat "$T/offset.txt")" = "105"
check "last_sender is 111" test "$(cat "$T/last_sender.txt")" = "111"
check_grep "health messages_in=4" "$T/health.json" '"messages_in": 4'
check_grep "bridge.log IN line" "$T/bridge.log" "IN 4 message(s)"

# ---- 2. inbox: empty cycle keeps looping silently ----
export FAKE_MODE=empty
set +e
timeout 4 bash "$B/tg-inbox.sh" >/tmp/tgtest_out2.txt 2>&1
rc=$?
set -e
check "empty cycle loops (timeout kills it)" test "$rc" = "124"
check "empty cycle prints nothing" test ! -s /tmp/tgtest_out2.txt

# ---- 3. outbox: tag routing + fallback ----
export OUTBOX_POLL_INTERVAL=1
rm -f "$T/sends.log"
printf '[Telegram→משני]\nתשובה למשני\n__TG_SEND__\nבלי תגית\n__TG_SEND__\n[Telegram→111]\nמספרי\n__TG_SEND__\n' > "$T/outbox.txt"
echo 222 > "$T/last_sender.txt"
set +e
timeout 5 bash "$B/tg-outbox.sh" >/dev/null 2>&1
set -e
check_grep "tag routes to 222" "$T/sends.log" "SEND chat_id=222 reply_to=- text=תשובה למשני"
check_grep "untagged falls back to last_sender" "$T/sends.log" "SEND chat_id=222 reply_to=- text=בלי תגית"
check_grep "numeric tag routes to 111" "$T/sends.log" "SEND chat_id=111 reply_to=- text=מספרי"
check_grep "tag stripped from body" "$T/sends.log" "text=תשובה למשני$"
check "queue drained" test ! -s "$T/outbox.txt"
check_grep "health sends=3" "$T/health.json" '"sends": 3'
check_grep "bridge.log OUT ok" "$T/bridge.log" "OUT @משני ok"

# ---- 3b. outbox: __TG_REPLY_TO__ threads the reply, marker stripped ----
rm -f "$T/sends.log"
printf '[Telegram→משני]\n__TG_REPLY_TO__456\nתשובה משורשרת\n__TG_SEND__\n[Telegram→111]\nבלי שרשור\n__TG_SEND__\n' > "$T/outbox.txt"
set +e
timeout 5 bash "$B/tg-outbox.sh" >/dev/null 2>&1
set -e
check_grep "reply_to passed to tg send" "$T/sends.log" "reply_to=456 text=תשובה משורשרת"
check_grep "reply marker stripped from body" "$T/sends.log" "text=תשובה משורשרת$"
check_grep "no reply_to defaults to -" "$T/sends.log" "reply_to=- text=בלי שרשור"
check "queue drained after reply_to" test ! -s "$T/outbox.txt"

# ---- 4. outbox: backoff then dead letters ----
rm -f "$T/sends.log" "$T/dead_letters.txt" "$T/outbox_state.json"
export OUTBOX_MAX_ATTEMPTS=3 OUTBOX_BACKOFFS="1,1,1"
printf 'FAIL_ALWAYS הודעה כושלת\n__TG_SEND__\n' > "$T/outbox.txt"
set +e
timeout 10 bash "$B/tg-outbox.sh" >/dev/null 2>&1
set -e
attempts=$(grep -c "FAIL_ALWAYS" "$T/sends.log" 2>/dev/null || echo 0)
check "exactly 3 attempts then stop" test "$attempts" = "3"
check_grep "dead letter recorded" "$T/dead_letters.txt" "FAIL_ALWAYS"
check "queue drained after dead-letter" test ! -s "$T/outbox.txt"
check_grep "health dead_letters=1" "$T/health.json" '"dead_letters": 1'
check_grep "bridge.log retry then dead" "$T/bridge.log" "FAILED after 3 attempts"
unset OUTBOX_MAX_ATTEMPTS OUTBOX_BACKOFFS

# ---- 5. outbox: crash recovery of interrupted batch ----
rm -f "$T/sends.log"
printf 'הודעה שנקטעה\n__TG_SEND__\n' > "$T/.outbox_processing"
set +e
timeout 4 bash "$B/tg-outbox.sh" >/dev/null 2>&1
set -e
check_grep "interrupted batch recovered and sent" "$T/sends.log" "הודעה שנקטעה"
check_grep "recovery logged" "$T/bridge.log" "recovered interrupted batch"
check "processing file cleaned" test ! -e "$T/.outbox_processing"

# ---- 6. supervisor: message wakes, prints, exits ----
cat > "$T/updates2.json" <<'EOF'
{"ok": true, "result": [
  {"update_id": 200, "message": {"chat": {"id": 111}, "text": "סופרוויזר", "date": 1758790300}}
]}
EOF
export FAKE_UPDATES="$T/updates2.json" FAKE_MODE=messages
set +e
SOUT="$(timeout 20 bash "$B/tg-supervisor.sh" 2>&1)"
src=$?
set -e
check "supervisor exits on message" test "$src" = "0"
echo "$SOUT" | grep -q '@ראשי] סופרוויזר' \
  && { pass=$((pass+1)); echo "PASS supervisor prints message"; } \
  || { fail=$((fail+1)); echo "FAIL supervisor prints message"; echo "$SOUT"; }
pkill -f "$T/bin/tg-outbox.sh" 2>/dev/null || true  # cleanup child from test 6
sleep 1

# ---- 7. supervisor: duplicate guard (second instance exits) ----
export FAKE_MODE=empty
bash "$B/tg-supervisor.sh" >/tmp/tgtest_sup.txt 2>&1 &
sup1=$!
sleep 2
set +e
timeout 5 bash "$B/tg-supervisor.sh" >/tmp/tgtest_sup2.txt 2>&1
rc2=$?
set -e
check "second supervisor exits immediately" test "$rc2" = "0"
check_grep "duplicate guard message" /tmp/tgtest_sup2.txt "another supervisor is already running"
kill $sup1 2>/dev/null || true
wait $sup1 2>/dev/null || true
pkill -f "$T/bin/tg-outbox.sh" 2>/dev/null || true
sleep 1

# ---- 8. tg-ctl.sh status ----
check "tg-ctl status runs" bash "$B/tg-ctl.sh" status

# ---- 9. supervisor: transient API failure stays quiet (no agent wake-up) ----
export FAKE_MODE=fail INBOX_MAX_FAILURES=2 INBOX_FAIL_STEP=1 SUPERVISOR_BACKOFFS="1,2"
rm -f "$T/bridge.log"
set +e
SOUT9="$(timeout 8 bash "$B/tg-supervisor.sh" 2>/dev/null)"
rc9=$?
set -e
check "transient failure: no output (nothing would wake the agent)" test -z "$SOUT9"
check_grep "transient failure logged with backoff" "$T/bridge.log" "transient inbox failure"
check_grep "no agent wake-up noted" "$T/bridge.log" "no agent wake-up"
pkill -f "$T/bin/tg-outbox.sh" 2>/dev/null || true
sleep 1
unset INBOX_MAX_FAILURES INBOX_FAIL_STEP SUPERVISOR_BACKOFFS

# ---- 10. supervisor: fatal config error wakes agent exactly once ----
printf 'not-json' > "$T/accounts.json"
set +e
SOUT10="$(timeout 10 bash "$B/tg-supervisor.sh" 2>/dev/null)"
rc10=$?
set -e
check "fatal error: supervisor exits 2" test "$rc10" = "2"
echo "$SOUT10" | grep -q "ERROR" \
  && { pass=$((pass+1)); echo "PASS fatal error output shown"; } \
  || { fail=$((fail+1)); echo "FAIL fatal error output shown"; echo "$SOUT10"; }
printf '%s' '{"111": "ראשי", "222": "משני"}' > "$T/accounts.json"
pkill -f "$T/bin/tg-outbox.sh" 2>/dev/null || true
sleep 1

# ---- 11. rotation_check.py: suggests at threshold, cooldown suppresses repeat ----
rm -f "$T/rotation.json"
set +e
ROUT1="$(TG_BRIDGE_DIR="$T" ROTATE_AFTER_MESSAGES=0 ROTATE_AFTER_DAYS=999999 python3 "$B/rotation_check.py" 2>/dev/null)"; rc11a=$?
set -e
check "rotation: suggests when threshold met" test -n "$ROUT1"
echo "$ROUT1" | grep -q "rotate-suggest" \
  && { pass=$((pass+1)); echo "PASS rotation: suggestion line format"; } \
  || { fail=$((fail+1)); echo "FAIL rotation: suggestion line format"; }
set +e
ROUT2="$(TG_BRIDGE_DIR="$T" ROTATE_AFTER_MESSAGES=0 ROTATE_AFTER_DAYS=999999 python3 "$B/rotation_check.py" 2>/dev/null)"; rc11b=$?
set -e
check "rotation: second run exits non-zero (no repeat)" test "$rc11b" != "0"
check "rotation: cooldown suppresses repeat suggestion" test -z "$ROUT2"

# ---- 12. rotation_check.py: quiet under thresholds ----
rm -f "$T/rotation.json"
set +e
ROUT3="$(TG_BRIDGE_DIR="$T" ROTATE_AFTER_MESSAGES=999999 ROTATE_AFTER_DAYS=999999 python3 "$B/rotation_check.py" 2>/dev/null)"; rc12=$?
set -e
check "rotation: quiet under thresholds" test -z "$ROUT3" -a "$rc12" != "0"

# ---- 13. supervisor appends [SYSTEM rotate-suggest] when criteria met ----
rm -f "$T/rotation.json"
export FAKE_MODE=message
export FAKE_TEXT="שלום"
export ROTATE_AFTER_MESSAGES=0 ROTATE_AFTER_DAYS=999999 ROTATE_SUGGEST_COOLDOWN_DAYS=0
set +e
SOUT13="$(timeout 10 bash "$B/tg-supervisor.sh" 2>/dev/null)"
set -e
echo "$SOUT13" | grep -q "rotate-suggest" \
  && { pass=$((pass+1)); echo "PASS supervisor appends rotate-suggest"; } \
  || { fail=$((fail+1)); echo "FAIL supervisor appends rotate-suggest"; echo "$SOUT13"; }
unset ROTATE_AFTER_MESSAGES ROTATE_AFTER_DAYS ROTATE_SUGGEST_COOLDOWN_DAYS
pkill -f "$T/bin/tg-outbox.sh" 2>/dev/null || true
sleep 1

# ---- 14. supervisor output has no [SYSTEM line under normal thresholds ----
rm -f "$T/rotation.json"
set +e
SOUT14="$(timeout 10 bash "$B/tg-supervisor.sh" 2>/dev/null)"
set -e
echo "$SOUT14" | grep -q "SYSTEM" \
  && { fail=$((fail+1)); echo "FAIL supervisor has no SYSTEM line normally"; echo "$SOUT14"; } \
  || { pass=$((pass+1)); echo "PASS supervisor has no SYSTEM line normally"; }
pkill -f "$T/bin/tg-outbox.sh" 2>/dev/null || true
sleep 1
unset FAKE_MODE FAKE_TEXT

# ---- 15. lib.sh: token selection (env wins, then token file) ----
echo "test-token-abc" > "$T/token"
TOK_OUT="$(TG_BRIDGE_DIR="$T" bash -c "source '$B/lib.sh'; printf '%s' \"\$TG_TOKEN\"")"
check "token file is exported" test "$TOK_OUT" = "test-token-abc"
rm -f "$T/token"
TOK_ENV="$(TG_BRIDGE_DIR="$T" TG_TOKEN="env-token-xyz" bash -c "source '$B/lib.sh'; printf '%s' \"\$TG_TOKEN\"")"
check "TG_TOKEN env wins over missing file" test "$TOK_ENV" = "env-token-xyz"
echo "file-token" > "$T/token"
TOK_PREC="$(TG_BRIDGE_DIR="$T" TG_TOKEN="env-token-xyz" bash -c "source '$B/lib.sh'; printf '%s' \"\$TG_TOKEN\"")"
check "TG_TOKEN env wins over token file" test "$TOK_PREC" = "env-token-xyz"
rm -f "$T/token"

# ---- 16. new-bot.sh scaffolds an independent instance ----
SB="test_bot_scaffold_xy"
rm -rf "$T/$SB"
bash "$B/new-bot.sh" "$SB" "$T" >/dev/null
check "scaffold creates bin" test -f "$T/$SB/bin/tg-dispatch.sh" -a -f "$T/$SB/bin/lib.sh" -a -f "$T/$SB/bin/tg"
check "scaffold writes empty token file" test -f "$T/$SB/token" -a ! -s "$T/$SB/token"
check "scaffold creates empty accounts.json" test "$(cat "$T/$SB/accounts.json")" = "{}"
check "scaffold copies tests" test -f "$T/$SB/tests/test_bridge.sh"
check "scaffold copies docs+examples" test -f "$T/$SB/docs/AGENT_PROTOCOL.md" -a -f "$T/$SB/examples/echo_agent.sh"
rm -rf "$T/$SB"

# ---- 17. tg-ctl.sh is per-instance ----
mkdir -p "$T/ia/bin" "$T/ib/bin"
printf '#!/usr/bin/env bash\nwhile true; do sleep 60; done\n' > "$T/ia/bin/tg-supervisor.sh"
chmod +x "$T/ia/bin/tg-supervisor.sh"
bash "$T/ia/bin/tg-supervisor.sh" &
IASUP=$!
sleep 1
TG_BRIDGE_DIR="$T/ia" bash "$B/tg-ctl.sh" status > /tmp/tgtest_ctl_a.txt 2>&1
TG_BRIDGE_DIR="$T/ib" bash "$B/tg-ctl.sh" status > /tmp/tgtest_ctl_b.txt 2>&1
grep -q "^supervisor *running" /tmp/tgtest_ctl_a.txt \
  && { pass=$((pass+1)); echo "PASS ctl sees own instance supervisor"; } \
  || { fail=$((fail+1)); echo "FAIL ctl sees own instance supervisor"; cat /tmp/tgtest_ctl_a.txt; }
grep -q "^supervisor *DOWN" /tmp/tgtest_ctl_b.txt \
  && { pass=$((pass+1)); echo "PASS ctl does not see other instance supervisor"; } \
  || { fail=$((fail+1)); echo "FAIL ctl does not see other instance supervisor"; cat /tmp/tgtest_ctl_b.txt; }
kill "$IASUP" 2>/dev/null || true
wait "$IASUP" 2>/dev/null || true

# ---- 18. dispatch: routes private / topic / general / unknown ----
cat > "$T/updates3.json" <<'EOF'
{"ok": true, "result": [
  {"update_id": 300, "message": {"message_id": 2001, "chat": {"id": 111, "type": "private"}, "from": {"id": 111}, "text": "היי פרטי", "date": 1758790000}},
  {"update_id": 301, "message": {"message_id": 2002, "chat": {"id": 777, "type": "supergroup"}, "from": {"id": 111}, "message_thread_id": 5, "text": "היי טופיק", "date": 1758790060}},
  {"update_id": 302, "message": {"message_id": 2003, "chat": {"id": 777, "type": "supergroup"}, "from": {"id": 222}, "text": "היי גנרל", "date": 1758790120}},
  {"update_id": 303, "message": {"message_id": 2004, "chat": {"id": 777, "type": "supergroup"}, "from": {"id": 999}, "message_thread_id": 5, "text": "זר בקבוצה", "date": 1758790180}},
  {"update_id": 304, "message": {"message_id": 2005, "chat": {"id": 555, "type": "supergroup"}, "from": {"id": 111}, "text": "קבוצה זרה", "date": 1758790240}}
]}
EOF
echo 777 > "$T/forum_chat_id"
rm -rf "$T/topics"
export FAKE_UPDATES="$T/updates3.json" FAKE_MODE=messages
set +e
TG_DISPATCH_ONESHOT=1 timeout 20 bash "$B/tg-dispatch.sh" >/dev/null 2>&1
rc18=$?
set -e
pkill -f "$T/bin/tg-outbox.sh" 2>/dev/null || true
sleep 1
check "dispatch oneshot exits 0" test "$rc18" = "0"
check_grep "private routed to _main" "$T/topics/_main.queue" '@ראשי#2001] היי פרטי'
check_grep "topic routed to thread queue" "$T/topics/5.queue" '@ראשי#2002] היי טופיק'
check_grep "general lands in _main with suffix" "$T/topics/_main.queue" '@משני#2003 @general] היי גנרל'
check_grep "unknown group sender logged" "$T/unknown_senders.log" "unknown group sender=999"
check_grep "unknown group chat logged" "$T/unknown_senders.log" "unknown group chat_id=555"
if grep -rq 'זר בקבוצה\|קבוצה זרה' "$T/topics/" 2>/dev/null; \
  then fail=$((fail+1)); echo "FAIL unknown group message not queued"; \
  else pass=$((pass+1)); echo "PASS unknown group message not queued"; fi
check_grep "dispatch counts messages_in" "$T/health.json" '"messages_in":'

# ---- 19. dispatch: no forum configured -> group messages ignored ----
rm -f "$T/forum_chat_id"
rm -rf "$T/topics"
cat > "$T/updates4.json" <<'EOF'
{"ok": true, "result": [
  {"update_id": 400, "message": {"message_id": 2006, "chat": {"id": 777, "type": "supergroup"}, "from": {"id": 111}, "message_thread_id": 5, "text": "טופיק בלי קונפיג", "date": 1758790300}}
]}
EOF
export FAKE_UPDATES="$T/updates4.json"
set +e
TG_DISPATCH_ONESHOT=1 timeout 20 bash "$B/tg-dispatch.sh" >/dev/null 2>&1
set -e
pkill -f "$T/bin/tg-outbox.sh" 2>/dev/null || true
sleep 1
check "unconfigured forum: no topic queue created" test ! -e "$T/topics/5.queue"
check_grep "unconfigured forum logged" "$T/unknown_senders.log" "unknown group chat_id=777"

# ---- 20. watcher: prints new lines, tracks offset ----
mkdir -p "$T/topics"
printf '[Telegram 10:00 @ראשי#1] שורה1\n[Telegram 10:01 @ראשי#2] שורה2\n[Telegram 10:02 @ראשי#3] שורה3\n' > "$T/topics/q1.queue"
rm -f "$T/topics/q1.offset"
set +e
WOUT="$(TOPIC_WATCH_POLL=1 timeout 10 bash "$B/tg-topic-watch.sh" q1 2>/dev/null)"; wrc=$?
set -e
check "watcher exits 0 on new lines" test "$wrc" = "0"
check "watcher prints all unread lines" test "$(printf '%s' "$WOUT" | grep -c 'שורה')" = "3"
check "watcher records offset" test "$(cat "$T/topics/q1.offset")" = "3"
set +e
TOPIC_WATCH_POLL=1 timeout 4 bash "$B/tg-topic-watch.sh" q1 >/dev/null 2>&1; wrc2=$?
set -e
check "watcher idles when caught up (timeout)" test "$wrc2" = "124"
printf '[Telegram 10:03 @ראשי#4] שורה4\n' >> "$T/topics/q1.queue"
set +e
WOUT2="$(TOPIC_WATCH_POLL=1 timeout 10 bash "$B/tg-topic-watch.sh" q1 2>/dev/null)"
set -e
check "watcher prints only the new line" test "$WOUT2" = "[Telegram 10:03 @ראשי#4] שורה4"

# ---- 21. outbox: __TG_THREAD__ routing ----
echo 777 > "$T/forum_chat_id"
rm -f "$T/sends.log" "$T/dead_letters.txt"
printf '__TG_THREAD__5\n__TG_REPLY_TO__123\nתשובה לטופיק\n__TG_SEND__\n__TG_THREAD__general\nהודעה לגנרל\n__TG_SEND__\n' > "$T/outbox.txt"
set +e
timeout 5 bash "$B/tg-outbox.sh" >/dev/null 2>&1
set -e
check_grep "thread routed to forum with thread id" "$T/sends.log" "chat_id=777.*text=תשובה לטופיק thread=5"
check_grep "thread markers stripped" "$T/sends.log" "text=הודעה לגנרל$"
GLINE="$(grep 'הודעה לגנרל' "$T/sends.log")"
check "general sent to forum without thread param" test -n "$GLINE" -a "$GLINE" = "${GLINE%thread=*}"
rm -f "$T/forum_chat_id" "$T/sends.log" "$T/dead_letters.txt"
printf '__TG_THREAD__5\nבלי קונפיג\n__TG_SEND__\n' > "$T/outbox.txt"
set +e
timeout 5 bash "$B/tg-outbox.sh" >/dev/null 2>&1
set -e
check_grep "thread without forum -> dead letter" "$T/dead_letters.txt" "no forum_chat_id"

# ---- 22. in-repo tg CLI: imports, subcommands, clean no-token error ----
# (regression: missing import os once broke every poll)
REPO_TG="$B/tg"
set +e
python3 -c "import runpy; runpy.run_path('$REPO_TG', run_name='__tg_test__')" >/dev/null 2>&1
rc22a=$?
set -e
check "tg CLI imports without NameError" test "$rc22a" = "0"
python3 "$REPO_TG" send --help 2>&1 | grep -q -- "--thread-id" \
  && { pass=$((pass+1)); echo "PASS tg send has --thread-id"; } \
  || { fail=$((fail+1)); echo "FAIL tg send has --thread-id"; }
python3 "$REPO_TG" send --help 2>&1 | grep -q -- "--reply-to" \
  && { pass=$((pass+1)); echo "PASS tg send has --reply-to"; } \
  || { fail=$((fail+1)); echo "FAIL tg send has --reply-to"; }
python3 "$REPO_TG" create-topic --help 2>&1 | grep -q -- "--name" \
  && { pass=$((pass+1)); echo "PASS tg create-topic args"; } \
  || { fail=$((fail+1)); echo "FAIL tg create-topic args"; }
python3 "$REPO_TG" set-commands --help 2>&1 | grep -q -- "--commands" \
  && { pass=$((pass+1)); echo "PASS tg set-commands args"; } \
  || { fail=$((fail+1)); echo "FAIL tg set-commands args"; }
# no token anywhere -> exit 2 with a clean message (no traceback)
set +e
TG_TOKEN= TG_BRIDGE_DIR="$T/empty_nodir_xyz" python3 "$REPO_TG" getme >"$T/notok.out" 2>"$T/notok.err"
rc22b=$?
set -e
check "tg without token exits 2" test "$rc22b" = "2"
grep -q "no bot token" "$T/notok.err" \
  && { pass=$((pass+1)); echo "PASS tg no-token message"; } \
  || { fail=$((fail+1)); echo "FAIL tg no-token message"; }
! grep -qi "traceback" "$T/notok.err" \
  && { pass=$((pass+1)); echo "PASS tg no-token no traceback"; } \
  || { fail=$((fail+1)); echo "FAIL tg no-token no traceback"; }

# ---- 23. dc CLI: imports, subcommands, clean no-token error ----
DC_CLI="$B/discord/dc"
set +e
python3 -c "import runpy; runpy.run_path('$DC_CLI', run_name='__dc_test__')" >/dev/null 2>&1
rc23a=$?
set -e
check "dc CLI imports cleanly" test "$rc23a" = "0"
python3 "$DC_CLI" send --help 2>&1 | grep -q -- "--channel" \
  && { pass=$((pass+1)); echo "PASS dc send has --channel"; } \
  || { fail=$((fail+1)); echo "FAIL dc send has --channel"; }
python3 "$DC_CLI" create-thread --help 2>&1 | grep -q -- "--name" \
  && { pass=$((pass+1)); echo "PASS dc create-thread has --name"; } \
  || { fail=$((fail+1)); echo "FAIL dc create-thread has --name"; }
set +e
DISCORD_TOKEN= TG_BRIDGE_DIR="$T/empty_nodir_xyz" python3 "$DC_CLI" getme >"$T/dcnotok.out" 2>"$T/dcnotok.err"
rc23b=$?
set -e
check "dc without token exits 2" test "$rc23b" = "2"
grep -q "no Discord bot token" "$T/dcnotok.err" \
  && { pass=$((pass+1)); echo "PASS dc no-token message"; } \
  || { fail=$((fail+1)); echo "FAIL dc no-token message"; }

# ---- 24. dc-dispatch: poll -> queue lines (oneshot, fake dc) ----
cat > "$T/bin/fake-dc" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[0] == "getme":
    print(json.dumps({"id": "999", "username": "testbot"}))
elif args[0] == "dm-channels":
    print(json.dumps([]))
elif args[0] == "list-threads":
    print(json.dumps({"threads": []}))
elif args[0] == "messages":
    after = args[args.index("--after") + 1] if "--after" in args else None
    msgs = [
        {"id": "m3", "channel_id": "C1", "author": {"id": "111"},
         "content": "third", "attachments": []},
        {"id": "m2", "channel_id": "C1", "author": {"id": "222"},
         "content": "second", "attachments": []},
        {"id": "m1", "channel_id": "C1", "author": {"id": "999", "bot": True},
         "content": "own, skip me", "attachments": []},
    ]
    if after:
        msgs = [m for m in msgs if int(m["id"][1:]) > int(after[1:])]
    print(json.dumps(msgs))
elif args[0] == "send":
    ch = args[args.index("--channel") + 1]
    text = args[args.index("--text") + 1]
    rt = args[args.index("--reply-to") + 1] if "--reply-to" in args else "-"
    with open(os.environ["TG_BRIDGE_DIR"] + "/dc_sends.log", "a", encoding="utf-8") as f:
        f.write("SEND channel=%s reply_to=%s text=%s\n" % (ch, rt, text))
    print(json.dumps([{"id": "sent1", "channel_id": ch}]))
elif args[0] == "open-dm":
    uid = args[args.index("--user-id") + 1]
    print(json.dumps({"id": "DM" + uid, "type": 1}))
else:
    print(json.dumps({"ok": False, "description": "fake-dc: unknown " + args[0]}))
EOF
chmod +x "$T/bin/fake-dc"
printf '{"channels": ["C1"], "queues": {"C1": "_main"}, "discover_dms": false, "auto_threads": false, "poll_interval": 1}' > "$T/discord.json"
printf '{"111": "me"}' > "$T/discord_accounts.json"
rm -f "$T/discord_cursors.json" "$T/unknown_senders.log" "$T/topics/_main.queue" "$T/discord_last_sender.txt"
set +e
DC_DISPATCH_ONESHOT=1 DC_BIN="$T/bin/fake-dc" TG_BRIDGE_DIR="$T" timeout 30 bash "$B/discord/dc-dispatch.sh" >/dev/null 2>&1
rc24=$?
set -e
pkill -f "$T/bin/discord/dc-outbox.sh" 2>/dev/null || true
check "dc-dispatch oneshot exits 0" test "$rc24" = "0"
check_grep "dc queue line format" "$T/topics/_main.queue" "@me#m3] third"
check_grep "dc unknown sender tagged" "$T/topics/_main.queue" "@unknown_222#m2] second"
check_grep "dc unknown logged" "$T/unknown_senders.log" "discord:222"
check "dc own message skipped" test "$(grep -c . "$T/topics/_main.queue")" = "2"
check "dc cursor saved" test "$(python3 -c "import json; print(json.load(open('$T/discord_cursors.json'))['C1'])")" = "m3"
check "dc last sender" test "$(cat "$T/discord_last_sender.txt")" = "111"
set +e
DC_DISPATCH_ONESHOT=1 DC_BIN="$T/bin/fake-dc" TG_BRIDGE_DIR="$T" timeout 30 bash "$B/discord/dc-dispatch.sh" >/dev/null 2>&1
set -e
pkill -f "$T/bin/discord/dc-outbox.sh" 2>/dev/null || true
check "dc no duplicates on re-poll" test "$(grep -c . "$T/topics/_main.queue")" = "2"

# ---- 25. dc-outbox: [Discord→name] routing, reply/thread markers ----
rm -f "$T/dc_sends.log" "$T/dead_letters.txt" "$T/outbox_state.json"
printf '[Discord→me]\n__REPLY_TO__m3\nhello discord\n__TG_SEND__\n__THREAD__C9\nthread msg\n__TG_SEND__\n' > "$T/outbox.txt"
set +e
DC_BIN="$T/bin/fake-dc" TG_BRIDGE_DIR="$T" timeout 8 bash "$B/discord/dc-outbox.sh" >/dev/null 2>&1
set -e
pkill -f "$T/bin/discord/dc-outbox.sh" 2>/dev/null || true
sleep 1
check_grep "dc outbox DM send" "$T/dc_sends.log" "SEND channel=DM111 reply_to=m3 text=hello discord"
check_grep "dc outbox thread send" "$T/dc_sends.log" "SEND channel=C9 reply_to=- text=thread msg"
check "dc outbox drained" test ! -s "$T/outbox.txt"

# ---- 26. tg-outbox accepts neutral __REPLY_TO__ / __THREAD__ markers ----
rm -f "$T/sends.log"
printf '12345\n' > "$T/forum_chat_id"
printf '[Telegram→משני]\n__REPLY_TO__789\n__THREAD__5\nניטרלי\n__TG_SEND__\n' > "$T/outbox.txt"
set +e
timeout 5 bash "$B/tg-outbox.sh" >/dev/null 2>&1
set -e
pkill -f "$T/bin/tg-outbox.sh" 2>/dev/null || true
check_grep "neutral reply marker routed" "$T/sends.log" "reply_to=789"
check_grep "neutral thread marker routed" "$T/sends.log" "thread=5"
rm -f "$T/forum_chat_id"

# ---- 27. wait_for_change prefers inotifywait when available ----
mkdir -p "$T/fakebin"
cat > "$T/fakebin/inotifywait" <<'EOF'
#!/usr/bin/env bash
echo "called $*" >> "${INOTIFY_CALLS:?}/calls.log"
sleep 0.2
exit 0
EOF
chmod +x "$T/fakebin/inotifywait"
export INOTIFY_CALLS="$T"
rm -f "$T/calls.log"
printf '[Telegram 10:00 @x#1] a\n' > "$T/topics/qz.queue"
printf '1\n' > "$T/topics/qz.offset"
set +e
PATH="$T/fakebin:$PATH" TOPIC_WATCH_POLL=30 timeout 3 bash "$B/tg-topic-watch.sh" qz >/dev/null 2>&1
set -e
check "watcher uses inotifywait when present" test -s "$T/calls.log"

# ---- 28. watcher wakes promptly on append (inotify path) ----
rm -f "$T/calls.log"
: > "$T/topics/qw.queue"
rm -f "$T/topics/qw.offset"
( sleep 0.5; printf '[Telegram 10:00 @x#9] ping\n' >> "$T/topics/qw.queue" ) &
set +e
START=$(date +%s)
WOUT3="$(PATH="$T/fakebin:$PATH" TOPIC_WATCH_POLL=30 timeout 15 bash "$B/tg-topic-watch.sh" qw 2>/dev/null)"
wrc3=$?
END=$(date +%s)
set -e
wait 2>/dev/null || true
check "watcher exits 0 on inotify wake" test "$wrc3" = "0"
check "watcher prints appended line" test "$WOUT3" = "[Telegram 10:00 @x#9] ping"
check "watcher woke fast (no 30s poll)" test "$((END - START))" -lt 10

echo "----"
echo "passed: $pass failed: $fail"
[ "$fail" = "0" ]
