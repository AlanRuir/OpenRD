# openrd_control_service

Minimal public control service for OpenRD video-on-demand push.

It uses only Python standard library modules. The browser calls the public HTTP
API, and the RK3588 `openrd-video-agent` actively polls `/api/agent/poll` for
commands. This keeps the vehicle side outbound-only.

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
POST /api/agent/poll
```

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
```

If a token is set, clients must send either:

```text
Authorization: Bearer <token>
```

or:

```text
X-OpenRD-Token: <token>
```
