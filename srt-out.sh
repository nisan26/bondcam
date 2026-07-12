#!/bin/sh
# Spawned by MediaMTX when a camera goes live (runOnReady).
#  1) SRT out (port 9000+N) : FULL HD - original video untouched + AAC audio
#  2) camN_prev             : 720p H264 + OPUS audio, for the control-room wall + audio meter
CAM="$1"
case "$CAM" in *_prev) exit 0 ;; esac
N=$(printf '%s' "$CAM" | tr -cd '0-9')
[ -z "$N" ] && exit 0
PORT=$((9000 + N))
SRC="rtsp://127.0.0.1:8554/${CAM}"
sleep 1

# control-room preview: 720p H264 + Opus (browsers need H264; Opus feeds the audio meter)
/usr/bin/ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$SRC" \
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
  -vf scale=1280:720 -b:v 2500k -maxrate 2800k -bufsize 4000k -g 60 -r 30 \
  -c:a libopus -b:a 96k -ar 48000 -ac 2 \
  -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/${CAM}_prev" &

# SRT out: FULL HD, video bit-for-bit (H265/H264 untouched), audio -> AAC for MPEG-TS
exec /usr/bin/ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$SRC" \
  -c:v copy -c:a aac -b:a 160k -ar 48000 -ac 2 \
  -f mpegts "srt://0.0.0.0:${PORT}?mode=listener"
