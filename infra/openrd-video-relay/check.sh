#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-127.0.0.1}"
HTTP_PORT="${ZLM_HTTP_PORT:-8888}"

echo "== OpenRD video relay check =="
echo "host=${HOST}"
echo "http_port=${HTTP_PORT}"
echo

if [[ "${HOST}" == "127.0.0.1" || "${HOST}" == "localhost" ]]; then
  zlm_dir="${ZLM_DIR:-/home/ubuntu/ZLMediaKit/release/linux/Release}"

  echo "== MediaServer process =="
  ps -eo pid,user,comm,args | grep -E '[M]ediaServer|[s]creen -S media-server' || true
  echo

  if [[ -f "${zlm_dir}/config.ini" ]]; then
    echo "== Recording-related config =="
    grep -n '^enable_hls=' "${zlm_dir}/config.ini" || true
    grep -n '^enable_hls_fmp4=' "${zlm_dir}/config.ini" || true
    grep -n '^enable_mp4=' "${zlm_dir}/config.ini" || true
    grep -n '^hls_demand=' "${zlm_dir}/config.ini" || true
    grep -n '^mp4_as_player=' "${zlm_dir}/config.ini" || true
    grep -n '^segNum=' "${zlm_dir}/config.ini" || true
    grep -n '^segRetain=' "${zlm_dir}/config.ini" || true
    grep -n '^segKeep=' "${zlm_dir}/config.ini" || true
    echo

    echo "== Media files under www/log =="
    find "${zlm_dir}/www" "${zlm_dir}/log" -maxdepth 6 -type f \
      \( -iname '*.mp4' -o -iname '*.ts' -o -iname '*.m3u8' -o -iname '*.flv' -o -iname '*.h264' -o -iname '*.h265' \) \
      -printf '%s %p\n' 2>/dev/null | sort -nr | head -n 40
    echo
  fi

  echo "== Listening media ports =="
  if command -v ss >/dev/null 2>&1; then
    ss -lntup 2>/dev/null | grep -E ':(554|1935|8888|9000|10000)\b' || true
  else
    netstat -lntup 2>/dev/null | grep -E ':(554|1935|8888|9000|10000)\b' || true
  fi
  echo
fi

echo "== HTTP probe =="
curl -fsS -I --max-time 5 "http://${HOST}:${HTTP_PORT}/" || true
echo

echo "== Candidate endpoints =="
echo "RTMP ingest:     rtmp://${HOST}:1935/live/openrd"
echo "HTTP-FLV play:   http://${HOST}:${HTTP_PORT}/live/openrd.live.flv"
echo "HLS play:        disabled by config to avoid disk segment generation"
echo "RTSP play:       rtsp://${HOST}/live/openrd"
