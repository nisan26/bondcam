#!/usr/bin/env bash
# Fix: SRT output now carries BOTH video and audio (Opus -> AAC).
# Run:  sudo bash fix-srt.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "צריך sudo"; exit 1; }
RAW=https://github.com/nisan26/bondcam/raw/main

echo "== ffmpeg =="
apt-get install -y ffmpeg >/dev/null

echo "== מוריד srt-out מעודכן =="
curl -fsSL -o /usr/local/bin/srt-out.sh "${RAW}/srt-out.sh"
chmod +x /usr/local/bin/srt-out.sh

echo "== מפעיל RTSP פנימי ב-MediaMTX (נדרש כדי לשמר את האודיו) =="
Y=/opt/mediamtx/mediamtx.yml
if grep -q '^rtsp: no' "$Y"; then
  sed -i 's#^rtsp: no#rtsp: yes\nrtspAddress: 127.0.0.1:8554\nrtspTransports: [tcp]#' "$Y"
elif ! grep -q '^rtsp:' "$Y"; then
  printf '\nrtsp: yes\nrtspAddress: 127.0.0.1:8554\nrtspTransports: [tcp]\n' >> "$Y"
fi
grep -n '^rtsp' "$Y" || true

systemctl restart mediamtx
sleep 2
systemctl is-active mediamtx

echo ""
echo "==================================================="
echo "  תוקן! כתובת SRT מעבירה עכשיו וידאו + אודיו."
echo "  מסך #1: srt://satview.ddns.net:9001"
echo "  (המצלמה צריכה לעלות מחדש לאוויר כדי שהפורט ייפתח)"
echo "==================================================="
