#!/usr/bin/env bash
set -euo pipefail

CONFIG=${MEDIAMTX_CONFIG:-/usr/local/etc/mediamtx.yml}
PUBLISHER_PATH_NAME=${OPENRD_MEDIAMTX_PUBLISHER_PATH:-live}
FRONT_PUBLISHER_PATH_NAME=${OPENRD_MEDIAMTX_FRONT_PUBLISHER_PATH:-live-front}
REAR_PUBLISHER_PATH_NAME=${OPENRD_MEDIAMTX_REAR_PUBLISHER_PATH:-live-rear}
EXTRA_PUBLISHER_PATH_NAME=${OPENRD_MEDIAMTX_EXTRA_PUBLISHER_PATH:-openrd}
ENABLE_LEGACY_RTP_PATH=${OPENRD_MEDIAMTX_ENABLE_LEGACY_RTP_PATH:-false}
LEGACY_RTP_PATH_NAME=${OPENRD_MEDIAMTX_LEGACY_RTP_PATH:-live-rtp}
RTP_HOST=${OPENRD_MEDIAMTX_RTP_HOST:-127.0.0.1}
RTP_PORT=${OPENRD_MEDIAMTX_RTP_PORT:-5004}
RTP_PAYLOAD_TYPE=${OPENRD_MEDIAMTX_RTP_PAYLOAD_TYPE:-96}

default_webrtc_additional_hosts() {
  if [[ -n "${OPENRD_BOARD_IP:-}" ]]; then
    echo "$OPENRD_BOARD_IP"
    return 0
  fi

  local static_src
  static_src=$(ip -4 -o addr show scope global 2>/dev/null | awk '$0 !~ / dynamic / { split($4, addr, "/"); print addr[1]; exit }')
  if [[ -n "$static_src" ]]; then
    echo "$static_src"
    return 0
  fi

  local route_src
  route_src=$(ip route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
  if [[ -n "$route_src" ]]; then
    echo "$route_src"
    return 0
  fi

  hostname -I | tr ' ' '\n' | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print }' | paste -sd, -
}

WEBRTC_ADDITIONAL_HOSTS=${OPENRD_MEDIAMTX_WEBRTC_ADDITIONAL_HOSTS:-$(default_webrtc_additional_hosts)}

if [[ ! -f "$CONFIG" ]]; then
  echo "MediaMTX config not found: $CONFIG" >&2
  exit 1
fi

backup="$CONFIG.openrd.$(date +%Y%m%d-%H%M%S).bak"
tmp=$(mktemp)
declare -A added_paths=()

append_publisher_path() {
  local path_name=$1
  if [[ -z "$path_name" || -n "${added_paths[$path_name]:-}" ]]; then
    return
  fi

  added_paths[$path_name]=1
  cat >> "$tmp" <<EOF
  ${path_name}:
    source: publisher
EOF
}

cat > "$tmp" <<EOF
webrtcAllowOrigins: ['*']
webrtcIPsFromInterfaces: false
webrtcAdditionalHosts: [${WEBRTC_ADDITIONAL_HOSTS}]

paths:
EOF

append_publisher_path "$PUBLISHER_PATH_NAME"
append_publisher_path "$FRONT_PUBLISHER_PATH_NAME"
append_publisher_path "$REAR_PUBLISHER_PATH_NAME"
append_publisher_path "$EXTRA_PUBLISHER_PATH_NAME"

if [[ "$ENABLE_LEGACY_RTP_PATH" == true ]]; then
  cat >> "$tmp" <<EOF
  ${LEGACY_RTP_PATH_NAME}:
    source: udp+rtp://${RTP_HOST}:${RTP_PORT}
    rtpSDP: |
      v=0
      o=- 0 0 IN IP4 ${RTP_HOST}
      s=OpenRD H264 RTP Legacy Stream
      c=IN IP4 ${RTP_HOST}
      t=0 0
      m=video ${RTP_PORT} RTP/AVP ${RTP_PAYLOAD_TYPE}
      a=rtpmap:${RTP_PAYLOAD_TYPE} H264/90000
      a=fmtp:${RTP_PAYLOAD_TYPE} packetization-mode=1
EOF
fi

if cmp -s "$CONFIG" "$tmp"; then
  rm -f "$tmp"
  echo "MediaMTX config already matches OpenRD publisher mode: $CONFIG"
else
  sudo cp "$CONFIG" "$backup"
  sudo install -m 0644 "$tmp" "$CONFIG"
  rm -f "$tmp"
  echo "MediaMTX config updated for OpenRD publisher mode: $CONFIG"
  echo "Backup: $backup"
fi

sudo systemctl restart mediamtx.service
sleep 1
systemctl is-active mediamtx.service

echo "RTSP:   rtsp://127.0.0.1:8554/${PUBLISHER_PATH_NAME}"
echo "HLS:    http://127.0.0.1:8888/${PUBLISHER_PATH_NAME}/index.m3u8"
echo "WebRTC: http://127.0.0.1:8889/${PUBLISHER_PATH_NAME}"
echo "Reserved front path: rtsp://127.0.0.1:8554/${FRONT_PUBLISHER_PATH_NAME}"
echo "Reserved rear path:  rtsp://127.0.0.1:8554/${REAR_PUBLISHER_PATH_NAME}"
echo "WebRTC ICE additional hosts: ${WEBRTC_ADDITIONAL_HOSTS}"
