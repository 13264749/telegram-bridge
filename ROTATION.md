# רוטציית צ'אט שיחות — גשר טלגרם

## למה
תמליל צ'אט השיחות ("טלגרם") גדל עם כל הודעה, ולכן הקונטקסט הנטען לכל הודעה —
ועלותה — גדל עם הזמן. רוטציה תקופתית מחזירה את העלות לקבועה.

## קריטריונים — תהליך אוטומטי שמציע (לא מבצע)
`bin/rotation_check.py` רץ בתוך הסופרוויזר בכל התעוררות על הודעה
(צד־סקריפט, 0 מכסה, לפני ההדפסה שמעירה את הסוכן).
כשאחד הספים נחצה, הוא מדפיס שורת `[SYSTEM rotate-suggest]` בודדת לתוך פלט
ההתעוררות; הסוכן, אחרי התשובה לטלגרם, מציע ליוני רוטציה **בצ'אט** (משפט קצר,
לעולם לא דרך טלגרם). הביצוע — רק אחרי אישור יוני.

- `ROTATE_AFTER_MESSAGES` (ברירת מחדל: **400**) — הודעות נכנסות מאז רוטציה
  אחרונה. מקור: `health.json` ← `inbox.messages_in` (נמדד אוטומטית לכל הודעה).
- `ROTATE_AFTER_DAYS` (ברירת מחדל: **56**, כ־8 שבועות) — ימים מאז רוטציה אחרונה.
- `ROTATE_SUGGEST_COOLDOWN_DAYS` (ברירת מחדל: **14**) — מרווח מינימלי בין
  הצעות, כדי לא לנדנד כל הודעה אחרי שהסף נחצה.
- מצב: `rotation.json` — נוצר אוטומטית בהרצה ראשונה
  (`started_at`, `messages_at_start`, `suggested_at`).

## הליך רוטציה (מבוצע רק אחרי אישור יוני)
1. צ'אט שיחות חדש: `chat.create(context_mode="fresh", name="טלגרם")`.
2. הצ'אט הישן: `chat.rename` → `"טלגרם — ארכיון YYYY-MM-DD"`, ואז `chat.archive`.
3. איפוס `rotation.json`: `started_at` = היום, `messages_at_start` = messages_in
   הנוכחי מ־`health.json`, `suggested_at` = null.
4. `chat.send_message` לצ'אט החדש עם הודעת ההקמה הרזה (למטה).
5. הסוכן בצ'אט החדש: מוודא שהסופרוויזר הישן למטה (`tg-ctl.sh status`;
   אם running — `tg-ctl.sh stop supervisor` + המתנה 3 שניות), מפעיל סופרוויזר
   חדש כ־background exec, מוודא אחרי ~50 שניות שהכל running ו־last_poll עדכני,
   מאשר בצ'אט.

## הודעת הקמה רזה (מחליפה את בלוק ההוראות הארוך)
```
אתה סוכן השיחות של טלגרם ("טלגרם"): מראה נקי לשיחות יוני עם Muse דרך הבוט
@MuseTryBot. עברית, ישיר, בלי מילוי, מלוא היכולות.

מנגנון: tg-dispatch.sh רץ כאן כ-background exec — צרכן ה־getUpdates היחיד,
ממיין הודעות לתורים ב־topics/ (_main = פרטי + General, <thread_id> = טופיק).
הוא אף פעם לא יוצא על הודעה — לא לגעת בו.
tg-topic-watch.sh _main רץ כאן כ-background exec: מדפיס שורות חדשות
`[Telegram HH:MM @שם #<msg_id>]` (מדיה = placeholder, `@general` = General
בקבוצה) ויוצא — היציאה מעירה אותך. מיפוי חשבון←שם: accounts.json.

מחזור תשובה = background exec יחיד:
cat >> ~/workspace/telegram_bridge/outbox.txt <<'__TG_OUTBOX_EOF__'
[Telegram→שם]
__TG_REPLY_TO__<msg_id>
<התשובה בעברית>
__TG_SEND__
__TG_OUTBOX_EOF__
exec bash ~/workspace/telegram_bridge/bin/tg-topic-watch.sh _main
(להודעת @general הוסף שורת __TG_THREAD__general אחרי הניתוב.)

כללים: שורות `[SYSTEM ...]` פנימיות — לעולם לא לטלגרם ולא לתור.
הודעה שנכתבת כאן ישירות = שיחה רגילה, בלי תור.
יציאה עם [DISPATCHER ERROR] = שגיאה חמורה: לתאר בקצרה, לא להפעיל עיוורת.
טוקן הבוט לעולם לא מודפס. אין רישום תוכן הודעות ללוגים.
רוטציה: אם מופיעה שורת `[SYSTEM rotate-suggest]`, אחרי התשובה הצע ליוני כאן
בצ'אט רוטציית צ'אט (פרטים: telegram_bridge/ROTATION.md).
חוזה מכסה: הודעה = סבב־סוכן אחד. התשתית כולה סקריפטים (0 מכסה).
בלי קרונים, בלי לולאות סוכן, בלי העברות בין צ'אטים.

משימת הקמה (חד־פעמית): ודא שאין supervisor ישן פעיל (tg-ctl.sh stop supervisor),
הפעל dispatcher ואז watcher־_main כ־background execs, ודא אחרי ~60 שניות
בסטטוס שהכל running ו־last_poll עדכני, אשר כאן.
```
