# Multi-bot — בוטים נפרדים לגשר טלגרם

## הרעיון
לכל בוט אינסטנס גשר עצמאי: תיקייה משלו, טוקן משלו (connector משלו ב־Vault),
offset משלו, תור משלו, סופרוויזר/dispatcher משלו וצ'אט Muse משלו.
אין תחרות על offset כי offset הוא פר־טוקן.

## איך הטוקן נבחר
- `bin/tg` קורא `TG_CREDENTIAL` מהסביבה (ברירת מחדל: `custom.telegram`).
- `bin/lib.sh` (נטען ע"י כל הסקריפטים) קורא קובץ `credential` בתיקיית
  האינסטנס ומייצא `TG_CREDENTIAL`. אין קובץ = ההתנהגות הישנה.
- הטוקן עצמו לעולם לא בקבצים — רק שם ה־connector.

## הקמת אינסטנס חדש
```bash
bash ~/workspace/telegram_bridge/bin/new-bot.sh <dir-name> <credential-name>
# דוגמה: new-bot.sh telegram_bridge_side custom.telegram-side
```
הסקריפט משכפל `bin/`, `tests/` והדוקס, כותב `credential`, ויוצר
`accounts.json` ריק + קבצי מצב. אחר כך:
1. יוצרים בוט ב־@BotFather.
2. שומרים את הטוקן ב־connector (כרטיס מאובטח).
3. ממלאים `accounts.json` (`{"<chat_id>": "<name>"}`).
4. פותחים צ'אט Muse חדש לבוט, מפעילים dispatcher + watcher `_main`
   כ־background execs, מוודאים עם `tg-ctl.sh status`.

## הפרדה בין אינסטנסים
- `tg-ctl.sh status/stop` — התבניות כוללות את `DIR`, כל אינסטנס רואה רק
  את התהליכים שלו.
- `topics/`, `outbox.txt`, `offset.txt`, `health.json`, `rotation.json` —
  הכל פר־אינסטנס.
- חוזה מכסה נשמר: הודעה = סבב אחד בצ'אט של הבוט שלה.

## מגבלות
- שם תיקיית האינסטנס: `[A-Za-z0-9_]` בלבד.
- כל אינסטנס = ~2 תהליכי background + polling של 45 שניות (0 מכסה AI).
