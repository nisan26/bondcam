#!/bin/sh
# Spawned by MediaMTX when a camera goes live (runOnReady).
# camN -> dedicated SRT listener on port 9000+N, with BOTH video and audio.
# Reads via RTSP (carries Opus), copies video, transcodes audio Opus->AAC for MPEG-TS.
CAM="$1"
N=$(printf '%s' "$CAM" | tr -cd '0-9')
[ -z "$N" ] && exit 0
PORT=$((9000 + N))
sleep 1
exec /usr/bin/ffmpeg -hide_banner -loglevel error \
  -rtsp_transport tcp -i "rtsp://127.0.0.1:8554/${CAM}" \
  -c:v copy \
  -c:a aac -b:a 160k -ar 48000 -ac 2 \
  -f mpegts "srt://0.0.0.0:${PORT}?mode=listener"
