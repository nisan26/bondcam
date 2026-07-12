#!/usr/bin/env bash
# Adds the branded SATVIEW.TV guest broadcast page (1080p, no password)
# and updates the control room. Run:  sudo bash add-guest.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "צריך sudo"; exit 1; }
DOMAIN=satview.ddns.net
CERT=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem
KEY=/etc/letsencrypt/live/${DOMAIN}/privkey.pem
RAW=https://github.com/nisan26/bondcam/raw/main

echo "== מוריד את דף המרואיין ואת חדר הבקרה =="
mkdir -p /var/www/bondcam-guest
curl -fsSL -o /var/www/bondcam-guest/index.html "${RAW}/guest.html"
curl -fsSL -o /var/www/bondcam-admin/index.html "${RAW}/dashboard.html"
chmod -R a+rX /var/www/bondcam-guest /var/www/bondcam-admin

echo "== מגדיר nginx (דף המרואיין ללא סיסמה) =="
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

    # דף שידור למרואיין - ללא סיסמה
    location ^~ /guest/ {
        auth_basic off;
        alias /var/www/bondcam-guest/;
        index index.html;
    }

    # חדר בקרה - עם סיסמה
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

echo ""
echo "==================================================="
echo "  מוכן!"
echo "  חדר בקרה:      https://${DOMAIN}/          (עם סיסמה)"
echo "  דף מרואיין:    https://${DOMAIN}/guest/?cam=guest1   (ללא סיסמה, 1080p)"
echo "==================================================="
