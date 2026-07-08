#!/usr/bin/env bash
# HTTPS for SATVIEW.TV control room (Let's Encrypt, webroot) + WebRTC over TLS.
# Requires ports 80 and 443 open to the internet, and free (Flussonic moved off 80).
# Run:  sudo bash setup-ssl.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "צריך sudo"; exit 1; }
DOMAIN=satview.ddns.net
CERT=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem
KEY=/etc/letsencrypt/live/${DOMAIN}/privkey.pem

echo "== מתקין certbot =="
apt-get update
apt-get install -y certbot
mkdir -p /var/www/html/.well-known/acme-challenge

echo "== nginx על 80 (עם עקיפת סיסמה לאימות התעודה) =="
cat > /etc/nginx/sites-available/bondcam-ssl <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ { auth_basic off; allow all; root /var/www/html; }
    auth_basic "SATVIEW Control Room";
    auth_basic_user_file /etc/nginx/.bondcam-htpasswd;
    root /var/www/bondcam-admin; index index.html;
    location / { try_files \$uri \$uri/ =404; }
    location /api/ { proxy_pass http://127.0.0.1:9997/; }
    location /recordings/ { alias /var/recordings/; autoindex on; }
}
EOF
ln -sf /etc/nginx/sites-available/bondcam-ssl /etc/nginx/sites-enabled/bondcam-ssl
nginx -t && systemctl reload nginx

echo "== משיג תעודה (webroot) =="
certbot certonly --webroot -w /var/www/html -d ${DOMAIN} \
  --non-interactive --agree-tos --register-unsafely-without-email

echo "== מגדיר HTTPS (443) + redirect =="
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

    auth_basic "SATVIEW Control Room";
    auth_basic_user_file /etc/nginx/.bondcam-htpasswd;
    root /var/www/bondcam-admin; index index.html;
    location / { try_files \$uri \$uri/ =404; }
    location /api/ { proxy_pass http://127.0.0.1:9997/; }
    location /recordings/ { alias /var/recordings/; autoindex on; }
}
EOF
nginx -t && systemctl reload nginx

echo "== WebRTC over TLS ב-MediaMTX (אותה תעודה) =="
if ! grep -q "webrtcEncryption" /opt/mediamtx/mediamtx.yml; then
  sed -i "s#^webrtcLocalUDPAddress: :8189#webrtcLocalUDPAddress: :8189\nwebrtcEncryption: yes\nwebrtcServerCert: ${CERT}\nwebrtcServerKey: ${KEY}#" /opt/mediamtx/mediamtx.yml
fi
systemctl restart mediamtx

echo "== hook לחידוש אוטומטי =="
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/bondcam.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
systemctl restart mediamtx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/bondcam.sh

echo ""
echo "==================================================="
echo "  HTTPS מוכן!  https://${DOMAIN}/"
echo "  (הישן עדיין עובד: http://${DOMAIN}:8080/)"
echo "==================================================="
