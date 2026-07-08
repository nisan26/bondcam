#!/usr/bin/env bash
# HTTPS for SATVIEW.TV control room (Let's Encrypt) + WebRTC over TLS.
# Requires ports 80 and 443 open to the internet.
# Run:  sudo bash setup-ssl.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "צריך sudo"; exit 1; }
DOMAIN=satview.ddns.net
CERT=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem
KEY=/etc/letsencrypt/live/${DOMAIN}/privkey.pem

echo "== מתקין certbot =="
apt-get update
apt-get install -y certbot python3-certbot-nginx

echo "== nginx לדומיין על פורט 80 =="
cat > /etc/nginx/sites-available/bondcam-ssl <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

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

echo "== משיג תעודת SSL =="
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --register-unsafely-without-email --redirect

echo "== מפעיל HTTPS ל-WebRTC ב-MediaMTX =="
if ! grep -q "webrtcEncryption" /opt/mediamtx/mediamtx.yml; then
  sed -i "s#^webrtcLocalUDPAddress: :8189#webrtcLocalUDPAddress: :8189\nwebrtcEncryption: yes\nwebrtcServerCert: ${CERT}\nwebrtcServerKey: ${KEY}#" /opt/mediamtx/mediamtx.yml
fi
systemctl restart mediamtx

echo "== hook לחידוש אוטומטי של התעודה =="
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/restart-mediamtx.sh <<'HOOK'
#!/bin/sh
systemctl restart mediamtx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-mediamtx.sh

echo ""
echo "==================================================="
echo "  HTTPS מוכן!"
echo "  חדר בקרה מאובטח:  https://${DOMAIN}/"
echo "  ודא שפורטים 80/tcp ו-443/tcp פתוחים אצל ספק ה-VPS"
echo "==================================================="
