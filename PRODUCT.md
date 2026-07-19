# SATVIEW.TV — מערכת בונדינג לשידור חי מנייד

מסמך מוצר והקשר. פותחים צ'אט חדש? קראו את זה קודם — הוא מסביר את כל המערכת,
מה כבר עובד, ואיפה כל דבר יושב.

---

## מה זה

מערכת בונדינג בסגנון LiveU בכלים פתוחים: אפליקציית אנדרואיד (BondCam) משדרת
וידאו HD מהטלפון בשילוב **WiFi + סלולר במקביל** (SRTLA bonding), שרת מרכזי
מרכיב את הזרם חזרה ומפיץ אותו לדשבורד חדר בקרה עם עד 16 ערוצים.

הרעיון: לשכפל את מה ש-LiveU עושה (LRT + חומרה ייעודית + LiveU Central)
בעלות שבריר — SRTLA ≈ LRT, קידוד החומרה של הטלפון ≈ המקודד, MediaMTX +
דשבורד ≈ ה-MMH/Central.

---

## ארכיטקטורה

```
טלפון (BondCam)                    שרת sat33 (satview.ddns.net)
┌───────────────┐                  ┌──────────────────────────────────────┐
│ מצלמה+מיק     │  WiFi  ─────┐    │ srtla_rec :5001                       │
│ RootEncoder   │             ├──▶ │   (מרכיב בונדינג)                     │
│ H.265         │  סלולר ─────┘    │        │ SRT                          │
│ SrtlaSender   │                  │        ▼                             │
│  ↓ 127.0.0.1  │                  │ MediaMTX :8890 (SRT) :8889 (WebRTC)   │
└───────────────┘                  │        │ runOnReady                   │
                                   │        ▼                             │
                                   │ srt-out.sh                           │
                                   │  ├─ תצוגה 720p → <cam>_prev (WebRTC)  │
                                   │  └─ SRT out :9101+ (מרובה צופים)      │
                                   │ bondstat.py :9998 (סטטיסטיקות)        │
                                   │ nginx → דשבורד /var/www/bondcam-admin │
                                   └──────────────────────────────────────┘
```

---

## פורטים

| פורט | תפקיד |
|------|-------|
| 5001 | SRTLA bonding — הטלפון משדר לכאן (WiFi+סלולר) |
| 8890 | MediaMTX SRT (publish/read עם streamid) |
| 8889 | MediaMTX WebRTC (תצוגה בדשבורד) |
| 8554 | MediaMTX RTSP (פנימי, לתצוגה) |
| 9997 | MediaMTX API |
| 9998 | bondstat — נתוני בונדינג/CPU לדשבורד |
| 9101-9116 | SRT out לכל ערוץ (APP1-16) — לצפייה ב-VLC/מקלט, מרובה צופים |
| 9001-9016 | SRT out לערוצי אורחים (cam1-16) |

**streamid:** `publish:appN` לשידור, `read:appN` לצפייה. כל טלפון = streamid ייחודי.

---

## רכיבי השרת

- **srtla_rec** (`/usr/local/bin/srtla_rec`) — מקבל בונדינג על 5001, מרכיב ל-SRT יחיד ל-MediaMTX. שירות: `srtla.service`.
- **MediaMTX** (`/opt/mediamtx/`) — שרת המדיה. תצורה: `mediamtx.yml`. מריץ `srt-out.sh` על כל ערוץ שעולה (`runOnReady`).
- **srt-out.sh** (`/usr/local/bin/`) — לכל ערוץ: תצוגת 720p ל-multiview + יציאת SRT מרובת-צופים ל-9101+. היברידי: ffmpeg לתצוגה (יודע H.265), GStreamer לממסר.
- **bondstat.py** (`/usr/local/bin/`, שירות `bondstat.service`) — משרת JSON על 9998: נתיבי בונדינג, קצב לכל רשת (דרך conntrack על 5001), CPU/זיכרון.
- **דשבורד** (`/var/www/bondcam-admin/index.html`) — חדר הבקרה. טאבים: לינקים / אפליקציה / בונדינג. 16 ערוצים, עריכת שם כתב, מדי אודיו, גרף בונדינג, כרטיס שרת, כפתור הקלטה.
- **דף הורדות** (`/var/www/bondcam-app/`) — מגיש את ה-APK.

