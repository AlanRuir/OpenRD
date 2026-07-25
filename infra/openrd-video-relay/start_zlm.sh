#!/usr/bin/env bash
set -euo pipefail

ZLM_DIR="${ZLM_DIR:-/home/ubuntu/ZLMediaKit/release/linux/Release}"
SESSION="${OPENRD_ZLM_SCREEN:-openrd-zlm}"

if [[ ! -x "${ZLM_DIR}/MediaServer" ]]; then
  echo "MediaServer not found: ${ZLM_DIR}/MediaServer" >&2
  exit 1
fi

sudo -n pkill -TERM -x MediaServer 2>/dev/null || true
screen -S "${SESSION}" -X quit 2>/dev/null || true
sleep 1

screen -dmS "${SESSION}" bash -lc "cd '${ZLM_DIR}' && exec sudo -n ./MediaServer -c config.ini"
sleep 2

echo "== screen =="
screen -ls || true
echo

echo "== process =="
pgrep -a MediaServer
echo

echo "== http =="
curl -fsS -I --max-time 5 http://127.0.0.1:8888/
