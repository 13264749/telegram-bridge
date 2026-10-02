# Topics בלי ערבוב הקשר — תכנון ומימוש

## הרעיון
מפצל (dispatcher) יחיד קורא את סטרים הטלגרם וממיין כל הודעה לתור־קובץ
לפי נושא. לכל נושא צ'אט Muse משלו עם watcher משלו — תמליל נפרד, אין
ערבוב הקשר, והודעה = סבב אחד בצ'אט של הנושא שלה.

## ארכיטקטורה
```
Telegram --getUpdates--> tg-dispatch.sh --topics/<q>.queue--> tg-topic-watch.sh
   (צרכן יחיד,            (flock, 0 מכסה)                    (tracked exec
    אף פעם לא יוצא                                        בצ'אט הנושא;
    על הודעה)                                              יוצא רק כשיש
                                                           שורות חדשות)
```
- `bin/tg-dispatch.sh` — מחליף את `tg-supervisor.sh`+`tg-inbox.sh`.
  מחזיק גם את דמון ה־outbox בחיים. יוצא (2) רק על שגיאה חמורה.
- `bin/tg-topic-watch.sh <queue>` — רץ כ־background exec בכל צ'אט נושא.
  תורים: `_main` (צ'אטים פרטיים + General של הקבוצה), `<thread_id>` לטופיק.
- `bin/tg-outbox.sh` — מבין `__TG_THREAD__<id|general>` (יעד = `forum_chat_id`).

## פורמטים
- תור: שורה מתויגת `[Telegram HH:MM @שם #<msg_id>] <body>`,
  להודעות General בקבוצה סיומת ` @general`.
- תשובה לטופיק:
  ```
  __TG_THREAD__5
  __TG_REPLY_TO__123
  <תשובה>
  __TG_SEND__
  ```
  (בלי `[Telegram→שם]` — היעד קבוע). ל־General: `__TG_THREAD__general`.

## הקמת קבוצת פורום (צד יוני)
1. קבוצת supergroup פרטית, להדליק Topics בהגדרות.
2. להוסיף את @MuseTryBot כ**אדמין** (אחרת הוא לא רואה הודעות בטופיקים).
3. לכתוב `/start` ב־General → ה־chat_id של הקבוצה יירשם ב־`unknown_senders.log`.
4. להגיד ל־Muse → הוא כותב `forum_chat_id` (אחרי אישור).
5. לכל טופיק שרוצים: להגיד ל־Muse → הוא פותח צ'אט, שולח הודעת הקמה,
   מפעיל watcher. התור צובר בינתיים — שום הודעה לא הולכת לאיבוד.

## פתיחת נושא — דרך הבוט
יוני אומר (בטלגרם או כאן): "פתח נושא <שם>" או `/newtopic <שם>`.
הסוכן בצ'אט הראשי:
1. `FORUM="$(cat ~/workspace/telegram_bridge/forum_chat_id)"`
2. `python3 ~/workspace/skills/telegram-bridge/bin/tg create-topic --chat-id "$FORUM" --name "<שם>"`
   → `result.message_thread_id` (שגיאה? לדווח: הבוט חייב אדמין עם ניהול נושאים).
3. `chat.create` → `"טלגרם — <שם>"`.
4. `chat.send_message` לצ'אט החדש עם הודעת ההקמה לנושא (למטה).
5. הסוכן בצ'אט החדש מפעיל `tg-topic-watch.sh <thread_id>` כ־background exec.
6. תשובה ליוני: "נפתח ✓".

## הודעת הקמה לצ'אט נושא
```
אתה סוכן נושא "<שם>" (טופיק <thread_id>) בקבוצת הפורום של יוני, דרך הבוט
@MuseTryBot. עברית, ישיר, בלי מילוי, מלוא היכולות.

מנגנון: tg-topic-watch.sh <thread_id> רץ כאן כ-background exec — מדפיס שורות
`[Telegram HH:MM @שם #<msg_id>]` מהתור ויוצא; היציאה מעירה אותך.

מחזור תשובה = background exec יחיד:
cat >> ~/workspace/telegram_bridge/outbox.txt <<'__TG_OUTBOX_EOF__'
__TG_THREAD__<thread_id>
__TG_REPLY_TO__<msg_id>
<התשובה בעברית>
__TG_SEND__
__TG_OUTBOX_EOF__
exec bash ~/workspace/telegram_bridge/bin/tg-topic-watch.sh <thread_id>

כללים: שורות `[SYSTEM ...]` פנימיות — לעולם לא לטלגרם ולא לתור.
הודעה שנכתבת כאן ישירות = שיחה רגילה, בלי תור.
טוקן הבוט לעולם לא מודפס. אין רישום תוכן הודעות ללוגים.
חוזה מכסה: הודעה = סבב־סוכן אחד. התשתית כולה סקריפטים (0 מכסה).

משימת הקמה (חד־פעמית): הפעל את ה־watcher כ־background exec, אשר כאן.
```

## חשבון מכסה
מפצל = 0 סבבים (רץ, לא מתעורר על הודעות). watcher בטל = 0.
הודעה = סבב־סוכן אחד בצ'אט הנושא. זהה לבוטים נפרדים.

## הערות מימוש
- `accounts.json` ללא שינוי: בצ'אט פרטי chat_id = user_id, בקבוצה `from.id`
  = אותם מספרים.
- הודעות קבוצה כשה־chat_id אינו `forum_chat_id` → `unknown_senders.log`.
- `health.json → inbox.messages_in` ממשיך להיספר ע"י המפצל (רוטציה).
- קבצי legacy: `tg-supervisor.sh`, `tg-inbox.sh` נשמרים ל־rollback.
