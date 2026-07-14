#!/bin/sh
# MediaMTX runOnReady: /usr/local/bin/srt-out.sh $MTX_PATH $MTX_QUERY
#   cam1..camN  guest links (browser/WHIP) -> SRT 9001..
#   app1..appN  BondCam / IRL Pro          -> SRT 9101..
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
SRC="rtsp://127.0.0.1:8554/${CAM}"

# rotation hint sent by the guest page:  /camN/whip?rot=90
ROT=$(printf '%s' "$QUERY" | sed -n 's/.*rot=\([0-9]\{1,3\}\).*/\1/p')
case "$ROT" in
  90)  PRE="transpose=1," ;;              # 90 clockwise
  270) PRE="transpose=2," ;;              # 90 counter-clockwise
  180) PRE="transpose=1,transpose=1," ;;
  *)   PRE="" ;;
esac

# always end up as 1920x1080 landscape (cover + centre-crop)
TV="${PRE}scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1"

sleep 1

# --- control-room preview: 720p H264 + Opus
/usr/bin/ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$SRC" \
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
  -vf "${TV},scale=1280:720" -b:v 2500k -maxrate 2800k -bufsize 4000k -g 60 -r 30 \
  -c:a libopus -b:a 96k -ar 48000 -ac 2 \
  -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/${CAM}_prev" &

# --- SRT out
case "$CAM" in
  app*)
    # BondCam / IRL Pro: already landscape H265/H264 -> copy, bit-for-bit HD
    exec /usr/bin/ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$SRC" \
      -c:v copy -c:a aac -b:a 160k -ar 48000 -ac 2 \
      -f mpegts "srt://0.0.0.0:${PORT}?mode=listener"
    ;;
  *)
    # Guest link: rotate if asked, then force 1920x1080 landscape H264
    exec /usr/bin/ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$SRC" \
      -c:v libx264 -preset veryfast -tune zerolatency -profile:v high -pix_fmt yuv420p \
      -vf "$TV" -b:v 3500k -maxrate 4000k -bufsize 6000k -g 60 -r 30 \
      -c:a aac -b:a 160k -ar 48000 -ac 2 \
      -f mpegts "srt://0.0.0.0:${PORT}?mode=listener"
    ;;
esac
