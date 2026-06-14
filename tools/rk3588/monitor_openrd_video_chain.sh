#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}
NATIVE_DIR=${NATIVE_DIR:-"$PROJECT_DIR/vehicle/native_video"}
OUT_DIR=${OUT_DIR:-"$PROJECT_DIR/vehicle/native_video/run/monitor"}
DURATION_SEC=${DURATION_SEC:-600}
INTERVAL_SEC=${INTERVAL_SEC:-10}
RTSP_URL=${RTSP_URL:-rtsp://127.0.0.1:8554/live}
WEBRTC_URL=${WEBRTC_URL:-http://127.0.0.1:8889/live/}
FRAME_TIMEOUT_SEC=${FRAME_TIMEOUT_SEC:-8}
SERVICE_NAMES=${SERVICE_NAMES:-openrd-video-native.service mediamtx.service rkaiq_3A.service}
KERNEL_PATTERNS=${KERNEL_PATTERNS:-rkcif|rkisp_stream_stop|not active buffer|start stream failed|write regs|timeout|failed}

mkdir -p "$OUT_DIR"

run_id=$(date +%Y%m%d-%H%M%S)
csv="$OUT_DIR/video-chain-$run_id.csv"
events="$OUT_DIR/video-chain-$run_id.events.log"
summary="$OUT_DIR/video-chain-$run_id.summary.txt"
native_log="$NATIVE_DIR/run/openrd-video-native.log"

json_value() {
  local json=$1
  local key=$2
  printf '%s\n' "$json" |
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p; s/.*\"$key\"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p" |
    head -n 1
}

read_video_status() {
  if [[ -x "$NATIVE_DIR/openrd-video-native" ]]; then
    (cd "$NATIVE_DIR" && ./openrd-video-native status --json 2>/dev/null) || true
  fi
}

rtsp_frame_check() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo missing-ffmpeg
    return 0
  fi

  if timeout "${FRAME_TIMEOUT_SEC}s" ffmpeg -nostdin -hide_banner -loglevel error \
    -rtsp_transport tcp -i "$RTSP_URL" -map 0:v:0 -frames:v 1 -f null - >/dev/null 2>&1; then
    echo ok
  else
    echo fail
  fi
}

http_check() {
  local url=$1
  if ! command -v curl >/dev/null 2>&1; then
    echo missing-curl
    return 0
  fi

  curl -L -s -o /dev/null -w '%{http_code}' --max-time 4 "$url" 2>/dev/null || echo curl-fail
}

service_active_csv() {
  local output=()
  local service
  for service in $SERVICE_NAMES; do
    output+=("$(systemctl is-active "$service" 2>/dev/null || true)")
  done
  local IFS='|'
  echo "${output[*]}"
}

service_enabled_csv() {
  local output=()
  local service
  for service in $SERVICE_NAMES; do
    output+=("$(systemctl is-enabled "$service" 2>/dev/null || true)")
  done
  local IFS='|'
  echo "${output[*]}"
}

recent_native_events() {
  if [[ -f "$native_log" ]]; then
    local first_line=$((native_log_start_line + 1))
    tail -n +"$first_line" "$native_log" |
      grep -E 'health check failed|restarting video runtime|restarting camera engine|Could not connect|The server closed|Starting recording|starting OpenRD native video runtime' || true
  fi
}

collect_snapshot_logs() {
  local since=$1
  {
    echo "===== systemctl status $(date -Is) ====="
    systemctl --no-pager --full status openrd-video-native.service mediamtx.service rkaiq_3A.service || true
    echo
    echo "===== mediamtx since $since ====="
    journalctl -u mediamtx.service --no-pager --since "$since" || true
    echo
    echo "===== openrd-video-native service since $since ====="
    journalctl -u openrd-video-native.service --no-pager --since "$since" || true
    echo
    echo "===== rkaiq_3A since $since ====="
    journalctl -u rkaiq_3A.service --no-pager --since "$since" || true
    echo
    echo "===== kernel camera events since $since ====="
    journalctl -k --no-pager --since "$since" | grep -Ei "$KERNEL_PATTERNS" || true
    echo
    echo "===== native log tail ====="
    tail -n 240 "$native_log" 2>/dev/null || true
  } > "$OUT_DIR/video-chain-$run_id.logs.txt"
}

start_epoch=$(date +%s)
end_epoch=$((start_epoch + DURATION_SEC))
start_iso=$(date -Is)
start_journal=$(date '+%F %T')
native_log_start_line=0
if [[ -f "$native_log" ]]; then
  native_log_start_line=$(wc -l < "$native_log" 2>/dev/null || echo 0)
fi

cat > "$summary" <<EOF
run_id=$run_id
start=$start_iso
duration_sec=$DURATION_SEC
interval_sec=$INTERVAL_SEC
rtsp_url=$RTSP_URL
webrtc_url=$WEBRTC_URL
frame_timeout_sec=$FRAME_TIMEOUT_SEC
services=$SERVICE_NAMES
service_enabled=$(service_enabled_csv)
csv=$csv
events=$events
EOF

echo 'ts,elapsed_sec,services_active,video_pid,video_state,video_runtime_running,video_message,rtsp_frame,webrtc_http,native_events_since_start,kernel_camera_events_lookback' > "$csv"

echo "monitor started: $run_id" | tee -a "$events"
echo "csv: $csv" | tee -a "$events"
echo "events: $events" | tee -a "$events"

while (( $(date +%s) <= end_epoch )); do
  now_epoch=$(date +%s)
  ts=$(date -Is)
  elapsed=$((now_epoch - start_epoch))
  services=$(service_active_csv)
  status_json=$(read_video_status)
  video_pid=$(json_value "$status_json" pid)
  video_state=$(json_value "$status_json" state)
  runtime_running=$(json_value "$status_json" runtime_running)
  video_message=$(json_value "$status_json" message)
  rtsp_frame=$(rtsp_frame_check)
  webrtc_http=$(http_check "$WEBRTC_URL")
  native_events=$(recent_native_events | tail -n 8 | tr '\n' ';' | sed 's/,/ /g')
  kernel_events=$(journalctl -k --no-pager --since '-30 seconds' 2>/dev/null | grep -Ei "$KERNEL_PATTERNS" | tail -n 8 | tr '\n' ';' | sed 's/,/ /g' || true)

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$elapsed" "$services" "${video_pid:-}" "${video_state:-}" "${runtime_running:-}" \
    "${video_message:-}" "$rtsp_frame" "$webrtc_http" "$native_events" "$kernel_events" >> "$csv"

  if [[ "$rtsp_frame" != ok || "$services" != active\|active\|active || -n "$kernel_events" ]]; then
    {
      echo "[$ts] services=$services pid=${video_pid:-} state=${video_state:-} msg=${video_message:-} rtsp_frame=$rtsp_frame webrtc_http=$webrtc_http"
      if [[ -n "$kernel_events" ]]; then
        echo "  kernel: $kernel_events"
      fi
      if [[ -n "$native_events" ]]; then
        echo "  native: $native_events"
      fi
    } | tee -a "$events"
  fi

  sleep "$INTERVAL_SEC"
done

collect_snapshot_logs "$start_journal"

{
  echo "end=$(date -Is)"
  echo "samples=$(($(wc -l < "$csv") - 1))"
  echo "rtsp_frame_failures=$(grep -c ',fail,' "$csv" || true)"
  echo "native_event_samples=$(awk -F, 'NR > 1 && length($10) > 0 { count++ } END { print count + 0 }' "$csv")"
  echo "kernel_event_samples=$(awk -F, 'NR > 1 && length($11) > 0 { count++ } END { print count + 0 }' "$csv")"
  echo "logs=$OUT_DIR/video-chain-$run_id.logs.txt"
} >> "$summary"

echo "monitor finished: $run_id"
cat "$summary"
