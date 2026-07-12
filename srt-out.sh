#!/bin/sh
# Spawned by MediaMTX when a camera goes live (runOnReady).
# camN  ->  dedicated SRT listener on port 9000+N
CAM="$1"
N=$(printf '%s' "$CAM" | tr -cd '0-9')
[ -z "$N" ] && exit 0
PORT=$((9000 + N))
exec /usr/bin/srt-live-transmit \
  "srt://127.0.0.1:8890?streamid=read:${CAM}&mode=caller" \
  "srt://:${PORT}?mode=listener"
