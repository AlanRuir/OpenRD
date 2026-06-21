#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=${PROJECT_DIR:-/home/linaro/OpenRD}
STATE_DIR=${OPENRD_CLOUD_RTMP_STATE_DIR:-$PROJECT_DIR/vehicle/native_video/run}
SESSION=${OPENRD_CLOUD_RTMP_SESSION:-openrd-cloud-rtmp}
LOG_FILE=${OPENRD_CLOUD_RTMP_LOG:-$STATE_DIR/openrd-cloud-rtmp.log}
PID_FILE=${OPENRD_CLOUD_RTMP_PID_FILE:-$STATE_DIR/openrd-cloud-rtmp.pid}

RTMP_URL=${OPENRD_CLOUD_RTMP_URL:-rtmp://43.139.25.165:1935/live/openrd}
DEVICE=${OPENRD_CLOUD_RTMP_DEVICE:-/dev/openrd-cam-uvc}
INPUT_FORMAT=${OPENRD_CLOUD_RTMP_INPUT_FORMAT:-mjpg}
MJPEG_DECODER=${OPENRD_CLOUD_RTMP_MJPEG_DECODER:-mpp}
WIDTH=${OPENRD_CLOUD_RTMP_WIDTH:-1280}
HEIGHT=${OPENRD_CLOUD_RTMP_HEIGHT:-720}
FPS=${OPENRD_CLOUD_RTMP_FPS:-30}
BITRATE=${OPENRD_CLOUD_RTMP_BITRATE:-2000000}
GOP=${OPENRD_CLOUD_RTMP_GOP:-30}

usage() {
  cat <<'USAGE'
Usage:
  start_openrd_cloud_rtmp.sh start
  start_openrd_cloud_rtmp.sh stop
  start_openrd_cloud_rtmp.sh restart
  start_openrd_cloud_rtmp.sh status
  start_openrd_cloud_rtmp.sh pipeline
  start_openrd_cloud_rtmp.sh run

Environment:
  OPENRD_CLOUD_RTMP_URL              default rtmp://43.139.25.165:1935/live/openrd
  OPENRD_CLOUD_RTMP_DEVICE           default /dev/openrd-cam-uvc
  OPENRD_CLOUD_RTMP_INPUT_FORMAT     mjpg|nv12, default mjpg
  OPENRD_CLOUD_RTMP_MJPEG_DECODER    mpp|software, default mpp
  OPENRD_CLOUD_RTMP_WIDTH            default 1280
  OPENRD_CLOUD_RTMP_HEIGHT           default 720
  OPENRD_CLOUD_RTMP_FPS              default 30
  OPENRD_CLOUD_RTMP_BITRATE          default 2000000
  OPENRD_CLOUD_RTMP_GOP              default 30
USAGE
}

quote() {
  printf '%q' "$1"
}

camera_pipeline() {
  case "$INPUT_FORMAT" in
    mjpg|mjpeg|jpeg)
      if [[ "$MJPEG_DECODER" == "mpp" ]]; then
        printf '%s\n' \
          "v4l2src device=$(quote "$DEVICE")" \
          "! image/jpeg,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
          "! jpegparse" \
          "! mppjpegdec format=NV12" \
          "! video/x-raw,format=NV12"
      elif [[ "$MJPEG_DECODER" == "software" ]]; then
        printf '%s\n' \
          "v4l2src device=$(quote "$DEVICE")" \
          "! image/jpeg,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
          "! jpegdec" \
          "! videoconvert" \
          "! video/x-raw,format=NV12"
      else
        echo "unsupported OPENRD_CLOUD_RTMP_MJPEG_DECODER: $MJPEG_DECODER" >&2
        exit 2
      fi
      ;;
    nv12|raw)
      printf '%s\n' \
        "v4l2src device=$(quote "$DEVICE")" \
        "! video/x-raw,format=NV12,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1"
      ;;
    *)
      echo "unsupported OPENRD_CLOUD_RTMP_INPUT_FORMAT: $INPUT_FORMAT" >&2
      exit 2
      ;;
  esac
}

