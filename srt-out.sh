#!/bin/sh
# Spawned by MediaMTX when a camera goes live (runOnReady).
#  1) SRT out on port 9000+N  : original video (H264/H265) + audio AAC
#  2) preview path camN_prev  : low-res H264 so the control room works even with H265
CAM="$1"
case "$CAM" in *_prev) exit 0 ;; esac          # never recurse on preview paths
N=$(printf '%s' "$CAM" | tr -cd '0-9')
[ -z "$N" ] && exit 0
PORT=$((9000 + N))
SRC="rtsp://127.0.0.1:8554/${CAM}"
sleep 1

# browser-friendly preview (H264 640x360) for the control-room wall
/usr/bin/ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$SRC" \
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
  -vf scale=640:-2 -b:v 800k -g 60 \
  -c:a aac -b:a 64k -ar 48000 -ac 2 \
  -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/${CAM}_prev" &

# full-quality SRT out: video untouched, audio to AAC (MPEG-TS needs it)
exec /usr/bin/ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$SRC" \
  -c:v copy -c:a aac -b:a 160k -ar 48000 -ac 2 \
  -f mpegts "srt://0.0.0.0:${PORT}?mode=listener"
