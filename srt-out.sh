#!/bin/sh
# MediaMTX runOnReady: /usr/local/bin/srt-out.sh $MTX_PATH $MTX_QUERY
# Hybrid edition:
#   - SRT out (9101+/9001+): GStreamer pure byte relay, MULTI-CLIENT listeners
#   - Preview (<cam>_prev):  ffmpeg (proven), SRT read -> loopback push, auto-restart
#   cam1..camN  guest links (browser/WHIP) -> SRT 9001..
#   app1..appN  BondCam / IRL Pro          -> SRT 9101..
# Rollback: cp /usr/local/bin/srt-out.ffmpeg.bak /usr/local/bin/srt-out.sh
CAM="$1"
QUERY="$2"
case "$CAM" in *_prev) exit 0 ;; esac
N=$(printf '%s' "$CAM" | tr -cd '0-9')
[ -z "$N" ] && exit 0
case "$CAM" in
  app*) BASE=9100 ;;
  *)    BASE=9000 ;;
esac
PORT=$((BASE + N))
SRC="srt://127.0.0.1:8890?streamid=read:${CAM}"

# rotation hint sent by the guest page:  /camN/whip?rot=90
ROT=$(printf '%s' "$QUERY" | sed -n 's/.*rot=\([0-9]\{1,3\}\).*/\1/p')
case "$ROT" in
  90)  PRE="transpose=1," ;;
  270) PRE="transpose=2," ;;
  180) PRE="transpose=1,transpose=1," ;;
  *)   PRE="" ;;
esac
TV="${PRE}scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1"

sleep 1

# --- control-room preview: 720p H264 + Opus (handles H265 input), auto-restart
( while :; do
    /usr/bin/ffmpeg -hide_banner -loglevel error -i "$SRC" \
      -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
      -vf "${TV},scale=1280:720" -b:v 2500k -maxrate 2800k -bufsize 4000k -g 60 -r 30 \
      -c:a libopus -b:a 96k -ar 48000 -ac 2 \
      -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/${CAM}_prev"
    sleep 2
  done ) >/dev/null 2>&1 &

# --- SRT out (multi-client listener)
case "$CAM" in
  app*)
    # BondCam: pure byte relay of the MPEG-TS stream - zero touch, HD as-is
    exec /usr/bin/gst-launch-1.0 -q -e srtsrc uri="$SRC" ! queue \
      ! srtsink uri="srt://:${PORT}?mode=listener" wait-for-connection=false
    ;;
  *)
    # Guest link: rotate if asked, re-encode 1080p H264 + AAC (ffmpeg)
    exec /usr/bin/ffmpeg -hide_banner -loglevel error -i "$SRC" \
      -c:v libx264 -preset veryfast -tune zerolatency -profile:v high -pix_fmt yuv420p \
      -vf "$TV" -b:v 3500k -maxrate 4000k -bufsize 6000k -g 60 -r 30 \
      -c:a aac -b:a 160k -ar 48000 -ac 2 \
      -f mpegts "srt://0.0.0.0:${PORT}?mode=listener"
    ;;
esac
