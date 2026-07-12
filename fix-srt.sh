#!/usr/bin/env bash
# H265 support + SRT with video AND audio + browser preview for the control room.
# Run:  sudo bash fix-srt.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "צריך sudo"; exit 1; }
RAW=https://github.com/nisan26/bondcam/raw/main
Y=/opt/mediamtx/mediamtx.yml

echo "== ffmpeg =="
apt-get install -y ffmpeg >/dev/null

echo "== סקריפטים ודף בקרה =="
curl -fsSL -o /usr/local/bin/srt-out.sh "${RAW}/srt-out.sh"
chmod +x /usr/local/bin/srt-out.sh
curl -fsSL -o /var/www/bondcam-admin/index.html "${RAW}/dashboard.html"
chmod a+r /var/www/bondcam-admin/index.html

echo "== RTSP פנימי (נדרש לאודיו ולהמרה) =="
if grep -q '^rtsp: no' "$Y"; then
  sed -i 's#^rtsp: no#rtsp: yes\nrtspAddress: 127.0.0.1:8554\nrtspTransports: [tcp]#' "$Y"
elif ! grep -q '^rtsp:' "$Y"; then
  printf '\nrtsp: yes\nrtspAddress: 127.0.0.1:8554\nrtspTransports: [tcp]\n' >> "$Y"
fi

echo "== נתיבי תצוגה (_prev) - בלי הקלטה ובלי לולאה =="
python3 - "$Y" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
if '_prev' not in s:
    s=re.sub(r'(?m)^paths:\s*$',
             'paths:\n  "~^.*_prev$":\n    record: no\n    runOnReady: ""\n', s, count=1)
    open(p,'w').write(s)
    print("preview paths added")
else:
    print("already there")
PY

systemctl restart mediamtx
sleep 2
systemctl is-active mediamtx

echo ""
echo "==================================================="
echo "  מוכן!"
echo "  · SRT (מסך #1): srt://satview.ddns.net:9001  — וידאו + אודיו"
echo "  · H265 מהטלפון נתמך; חדר הבקרה מציג עותק H264"
echo "  · המצלמה צריכה לעלות מחדש לאוויר"
echo "==================================================="
