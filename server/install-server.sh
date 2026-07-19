#!/bin/sh
# ============================================================
# SATVIEW.TV bonding server - one-shot installer / restore
# Usage: sh install-server.sh [domain]     (default: satview.ddns.net)
# Fresh Ubuntu 22.04/24.04. Safe to re-run.
# ============================================================
set -e
REPO=https://raw.githubusercontent.com/nisan26/bondcam/main
DOMAIN=${1:-satview.ddns.net}
echo "== SATVIEW installer, domain: $DOMAIN =="

# --- packages ---
apt update
apt install -y nginx ffmpeg python3 conntrack curl unzip git apache2-utils \
  build-essential \
  gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
  gstreamer1.0-rtsp

# --- MediaMTX ---
mkdir -p /opt/mediamtx
if [ ! -f /opt/mediamtx/mediamtx ]; then
  ARCH=$(uname -m); case "$ARCH" in aarch64) A=arm64v8;; *) A=amd64;; esac
  URL=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
    | grep browser_download_url | grep "linux_${A}.tar.gz" | head -1 | cut -d'"' -f4)
  curl -sL "$URL" -o /tmp/mtx.tgz
  tar xzf /tmp/mtx.tgz -C /opt/mediamtx mediamtx
fi
curl -s $REPO/server/mediamtx.yml -o /opt/mediamtx/mediamtx.yml
sed -i "s/satview.ddns.net/$DOMAIN/g" /opt/mediamtx/mediamtx.yml

# --- srtla_rec (BELABOX srtla) ---
if [ ! -f /usr/local/bin/srtla_rec ]; then
  rm -rf /tmp/srtla
  git clone https://github.com/BELABOX/srtla /tmp/srtla
  ( cd /tmp/srtla && make srtla_rec ) && cp /tmp/srtla/srtla_rec /usr/local/bin/
fi

# --- scripts + services ---
curl -s $REPO/srt-out.sh -o /usr/local/bin/srt-out.sh && chmod +x /usr/local/bin/srt-out.sh
curl -s $REPO/server/bondstat.py -o /usr/local/bin/bondstat.py
for s in srtla bondstat mediamtx; do
  curl -s $REPO/server/$s.service -o /etc/systemd/system/$s.service
done

# --- web root ---
mkdir -p /var/www/bondcam-admin /var/www/bondcam-app /var/www/bondcam-guest /var/recordings
curl -s  $REPO/dashboard.html -o /var/www/bondcam-admin/index.html
curl -s  $REPO/app-page.html  -o /var/www/bondcam-app/index.html || true
curl -s  $REPO/guest.html     -o /var/www/bondcam-guest/index.html || true
curl -sL https://github.com/nisan26/bondcam/releases/download/latest/bondcam.apk \
        -o /var/www/bondcam-app/bondcam.apk || true

# --- nginx ---
[ -f /etc/nginx/.bondcam-htpasswd ] || htpasswd -bc /etc/nginx/.bondcam-htpasswd admin changeme
rm -f /etc/nginx/sites-enabled/default
if [ -d /etc/letsencrypt/live/$DOMAIN ]; then
  curl -s $REPO/server/nginx-bondcam-ssl.conf -o /etc/nginx/sites-available/bondcam
else
  echo ">> No SSL cert yet - installing HTTP-only site."
  echo ">> For SSL: apt install -y certbot python3-certbot-nginx && certbot --nginx -d $DOMAIN"
  curl -s $REPO/server/nginx-bondcam-http.conf -o /etc/nginx/sites-available/bondcam
fi
sed -i "s/satview.ddns.net/$DOMAIN/g" /etc/nginx/sites-available/bondcam
ln -sf /etc/nginx/sites-available/bondcam /etc/nginx/sites-enabled/bondcam

# --- housekeeping: cap journald so the disk never fills from logs ---
grep -q '^SystemMaxUse=300M' /etc/systemd/journald.conf || \
  sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=300M/' /etc/systemd/journald.conf
modprobe nf_conntrack 2>/dev/null || true
echo nf_conntrack > /etc/modules-load.d/nf_conntrack.conf

# --- start everything ---
systemctl daemon-reload
systemctl restart systemd-journald
systemctl enable --now mediamtx srtla bondstat
nginx -t && systemctl restart nginx

echo "== DONE =="
echo "Dashboard: http://$DOMAIN/  (user: admin, pass: changeme - CHANGE IT: htpasswd /etc/nginx/.bondcam-htpasswd admin)"
echo "Phone app: http://$DOMAIN/app/   Bonding port: 5001"