pipeline_text() {
  {
    camera_pipeline
    printf '%s\n' \
      "! mpph264enc bps=${BITRATE} gop=${GOP} profile=baseline header-mode=each-idr" \
      "! queue" \
      "! h264parse config-interval=1" \
      "! video/x-h264,stream-format=avc,alignment=au" \
      "! flvmux streamable=true" \
      "! rtmpsink location=$(quote "${RTMP_URL} live=1")"
  } | paste -sd ' ' -
}

run_pipeline() {
  echo "[$(date --iso-8601=seconds)] starting OpenRD cloud RTMP push"
  echo "device=$DEVICE input=$INPUT_FORMAT decoder=$MJPEG_DECODER size=${WIDTH}x${HEIGHT}@${FPS} bitrate=$BITRATE rtmp=$RTMP_URL"
  echo "pipeline=$(pipeline_text)"
  exec bash -lc "gst-launch-1.0 -e $(pipeline_text)"
}

start_push() {
  mkdir -p "$STATE_DIR"
  local script_path
  script_path=$(readlink -f "$0")
  stop_push >/dev/null 2>&1 || true
  sleep 1

  local cmd
  cmd="cd $(quote "$PROJECT_DIR") && exec env"
  cmd+=" OPENRD_CLOUD_RTMP_URL=$(quote "$RTMP_URL")"
  cmd+=" OPENRD_CLOUD_RTMP_DEVICE=$(quote "$DEVICE")"
  cmd+=" OPENRD_CLOUD_RTMP_INPUT_FORMAT=$(quote "$INPUT_FORMAT")"
  cmd+=" OPENRD_CLOUD_RTMP_MJPEG_DECODER=$(quote "$MJPEG_DECODER")"
  cmd+=" OPENRD_CLOUD_RTMP_WIDTH=$(quote "$WIDTH")"
  cmd+=" OPENRD_CLOUD_RTMP_HEIGHT=$(quote "$HEIGHT")"
  cmd+=" OPENRD_CLOUD_RTMP_FPS=$(quote "$FPS")"
  cmd+=" OPENRD_CLOUD_RTMP_BITRATE=$(quote "$BITRATE")"
  cmd+=" OPENRD_CLOUD_RTMP_GOP=$(quote "$GOP")"
  cmd+=" $(quote "$script_path") run >> $(quote "$LOG_FILE") 2>&1"

  if command -v screen >/dev/null 2>&1; then
    screen -dmS "$SESSION" bash -lc "$cmd"
    rm -f "$PID_FILE"
  else
    setsid bash -lc "$cmd" </dev/null >/dev/null 2>&1 &
    echo "$!" > "$PID_FILE"
  fi
  sleep 2
  status_push
}

stop_push() {
  if command -v screen >/dev/null 2>&1; then
    screen -S "$SESSION" -X quit >/dev/null 2>&1 || true
  fi

  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill -TERM -- "-$pid" >/dev/null 2>&1 || kill -TERM "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$PID_FILE"
  fi
  sleep 1
  status_push
}

status_push() {
  echo "session=$SESSION"
  if command -v screen >/dev/null 2>&1; then
    screen -ls | grep -F ".$SESSION" || true
  fi
  if [[ -f "$PID_FILE" ]]; then
    echo "pid=$(cat "$PID_FILE")"
    ps -p "$(cat "$PID_FILE")" -o pid,ppid,pgid,stat,comm,args || true
  fi
  pgrep -af 'gst-launch-1.0.*rtmpsink|start_openrd_cloud_rtmp.sh run' || true
  echo "log=$LOG_FILE"
  if [[ -f "$LOG_FILE" ]]; then
    tail -n 30 "$LOG_FILE"
  fi
}

command=${1:-}
case "$command" in
  start) start_push ;;
  stop) stop_push ;;
  restart) stop_push; start_push ;;
  status) status_push ;;
  pipeline) pipeline_text ;;
  run) run_pipeline ;;
  -h|--help|help) usage ;;
  *)
    usage
    exit 2
    ;;
esac
