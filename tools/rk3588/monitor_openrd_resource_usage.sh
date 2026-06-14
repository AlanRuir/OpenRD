#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}
NATIVE_DIR=${NATIVE_DIR:-"$PROJECT_DIR/vehicle/native_video"}
OUT_DIR=${OUT_DIR:-"$NATIVE_DIR/run/monitor"}

DURATION_SEC=${DURATION_SEC:-1200}
INTERVAL_SEC=${INTERVAL_SEC:-5}
RTSP_CHECK_INTERVAL_SEC=${RTSP_CHECK_INTERVAL_SEC:-30}
WEBRTC_CHECK_INTERVAL_SEC=${WEBRTC_CHECK_INTERVAL_SEC:-30}
RAW_SNAPSHOT_INTERVAL_SEC=${RAW_SNAPSHOT_INTERVAL_SEC:-30}
FRAME_TIMEOUT_SEC=${FRAME_TIMEOUT_SEC:-8}

RTSP_URL=${RTSP_URL:-rtsp://127.0.0.1:8554/live}
WEBRTC_URL=${WEBRTC_URL:-http://127.0.0.1:8889/live/}
SERVICE_NAMES=${SERVICE_NAMES:-openrd-video-native.service mediamtx.service}
PID_FILE=${PID_FILE:-"$NATIVE_DIR/run/openrd-video-native.pid"}

usage() {
  cat <<'EOF'
Monitor OpenRD RK3588 video resource usage.

Default run:
  DURATION_SEC=1200 INTERVAL_SEC=5 ./monitor_openrd_resource_usage.sh

Environment:
  DURATION_SEC                  Total monitor duration, default 1200.
  INTERVAL_SEC                  Resource sample interval, default 5.
  RTSP_CHECK_INTERVAL_SEC       RTSP frame probe interval, default 30.
  WEBRTC_CHECK_INTERVAL_SEC     HTTP page probe interval, default 30.
  RAW_SNAPSHOT_INTERVAL_SEC     Raw ps/MPP snapshot interval, default 30.
  OUT_DIR                       Output directory.
  RTSP_URL                      RTSP URL, default rtsp://127.0.0.1:8554/live.
  WEBRTC_URL                    WebRTC page URL, default http://127.0.0.1:8889/live/.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

validate_positive_int() {
  local name=$1
  local value=$2
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value <= 0 )); then
    echo "$name must be a positive integer: $value" >&2
    exit 2
  fi
}

validate_positive_int DURATION_SEC "$DURATION_SEC"
validate_positive_int INTERVAL_SEC "$INTERVAL_SEC"
validate_positive_int RTSP_CHECK_INTERVAL_SEC "$RTSP_CHECK_INTERVAL_SEC"
validate_positive_int WEBRTC_CHECK_INTERVAL_SEC "$WEBRTC_CHECK_INTERVAL_SEC"
validate_positive_int RAW_SNAPSHOT_INTERVAL_SEC "$RAW_SNAPSHOT_INTERVAL_SEC"
validate_positive_int FRAME_TIMEOUT_SEC "$FRAME_TIMEOUT_SEC"

mkdir -p "$OUT_DIR"

run_id=$(date +%Y%m%d-%H%M%S)
csv="$OUT_DIR/resource-$run_id.csv"
raw_log="$OUT_DIR/resource-$run_id.raw.log"
summary="$OUT_DIR/resource-$run_id.summary.txt"

csv_field() {
  local value=${1:-}
  value=${value//\"/\"\"}
  value=${value//$'\r'/}
  value=${value//$'\n'/;}
  printf '"%s"' "$value"
}

csv_row() {
  local first=1
  local field
  for field in "$@"; do
    if (( first )); then
      first=0
    else
      printf ','
    fi
    csv_field "$field"
  done
  printf '\n'
}

one_line() {
  local value=${1:-}
  value=${value//$'\r'/}
  value=${value//$'\n'/;}
  value=${value//,/ }
  printf '%s' "$value"
}

read_first_line() {
  local path=$1
  [[ -r "$path" ]] || return 0
  head -n 1 "$path" 2>/dev/null || true
}

join_by_pipe() {
  local IFS='|'
  echo "$*"
}

json_value() {
  local json=$1
  local key=$2
  printf '%s\n' "$json" |
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p; s/.*\"$key\"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p" |
    head -n 1
}

video_status_json() {
  if [[ -x "$NATIVE_DIR/openrd-video-native" ]]; then
    (cd "$NATIVE_DIR" && ./openrd-video-native status --json 2>/dev/null) || true
  fi
}

service_states() {
  local states=()
  local service
  for service in $SERVICE_NAMES; do
    states+=("$service=$(systemctl is-active "$service" 2>/dev/null || true)")
  done
  join_by_pipe "${states[@]}"
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
  if ! command -v curl >/dev/null 2>&1; then
    echo missing-curl
    return 0
  fi

  curl -L -s -o /dev/null -w '%{http_code}' --max-time 4 "$WEBRTC_URL" 2>/dev/null || echo curl-fail
}

declare -A PREV_CPU_IDLE=()
declare -A PREV_CPU_TOTAL=()

read_cpu_lines() {
  awk '
    /^cpu[0-9]*/ {
      idle=$5+$6
      total=0
      for (i=2; i<=9; i++) total+=$i
      print $1 ":" idle ":" total
    }
  ' /proc/stat
}

prime_cpu_sample() {
  local id idle total
  while IFS=: read -r id idle total; do
    [[ -n "$id" ]] || continue
    PREV_CPU_IDLE["$id"]=$idle
    PREV_CPU_TOTAL["$id"]=$total
  done < <(read_cpu_lines)
}

cpu_sample() {
  local id idle total prev_idle prev_total total_delta idle_delta busy_delta pct
  local overall=""
  local cores=()

  while IFS=: read -r id idle total; do
    [[ -n "$id" ]] || continue
    prev_idle=${PREV_CPU_IDLE[$id]:-$idle}
    prev_total=${PREV_CPU_TOTAL[$id]:-$total}
    total_delta=$((total - prev_total))
    idle_delta=$((idle - prev_idle))
    busy_delta=$((total_delta - idle_delta))
    if (( total_delta <= 0 )); then
      pct=""
    else
      pct=$(awk -v busy="$busy_delta" -v total="$total_delta" 'BEGIN { printf "%.1f", busy * 100 / total }')
    fi

    if [[ "$id" == "cpu" ]]; then
      overall=$pct
    else
      cores+=("$id=$pct")
    fi

    PREV_CPU_IDLE["$id"]=$idle
    PREV_CPU_TOTAL["$id"]=$total
  done < <(read_cpu_lines)

  printf '%s,%s\n' "$overall" "$(join_by_pipe "${cores[@]}")"
}

load_average() {
  awk '{ printf "%s|%s|%s", $1, $2, $3 }' /proc/loadavg
}

mem_sample() {
  awk '
    /^MemTotal:/ { mt=$2 }
    /^MemAvailable:/ { ma=$2 }
    /^SwapTotal:/ { st=$2 }
    /^SwapFree:/ { sf=$2 }
    END {
      used=mt-ma
      mem_pct=(mt > 0) ? used * 100 / mt : 0
      su=st-sf
      swap_pct=(st > 0) ? su * 100 / st : 0
      printf "%d,%d,%d,%.1f,%d,%d,%d,%.1f", mt, ma, used, mem_pct, st, sf, su, swap_pct
    }
  ' /proc/meminfo
}

thermal_sample() {
  local max=0
  local values=()
  local zone type temp label
  for zone in /sys/class/thermal/thermal_zone*; do
    [[ -r "$zone/temp" ]] || continue
    type=$(read_first_line "$zone/type")
    temp=$(read_first_line "$zone/temp")
    [[ "$temp" =~ ^-?[0-9]+$ ]] || continue
    label=${type:-$(basename "$zone")}
    label=${label// /_}
    values+=("$label=$temp")
    if (( temp > max )); then
      max=$temp
    fi
  done
  printf '%s,%s\n' "$max" "$(join_by_pipe "${values[@]}")"
}

cpu_freq_sample() {
  local values=()
  local policy related freq governor label
  for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [[ -d "$policy" ]] || continue
    related=$(read_first_line "$policy/related_cpus")
    related=${related// /-}
    freq=$(read_first_line "$policy/scaling_cur_freq")
    governor=$(read_first_line "$policy/scaling_governor")
    label="$(basename "$policy")"
    [[ -n "$related" ]] && label="$label($related)"
    values+=("$label=${freq:-na}kHz:${governor:-na}")
  done
  join_by_pipe "${values[@]}"
}

devfreq_sample() {
  local values=()
  local dev name freq load governor
  for dev in /sys/class/devfreq/*; do
    [[ -e "$dev" ]] || continue
    [[ -r "$dev/name" ]] || continue
    name=$(read_first_line "$dev/name")
    freq=$(read_first_line "$dev/cur_freq")
    load=$(read_first_line "$dev/load")
    governor=$(read_first_line "$dev/governor")
    values+=("${name:-$(basename "$dev")}:freq=${freq:-na}:load=${load:-na}:gov=${governor:-na}")
  done
  join_by_pipe "${values[@]}"
}

process_metrics() {
  local pid=${1:-}
  if [[ -z "$pid" || ! -d "/proc/$pid" ]]; then
    echo ",,,"
    return 0
  fi

  ps -p "$pid" -o %cpu=,%mem=,rss=,comm= 2>/dev/null |
    awk 'NR == 1 { printf "%s,%s,%s,%s", $1, $2, $3, $4 }'
}

pipeline_pid() {
  local parent=${1:-}
  local pid=""
  if [[ -n "$parent" ]]; then
    pid=$(pgrep -P "$parent" -x gst-launch-1.0 2>/dev/null | head -n 1 || true)
  fi
  if [[ -z "$pid" ]]; then
    pid=$(pgrep -f 'gst-launch-1.0 .*rtspclientsink.*127.0.0.1:8554/live' 2>/dev/null | head -n 1 || true)
  fi
  echo "$pid"
}

mpp_first_numeric() {
  local path=$1
  local value
  value=$(read_first_line "$path")
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    echo "$value"
  fi
}

mpp_rkvenc_fps() {
  local path=$1
  [[ -r "$path" ]] || return 0
  awk -F'|' '/RKVENC/ { gsub(/[[:space:]]/, "", $12); print $12; exit }' "$path" 2>/dev/null || true
}

mpp_sample() {
  local jpegd_aclk jpegd_buffers rkvenc0_aclk rkvenc0_core rkvenc0_tasks rkvenc0_fps
  local rkvenc1_aclk rkvenc1_core rkvenc1_tasks rkvenc1_fps rkvdec0_tasks rkvdec1_tasks
  jpegd_aclk=$(mpp_first_numeric /proc/mpp_service/jpegd/aclk)
  jpegd_buffers=$(mpp_first_numeric /proc/mpp_service/jpegd/session_buffers)
  rkvenc0_aclk=$(mpp_first_numeric /proc/mpp_service/rkvenc-core0/aclk)
  rkvenc0_core=$(mpp_first_numeric /proc/mpp_service/rkvenc-core0/clk_core)
  rkvenc0_tasks=$(mpp_first_numeric /proc/mpp_service/rkvenc-core0/task_count)
  rkvenc0_fps=$(mpp_rkvenc_fps /proc/mpp_service/rkvenc-core0/sessions-info)
  rkvenc1_aclk=$(mpp_first_numeric /proc/mpp_service/rkvenc-core1/aclk)
  rkvenc1_core=$(mpp_first_numeric /proc/mpp_service/rkvenc-core1/clk_core)
  rkvenc1_tasks=$(mpp_first_numeric /proc/mpp_service/rkvenc-core1/task_count)
  rkvenc1_fps=$(mpp_rkvenc_fps /proc/mpp_service/rkvenc-core1/sessions-info)
  rkvdec0_tasks=$(mpp_first_numeric /proc/mpp_service/rkvdec-core0/task_count)
  rkvdec1_tasks=$(mpp_first_numeric /proc/mpp_service/rkvdec-core1/task_count)

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$jpegd_aclk" "$jpegd_buffers" \
    "$rkvenc0_aclk" "$rkvenc0_core" "$rkvenc0_tasks" "$rkvenc0_fps" \
    "$rkvenc1_aclk" "$rkvenc1_core" "$rkvenc1_tasks" "$rkvenc1_fps" \
    "$rkvdec0_tasks" "$rkvdec1_tasks"
}

raw_snapshot() {
  local ts=$1
  local service_pid=$2
  local gst_pid=$3
  {
    echo "===== $ts ====="
    echo "--- services ---"
    for service in $SERVICE_NAMES; do
      printf '%s=' "$service"
      systemctl is-active "$service" 2>/dev/null || true
    done
    echo "--- process tree ---"
    ps -eo pid,ppid,pgid,comm,%cpu,%mem,rss,args |
      awk -v svc="$service_pid" -v gst="$gst_pid" '
        NR == 1 { print; next }
        $1 == svc || $2 == svc || $1 == gst || $2 == gst || $8 ~ /openrd-video-native|gst-launch-1.0|mediamtx/ { print }
      ' || true
    echo "--- top cpu ---"
    ps -eo pid,ppid,comm,%cpu,%mem,rss,args --sort=-%cpu | head -n 12 || true
    echo "--- meminfo ---"
    grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo || true
    echo "--- thermal ---"
    for zone in /sys/class/thermal/thermal_zone*; do
      [[ -r "$zone/temp" ]] || continue
      printf '%s type=%s temp=%s\n' "$zone" "$(read_first_line "$zone/type")" "$(read_first_line "$zone/temp")"
    done
    echo "--- devfreq ---"
    for dev in /sys/class/devfreq/*; do
      [[ -e "$dev" && -r "$dev/name" ]] || continue
      printf '%s name=%s cur_freq=%s load=%s governor=%s\n' \
        "$dev" "$(read_first_line "$dev/name")" "$(read_first_line "$dev/cur_freq")" \
        "$(read_first_line "$dev/load")" "$(read_first_line "$dev/governor")"
    done
    echo "--- mpp sessions summary ---"
    cat /proc/mpp_service/sessions-summary 2>/dev/null || true
    echo "--- mpp jpegd ---"
    for f in /proc/mpp_service/jpegd/aclk /proc/mpp_service/jpegd/session_buffers /proc/mpp_service/jpegd/timing_check; do
      [[ -r "$f" ]] && printf '%s=%s\n' "$f" "$(one_line "$(cat "$f" 2>/dev/null || true)")"
    done
    echo "--- mpp rkvenc ---"
    for f in /proc/mpp_service/rkvenc-core0/sessions-info /proc/mpp_service/rkvenc-core1/sessions-info; do
      [[ -r "$f" ]] && { echo "### $f"; cat "$f" 2>/dev/null || true; }
    done
    echo
  } >> "$raw_log"
}

start_epoch=$(date +%s)
end_epoch=$((start_epoch + DURATION_SEC))
next_rtsp_check=$start_epoch
next_webrtc_check=$start_epoch
next_raw_snapshot=$start_epoch
last_rtsp_frame=not-checked
last_webrtc_http=not-checked

cat > "$summary" <<EOF
run_id=$run_id
start=$(date -Is)
duration_sec=$DURATION_SEC
interval_sec=$INTERVAL_SEC
rtsp_check_interval_sec=$RTSP_CHECK_INTERVAL_SEC
webrtc_check_interval_sec=$WEBRTC_CHECK_INTERVAL_SEC
raw_snapshot_interval_sec=$RAW_SNAPSHOT_INTERVAL_SEC
rtsp_url=$RTSP_URL
webrtc_url=$WEBRTC_URL
services=$SERVICE_NAMES
csv=$csv
raw_log=$raw_log
EOF

csv_row \
  ts elapsed_sec service_states video_state video_runtime_running video_message input_format mjpeg_decoder \
  service_pid pipeline_pid cpu_total_pct cpu_core_pct load_avg \
  mem_total_kb mem_available_kb mem_used_kb mem_used_pct swap_total_kb swap_free_kb swap_used_kb swap_used_pct \
  max_temp_mC thermal_mC cpu_freq_kHz devfreq \
  service_cpu_pct service_mem_pct service_rss_kb service_comm pipeline_cpu_pct pipeline_mem_pct pipeline_rss_kb pipeline_comm \
  rtsp_frame webrtc_http \
  mpp_jpegd_aclk mpp_jpegd_session_buffers \
  mpp_rkvenc0_aclk mpp_rkvenc0_clk_core mpp_rkvenc0_task_count mpp_rkvenc0_fps_calc \
  mpp_rkvenc1_aclk mpp_rkvenc1_clk_core mpp_rkvenc1_task_count mpp_rkvenc1_fps_calc \
  mpp_rkvdec0_task_count mpp_rkvdec1_task_count \
  > "$csv"

echo "resource monitor started: $run_id"
echo "csv: $csv"
echo "raw_log: $raw_log"
echo "summary: $summary"

prime_cpu_sample
sleep "$INTERVAL_SEC"

samples=0
rtsp_failures=0
service_inactive_samples=0

while (( $(date +%s) <= end_epoch )); do
  now_epoch=$(date +%s)
  ts=$(date -Is)
  elapsed=$((now_epoch - start_epoch))

  status_json=$(video_status_json)
  video_state=$(json_value "$status_json" state)
  runtime_running=$(json_value "$status_json" runtime_running)
  video_message=$(json_value "$status_json" message)
  input_format=$(json_value "$status_json" input_format)
  mjpeg_decoder=$(json_value "$status_json" mjpeg_decoder)
  service_pid=$(json_value "$status_json" pid)
  [[ -z "$service_pid" || "$service_pid" == "0" ]] && service_pid=$(cat "$PID_FILE" 2>/dev/null || true)
  gst_pid=$(pipeline_pid "$service_pid")

  states=$(service_states)
  if [[ "$states" == *"=inactive"* || "$states" == *"=failed"* ]]; then
    service_inactive_samples=$((service_inactive_samples + 1))
  fi

  if (( now_epoch >= next_rtsp_check )); then
    last_rtsp_frame=$(rtsp_frame_check)
    next_rtsp_check=$((now_epoch + RTSP_CHECK_INTERVAL_SEC))
    [[ "$last_rtsp_frame" == "fail" ]] && rtsp_failures=$((rtsp_failures + 1))
  fi

  if (( now_epoch >= next_webrtc_check )); then
    last_webrtc_http=$(http_check)
    next_webrtc_check=$((now_epoch + WEBRTC_CHECK_INTERVAL_SEC))
  fi

  cpu_csv=$(cpu_sample)
  cpu_total=${cpu_csv%%,*}
  cpu_cores=${cpu_csv#*,}
  load_avg=$(load_average)
  mem_csv=$(mem_sample)
  thermal_csv=$(thermal_sample)
  max_temp=${thermal_csv%%,*}
  thermal_values=${thermal_csv#*,}
  cpu_freq=$(cpu_freq_sample)
  devfreq=$(devfreq_sample)
  service_proc_csv=$(process_metrics "$service_pid")
  pipeline_proc_csv=$(process_metrics "$gst_pid")
  mpp_csv=$(mpp_sample)

  IFS=, read -r mem_total mem_available mem_used mem_used_pct swap_total swap_free swap_used swap_used_pct <<< "$mem_csv"
  IFS=, read -r service_cpu service_mem service_rss service_comm <<< "$service_proc_csv"
  IFS=, read -r pipeline_cpu pipeline_mem pipeline_rss pipeline_comm <<< "$pipeline_proc_csv"
  IFS=, read -r \
    mpp_jpegd_aclk mpp_jpegd_buffers \
    mpp_rkvenc0_aclk mpp_rkvenc0_core mpp_rkvenc0_tasks mpp_rkvenc0_fps \
    mpp_rkvenc1_aclk mpp_rkvenc1_core mpp_rkvenc1_tasks mpp_rkvenc1_fps \
    mpp_rkvdec0_tasks mpp_rkvdec1_tasks <<< "$mpp_csv"

  csv_row \
    "$ts" "$elapsed" "$states" "$video_state" "$runtime_running" "$video_message" "$input_format" "$mjpeg_decoder" \
    "$service_pid" "$gst_pid" "$cpu_total" "$cpu_cores" "$load_avg" \
    "$mem_total" "$mem_available" "$mem_used" "$mem_used_pct" "$swap_total" "$swap_free" "$swap_used" "$swap_used_pct" \
    "$max_temp" "$thermal_values" "$cpu_freq" "$devfreq" \
    "$service_cpu" "$service_mem" "$service_rss" "$service_comm" "$pipeline_cpu" "$pipeline_mem" "$pipeline_rss" "$pipeline_comm" \
    "$last_rtsp_frame" "$last_webrtc_http" \
    "$mpp_jpegd_aclk" "$mpp_jpegd_buffers" \
    "$mpp_rkvenc0_aclk" "$mpp_rkvenc0_core" "$mpp_rkvenc0_tasks" "$mpp_rkvenc0_fps" \
    "$mpp_rkvenc1_aclk" "$mpp_rkvenc1_core" "$mpp_rkvenc1_tasks" "$mpp_rkvenc1_fps" \
    "$mpp_rkvdec0_tasks" "$mpp_rkvdec1_tasks" \
    >> "$csv"

  if (( now_epoch >= next_raw_snapshot )); then
    raw_snapshot "$ts" "$service_pid" "$gst_pid"
    next_raw_snapshot=$((now_epoch + RAW_SNAPSHOT_INTERVAL_SEC))
  fi

  samples=$((samples + 1))
  printf '[%s] elapsed=%ss cpu=%s%% mem=%s%% temp=%smC gst_pid=%s gst_cpu=%s%% rtsp=%s http=%s decoder=%s\n' \
    "$ts" "$elapsed" "$cpu_total" "$mem_used_pct" "$max_temp" "${gst_pid:-}" "${pipeline_cpu:-}" "$last_rtsp_frame" "$last_webrtc_http" "${mjpeg_decoder:-}" 

  sleep "$INTERVAL_SEC"
done

{
  echo "end=$(date -Is)"
  echo "samples=$samples"
  echo "rtsp_failures=$rtsp_failures"
  echo "service_inactive_samples=$service_inactive_samples"
  echo "csv=$csv"
  echo "raw_log=$raw_log"
} >> "$summary"

echo "resource monitor finished: $run_id"
cat "$summary"
