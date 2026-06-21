# openrd-video-agent

Host-side RK3588 agent for public video-on-demand control.

The agent runs on the RK3588 Debian host, actively polls the cloud control
service, and only controls:

```text
openrd-video-native.service
```

It does not capture, encode, or forward video itself. The actual media runtime
remains `vehicle/native_video/openrd-video-native`.

## Run Manually

```bash
cd /home/linaro/OpenRD
python3 vehicle/video_agent/openrd-video-agent
```

## Install On RK3588

```bash
cd /home/linaro/OpenRD
bash tools/rk3588/install_openrd_video_agent.sh
sudo systemctl start openrd-video-agent.service
systemctl status openrd-video-agent.service --no-pager
```

Optional local overrides are written to:

```text
/home/linaro/OpenRD/vehicle/video_agent/run/openrd-video-agent.env
```

Supported environment variables:

```text
OPENRD_VIDEO_AGENT_CLOUD_URL=http://43.139.25.165:8790
OPENRD_VIDEO_AGENT_VEHICLE_ID=openrd-001
OPENRD_VIDEO_AGENT_TOKEN=
OPENRD_VIDEO_AGENT_LOCAL_LEASE_SEC=150
OPENRD_VIDEO_AGENT_POLL_WAIT_SEC=20
OPENRD_VIDEO_AGENT_STATUS_INTERVAL_SEC=3
```

The agent has a local lease timeout. If the cloud service disappears or the
frontend stops renewing the session, the agent stops `openrd-video-native.service`.
