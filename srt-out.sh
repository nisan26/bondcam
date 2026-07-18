#!/bin/sh
# MediaMTX runOnReady: /usr/local/bin/srt-out.sh $MTX_PATH $MTX_QUERY
# GStreamer edition - PURE SRT, no RTSP anywhere.
#   cam1..camN  guest links (browser/WHIP) -> SRT 9001..
#   app1..appN  BondCam / IRL Pro          -> SRT 9101..
# SRT listeners accept MULTIPLE clients simultaneously (srtsink).
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
# SRT read/write against MediaMTX (loopback)
SRC="srt://127.0.0.1:8890?streamid=read:${CAM}"
PREV="srt://127.0.0.1:8890?streamid=publish:${CAM}_prev"

# rotation hint sent by the guest page:  /camN/whip?rot=90
ROT=$(printf '%s' "$QUERY" | sed -n 's/.*rot=\([0-9]\{1,3\}\).*/\1/p')
case "$ROT" in
  90)  FLIP="videoflip method=clockwise !" ;;
  270) FLIP="videoflip method=counterclockwise !" ;;
  180) FLIP="videoflip method=rotate-180 !" ;;
  *)   FLIP="" ;;
esac

sleep 1
GST=/usr/bin/gst-launch-1.0

# --- control-room preview: 720p H264 + Opus -> <cam>_prev (SRT publish)
$GST -q uridecodebin uri="$SRC" name=d \
  d. ! queue ! videoconvert ! $FLIP videoscale \
     ! "video/x-raw,width=1280,height=720" \
     ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=2500 key-int-max=60 \
     ! h264parse ! mux. \
  d. ! queue ! audioconvert ! audioresample ! opusenc bitrate=96000 ! mux. \
  mpegtsmux name=mux ! queue ! srtsink uri="$PREV" \
  >/dev/null 2>&1 &

# --- SRT out (multi-client listener)
case "$CAM" in
  app*)
    # BondCam: pure byte relay of the MPEG-TS stream - zero touch, HD as-is
    exec $GST -q -e srtsrc uri="$SRC" ! queue \
      ! srtsink uri="srt://:${PORT}?mode=listener" wait-for-connection=false
    ;;
  *)
    # Guest link: rotate if asked, re-encode 1080p H264 + AAC
    exec $GST -q -e uridecodebin uri="$SRC" name=d \
      d. ! queue ! videoconvert ! $FLIP videoscale \
         ! "video/x-raw,width=1920,height=1080" \
         ! x264enc tune=zerolatency speed-preset=veryfast bitrate=3500 key-int-max=60 \
         ! h264parse ! mux. \
      d. ! queue ! audioconvert ! audioresample ! avenc_aac bitrate=160000 ! aacparse ! mux. \
      mpegtsmux name=mux ! queue \
      ! srtsink uri="srt://:${PORT}?mode=listener" wait-for-connection=false
    ;;
esac
