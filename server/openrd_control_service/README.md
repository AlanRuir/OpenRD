# openrd_control_service

Minimal public control service for OpenRD video-on-demand push and public
chassis control.

It uses only Python standard library modules. The browser calls the public HTTP
API, and RK3588 agents actively poll `/api/agent/poll` for commands. This keeps
the vehicle side outbound-only.

## Run Locally

```bash
python3 openrd_control_service.py --host 0.0.0.0 --port 8790
```

On the current Tencent Cloud server, the preferred public control endpoint is:

```text
http://43.139.25.165:8790
```

Caddy also keeps a fallback reverse proxy at
`http://43.139.25.165:8080/openrd-control`.

## API

```text
GET  /health
GET  /api/vehicles/openrd-001/video/status
POST /api/vehicles/openrd-001/video/start
POST /api/vehicles/openrd-001/video/renew
POST /api/vehicles/openrd-001/video/stop
GET  /api/vehicles/openrd-001/drive/status
POST /api/vehicles/openrd-001/drive/command
POST /api/vehicles/openrd-001/drive/stop
POST /api/vehicles/openrd-001/drive/estop
POST /api/vehicles/openrd-001/drive/reset_estop
POST /api/agent/poll
```

The same agent polling endpoint is shared by video and drive agents. The server
routes queued commands by agent name:

```text
openrd-video-agent   -> video.* command queue
openrd-control-agent -> drive.* command queue
```

Drive commands are not accumulated unboundedly. Pending `drive.drive` commands
are replaced by the latest command so stale driving input does not replay later.

Default media URLs:

```text
RTMP ingest:   rtmp://43.139.25.165:1935/live/openrd
HTTP-FLV play: http://43.139.25.165:8888/live/openrd.live.flv
RTSP play:     rtsp://43.139.25.165/live/openrd
```

## Install On Tencent Cloud

Assuming the repo is at `/home/ubuntu/OpenRD`:

```bash
cd /home/ubuntu/OpenRD
bash server/openrd_control_service/install_openrd_control_service.sh
sudo systemctl start openrd-control.service
systemctl status openrd-control.service --no-pager
```

Optional local overrides are written to:

```text
/home/ubuntu/OpenRD/server/openrd_control_service/run/openrd-control.env
```

Supported environment variables:

```text
OPENRD_CONTROL_HOST=0.0.0.0
OPENRD_CONTROL_PORT=8790
OPENRD_CONTROL_ALLOW_ORIGIN=*
OPENRD_CONTROL_VIEWER_TOKEN=
OPENRD_CONTROL_AGENT_TOKEN=
OPENRD_CONTROL_DEFAULT_TTL_SEC=120
OPENRD_CONTROL_AGENT_TIMEOUT_SEC=45
OPENRD_VIDEO_LATENCY_STATUS_FILE=/tmp/openrd-video-latency.json
OPENRD_VIDEO_LATENCY_STALE_MS=5000
OPENRD_DRIVE_COMMAND_TTL_MS=300
OPENRD_DRIVE_DEFAULT_SPEED_LIMIT=300
OPENRD_DRIVE_MAX_SPEED_LIMIT=500
```

If a token is set, clients must send either:

```text
Authorization: Bearer <token>
```

or:

```text
X-OpenRD-Token: <token>
```

## Video Latency Status

`GET /api/vehicles/openrd-001/video/status` also merges the optional sidecar
status file from `OPENRD_VIDEO_LATENCY_STATUS_FILE`.

When `tools/video_latency/openrd_video_latency_sidecar.py` is running, the
response may include:

```json
{
  "video_latency_ms": 180,
  "video_latency_avg_ms": 190,
  "video_latency_p50_ms": 170,
  "video_latency_p95_ms": 260,
  "video_frame_seq": 123456,
  "sidecar_first_sei_seen_ms": 1780000000000,
  "sidecar_first_sei_frame_seq": 0,
  "sidecar_first_sei_latency_ms": 180,
  "video_latency_state": "ok",
  "video_latency_updated_ms": 1780000000000
}
```

If the status file is missing, the service returns
`video_latency_state=unknown`. If the file is stale, it returns
`video_latency_state=stale` instead of showing an old latency value as current.