---

## האפליקציה (BondCam)

- Kotlin, מבוססת RootEncoder 2.5.9 (pedroSG94).
- **SrtlaSender.kt** — ליבת הבונדינג בצד הטלפון. מפצל פקטות בין WiFi/סלולר.
- **MainActivity.kt** — UI, הגדרות, שידור, Adaptive Bitrate.
- **BondingNetworks.kt** — מחזיק את שתי הרשתות דלוקות במקביל (requestNetwork).
- מצבים: פורט **5001** = בונדינג (ברירת מחדל), **8890** = DIRECT (רשת אחת).
- שדות: שרת, פורט, ביטרייט, **Delay ms** (חלון תיקון SRT), Stream ID.
- הגדרה בלחיצה: `bondcam://setup?host=...&port=...&sid=...&latency=...&name=...` (QR/לינק מהדשבורד).

---

## בנייה ופריסה

- **קוד ב-GitHub:** `github.com/nisan26/bondcam` (ברנץ' main).
- ה-APK נבנה אוטומטית ב-**GitHub Actions** בכל push (`.github/workflows/build.yml`).
- הורדה קבועה: `github.com/nisan26/bondcam/releases/download/latest/bondcam.apk`
- מבנה הריפו: `app/` (מקורות Kotlin + מניפסט + layout), `dashboard.html`, `srt-out.sh`, `server/` (קבצי שרת + install), `bonding-project.zip` (עץ פרויקט מלא ל-build).
- **לעדכן שרת אחרי שינוי דשבורד:** `curl -s -o /var/www/bondcam-admin/index.html https://raw.githubusercontent.com/nisan26/bondcam/main/dashboard.html`
- **לעדכן srt-out:** `curl -s -o /usr/local/bin/srt-out.sh https://raw.githubusercontent.com/nisan26/bondcam/main/srt-out.sh && chmod +x`

---

## אלגוריתם הבונדינג (מצב יציב נוכחי — build 45/57)

- שתי רשתות תקינות → החזק (WiFi) מוביל, סלולר גיבוי חם (~10% probe).
- רשת עם איבודי פקטות (`lossRecent>=5`) → "חלש", יורדת לנתח בדיקה 10%.
- 3 שניות בלי איבודים → חוזרת לאיזון אוטומטית.
- **Adaptive Bitrate:** עומס → הביטרייט יורד ~20% (איכות במקום תקיעה), משתחרר → מטפס חזרה.
- שורת סטטוס: `WIFI: פעיל X% | CELLULAR: חלש Y%  ▲Zk`.

היו ניסיונות בגרסאות 46-58 (שקלול גמיש, שכפול פקטות, failover מהיר) —
הוחזרו לאחור כי הוסיפו רגרסיות. הבסיס היציב הוא 45.

---

## תקלות שנפתרו (לקחים)

1. **"Channel was closed"** → RootEncoder Ktor sockets. תיקון: `setSocketType(JAVA)`.
2. **"ICMP Port Unreachable"** → SrtlaSender נקשר ל-loopback IPv6. תיקון: bind מפורש ל-`127.0.0.1`.
3. **תצוגה לא עולה** → MediaMTX לא מקבל Opus-in-MPEGTS דרך SRT. תיקון: תצוגה ב-ffmpeg דרך RTSP loopback.
4. **תקיעות וידאו לסירוגין** → **הדיסק היה מלא 100%** (ההקלטות מילאו 13/20GB). תיקון: הקלטה כבויה כברירת מחדל + מחיקה אוטומטית 72h + הגבלת לוגים 300MB. **הרשת/בונדינג היו תקינים לגמרי — לא לחפש שם.**

---

## גיבוי / התקנה בשרת חדש

`server/install-server.sh` בריפו — סקריפט התקנה שמעמיד את כל המערכת על שרת נקי
(Ubuntu). כל קבצי התצורה החיים מגובים ב-`server/` בריפו.

---

## נקודות פתוחות / TODO

- להחליף סיסמת root של השרת (נשלחה בצ'אט) — `passwd`.
- להגדיר כניסת SSH עם מפתח במקום סיסמה.
- מדי קליטה (📶 WiFi / 📡 סלולר) באפליקציה — נוספו ב-build 58, לא נכללים בבסיס 57. להחליט אם למזג.
