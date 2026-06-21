# OpenRD Video Relay

OpenRD remote video relay notes for the Tencent Cloud server.

## Server

- Public IP: `43.139.25.165`
- SSH user: `ubuntu`
- Purpose: public video relay for RK3588 active push, then browser playback.
- Credential rule: do not store SSH keys, API secrets, certificates, passwords, or security-group details in this repository.

## Current Runtime

The server already has a native ZLMediaKit instance running. Do not start a second ZLMediaKit on the same default ports unless this instance is intentionally stopped and migrated.

- Source/build path: `/home/ubuntu/ZLMediaKit`
- Runtime directory: `/home/ubuntu/ZLMediaKit/release/linux/Debug`
- Binary: `/home/ubuntu/ZLMediaKit/release/linux/Debug/MediaServer`
- Command observed: `sudo ./MediaServer -d`
- Process wrapper observed: `screen -S media-server`
- HTTP service: `http://43.139.25.165:8888/`
- RTMP ingest: `rtmp://43.139.25.165:1935/live/openrd`
- RTSP play candidate: `rtsp://43.139.25.165/live/openrd`
- HTTP-FLV play candidate: `http://43.139.25.165:8888/live/openrd.live.flv`
- HLS: disabled to avoid disk segment generation.

Observed media ports:

```text
554/tcp    RTSP
1935/tcp   RTMP
8888/tcp   ZLMediaKit HTTP
9000/udp   ZLMediaKit RTP/WebRTC-related UDP
10000/tcp  ZLMediaKit RTP/WebRTC-related TCP
10000/udp  ZLMediaKit RTP/WebRTC-related UDP
```

## No Recording Policy

The runtime config at `/home/ubuntu/ZLMediaKit/release/linux/Debug/config.ini` is set for relay-only use:

```text
enable_hls=0
enable_hls_fmp4=0
enable_mp4=0
hls_demand=1
mp4_as_player=0
segKeep=0
```

With this setup, RTMP ingest, RTSP, HTTP-FLV, HTTP-FMP4, and WebRTC-style relay remain available, but HLS segment generation and MP4 recording are disabled by default. Do not enable HLS or MP4 recording unless there is an explicit retention plan and disk quota.

## Checks

From the server:

```bash
cd ~/tools/openrd-video-relay
./check.sh
```

Restart the existing native ZLMediaKit process:

```bash
cd ~/tools/openrd-video-relay
./start_zlm.sh
```

From a development machine:

```powershell
curl.exe -I http://43.139.25.165:8888/
```

Expected HTTP header contains `Server: ZLMediaKit`.

## Smoke Test

On 2026-06-21, a development machine pushed a synthetic RTMP stream to:

```text
rtmp://43.139.25.165:1935/live/openrd_smoke
```

HTTP-FLV playback from:

```text
http://43.139.25.165:8888/live/openrd_smoke.live.flv
```

returned HTTP 200 and downloaded live FLV bytes, so公网 RTMP ingest and HTTP-FLV playback are reachable.

After the no-recording change, HLS requests do not return media bytes, and `www/log` contains no generated `.mp4`, `.ts`, `.m3u8`, `.flv`, `.h264`, or `.h265` media files.

## RK3588 Push Sketch

Final RK3588 command depends on the camera node and encoder path. The first smoke test should push one H.264 stream to:

```text
rtmp://43.139.25.165:1935/live/openrd
```

Example shape:

```bash
ffmpeg -re -i INPUT -c:v h264_v4l2m2m -b:v 2500k -f flv rtmp://43.139.25.165:1935/live/openrd
```

After the push is live, verify playback with HTTP-FLV first, then wire WebRTC playback into the frontend.

## Docker Migration Note

The original preference is Docker for repeatable deployment under `~/tools/openrd-video-relay`, but this server already has a native ZLMediaKit instance occupying the default ports. Migration to Docker should be an explicit operation:

1. Record the current config and API secret outside the repo.
2. Stop the native `MediaServer` instance.
3. Start a Docker-based ZLMediaKit with equivalent ports and config.
4. Re-test RTMP ingest, HTTP-FLV, and WebRTC playback.
