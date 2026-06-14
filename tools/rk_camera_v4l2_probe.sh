#!/usr/bin/env bash
set -Eeuo pipefail

ITERATIONS=${OPENRD_CAMERA_PROBE_ITERATIONS:-10}
WIDTH=${OPENRD_CAMERA_PROBE_WIDTH:-1280}
HEIGHT=${OPENRD_CAMERA_PROBE_HEIGHT:-720}
PIXEL_FORMAT=${OPENRD_CAMERA_PROBE_PIXEL_FORMAT:-NV12}
STREAM_COUNT=${OPENRD_CAMERA_PROBE_STREAM_COUNT:-30}
TIMEOUT_SEC=${OPENRD_CAMERA_PROBE_TIMEOUT_SEC:-12}
SLEEP_SEC=${OPENRD_CAMERA_PROBE_SLEEP_SEC:-2}
STOP_SERVICE=${OPENRD_CAMERA_PROBE_STOP_SERVICE:-1}
RESTART_RKAIQ_EACH_ITER=${OPENRD_CAMERA_PROBE_RESTART_RKAIQ_EACH_ITER:-0}
KEEP_RAW=${OPENRD_CAMERA_PROBE_KEEP_RAW:-0}
ORDER=${OPENRD_CAMERA_PROBE_ORDER:-alternate}
OUT_DIR=${OPENRD_CAMERA_PROBE_OUT_DIR:-/tmp/openrd-camera-probe-$(date +%Y%m%d-%H%M%S)}

DEV_A=${OPENRD_CAMERA_PROBE_DEV_A:-/dev/video22}
DEV_B=${OPENRD_CAMERA_PROBE_DEV_B:-/dev/video31}
DMSG_PATTERN='imx|rkisp|csi|mipi|v4l2|video|rkcif|rkaiq'

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.csv"

echo "iteration,device,rc,status,bytes,frames_seen,duration_ms,raw_file,stream_log,dmesg_log" > "$SUMMARY"

require_command() {
  command -v "$1" >/dev/null || {
    echo "missing required command: $1" >&2
    exit 2
  }
}

ms_now() {
  date +%s%3N
}

device_order_for_iteration() {
  local iter=$1
  case "$ORDER" in
    video22-first|22-first)
      printf '%s\n%s\n' "$DEV_A" "$DEV_B"
      ;;
    video31-first|31-first)
      printf '%s\n%s\n' "$DEV_B" "$DEV_A"
      ;;
    alternate)
      if (( iter % 2 == 1 )); then
        printf '%s\n%s\n' "$DEV_A" "$DEV_B"
      else
        printf '%s\n%s\n' "$DEV_B" "$DEV_A"
      fi
      ;;
    *)
      echo "unknown OPENRD_CAMERA_PROBE_ORDER: $ORDER" >&2
      exit 2
      ;;
  esac
}

classify_result() {
  local rc=$1
  local bytes=$2
  local frames_seen=$3

  if (( rc == 0 && frames_seen >= STREAM_COUNT && bytes > 0 )); then
    echo "ok"
  elif (( frames_seen > 0 || bytes > 0 )); then
    echo "partial"
  elif (( rc == 124 )); then
    echo "timeout_no_frame"
  else
    echo "failed"
  fi
}

probe_device() {
  local iter=$1
  local dev=$2
  local label
  label=$(basename "$dev")
  local raw_file="$OUT_DIR/iter-${iter}-${label}.raw"
  local stream_log="$OUT_DIR/iter-${iter}-${label}.stream.log"
  local dmesg_log="$OUT_DIR/iter-${iter}-${label}.dmesg.log"
  local dmesg_before
  local started_ms ended_ms duration_ms rc bytes frames_seen status

  dmesg_before=$(dmesg | wc -l)
  started_ms=$(ms_now)

  set +e
  timeout "${TIMEOUT_SEC}s" v4l2-ctl -d "$dev" \
    --set-fmt-video="width=${WIDTH},height=${HEIGHT},pixelformat=${PIXEL_FORMAT}" \
    --stream-mmap \
    --stream-count="$STREAM_COUNT" \
    --stream-to="$raw_file" >"$stream_log" 2>&1
  rc=$?
  set -e

  ended_ms=$(ms_now)
  duration_ms=$((ended_ms - started_ms))
  bytes=0
  if [[ -f "$raw_file" ]]; then
    bytes=$(stat -c '%s' "$raw_file")
  fi
  frames_seen=$(tr -cd '<' < "$stream_log" | wc -c)
  status=$(classify_result "$rc" "$bytes" "$frames_seen")

  dmesg | tail -n +"$((dmesg_before + 1))" | grep -Ei "$DMSG_PATTERN" >"$dmesg_log" || true

  if (( KEEP_RAW == 0 )); then
    rm -f "$raw_file"
    raw_file=""
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$iter" "$dev" "$rc" "$status" "$bytes" "$frames_seen" "$duration_ms" \
    "$raw_file" "$stream_log" "$dmesg_log" | tee -a "$SUMMARY"
}

require_command v4l2-ctl
require_command timeout
require_command dmesg
require_command stat

echo "OpenRD RK camera V4L2 probe"
echo "out_dir=$OUT_DIR"
echo "devices=$DEV_A,$DEV_B iterations=$ITERATIONS order=$ORDER"
echo "format=${WIDTH}x${HEIGHT}/${PIXEL_FORMAT} stream_count=$STREAM_COUNT timeout=${TIMEOUT_SEC}s"

if (( STOP_SERVICE == 1 )); then
  echo "stopping openrd-video-native.service"
  sudo systemctl stop openrd-video-native.service || true
fi

for iter in $(seq 1 "$ITERATIONS"); do
  echo "=== iteration $iter / $ITERATIONS $(date -Is) ==="

  if (( RESTART_RKAIQ_EACH_ITER == 1 )); then
    echo "restarting rkaiq_3A.service"
    sudo systemctl restart rkaiq_3A.service || true
    sleep "$SLEEP_SEC"
  fi

  while IFS= read -r dev; do
    if [[ ! -e "$dev" ]]; then
      echo "$iter,$dev,127,missing,0,0,0,,," | tee -a "$SUMMARY"
      continue
    fi
    probe_device "$iter" "$dev"
    sleep "$SLEEP_SEC"
  done < <(device_order_for_iteration "$iter")
done

echo "=== summary by device/status ==="
awk -F, 'NR > 1 { count[$2 "," $4] += 1 } END { for (key in count) print key "," count[key] }' "$SUMMARY" | sort
echo "summary_csv=$SUMMARY"
