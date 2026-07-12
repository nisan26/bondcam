#!/usr/bin/env bash
# SATVIEW.TV: guest links (1080p) + a dedicated SRT port per screen.
# Run:  sudo bash add-guest.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "צריך sudo"; exit 1; }
DOMAIN=satview.ddns.net
CERT=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem
KEY=/etc/letsencrypt/live/${DOMAIN}/privkey.pem
RAW=https://github.com/nisan26/bondcam/raw/main

echo "== תלויות =="
apt-get install -y srt-tools curl >/dev/null

echo "== מוריד דפים =="
mkdir -p /var/www/bondcam-guest /var/www/bondcam-admin
curl -fsSL -o /var/www/bondcam-guest/index.html "${RAW}/guest.html"
curl -fsSL -o /var/www/bondcam-admin/index.html "${RAW}/dashboard.html"
curl -fsSL -o /usr/local/bin/srt-out.sh          "${RAW}/srt-out.sh"
chmod +x /usr/local/bin/srt-out.sh
chmod -R a+rX /var/www/bondcam-guest /var/www/bondcam-admin

echo "== פורט SRT ייעודי לכל מסך (9001-9025) =="
if ! grep -q "runOnReady" /opt/mediamtx/mediamtx.yml; then
  sed -i 's#^pathDefaults:#pathDefaults:\n  runOnReady: /usr/local/bin/srt-out.sh $MTX_PATH\n  runOnReadyRestart: yes#' /opt/mediamtx/mediamtx.yml
fi
systemctl restart mediamtx

echo "== nginx: דף מרואיין ללא סיסמה =="
cat > /etc/nginx/sites-available/bondcam-ssl <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ { auth_basic off; allow all; root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    server_name ${DOMAIN};
    ssl_certificate ${CERT};
    ssl_certificate_key ${KEY};

    location ^~ /guest/ { auth_basic off; alias /var/www/bondcam-guest/; index index.html; }

    auth_basic "SATVIEW Control Room";
    auth_basic_user_file /etc/nginx/.bondcam-htpasswd;
    root /var/www/bondcam-admin;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
    location /api/ { proxy_pass http://127.0.0.1:9997/; }
    location /recordings/ { alias /var/recordings/; autoindex on; }
}
EOF
ln -sf /etc/nginx/sites-available/bondcam-ssl /etc/nginx/sites-enabled/bondcam-ssl
nginx -t && systemctl reload nginx

echo "== חומת אש =="
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 9001:9025/udp
fi

echo ""
echo "==================================================="
echo "  מוכן!"
echo "  חדר בקרה:    https://${DOMAIN}/"
echo "  לינק מרואיין: https://${DOMAIN}/guest/?cam=cam1"
echo "  SRT למסך #1:  srt://${DOMAIN}:9001   (מסך #2 = 9002 ...)"
echo "  >> פתח אצל ספק ה-VPS פורטים 9001-9025/udp <<"
echo "==================================================="
