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
- Runtime directory: `/home/ubuntu/ZLMediaKit/release/linux/Release`
- Binary: `/home/ubuntu/ZLMediaKit/release/linux/Release/MediaServer`
- Command observed: `sudo ./MediaServer -c config.ini`
- Process wrapper observed: `screen -S openrd-zlm`
- HTTP service: `http://43.139.25.165:8888/`
- WHIP ingest: `http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=push`
- WHEP play: `http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=play`
- RTMP ingest: `rtmp://43.139.25.165:1935/live/openrd`
- RTSP play candidate: `rtsp://43.139.25.165/live/openrd`
- HTTP-FLV play candidate: `http://43.139.25.165:8888/live/openrd.live.flv`
- HLS: disabled to avoid disk segment generation.

Current OpenRD default is WHIP/WebRTC ingest from RK3588 and WHEP/WebRTC playback in Flutter. RTMP, RTSP, and HTTP-FLV remain available as relay smoke tests and fallback diagnostics.

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

The runtime config at `/home/ubuntu/ZLMediaKit/release/linux/Release/config.ini` is set for relay-only use:

```text
enable_hls=0
enable_hls_fmp4=0
enable_mp4=0
hls_demand=1
mp4_as_player=0
segKeep=0
```

With this setup, WHIP/WHEP WebRTC, RTMP ingest, RTSP, HTTP-FLV, and HTTP-FMP4 relay remain available, but HLS segment generation and MP4 recording are disabled by default. Do not enable HLS or MP4 recording unless there is an explicit retention plan and disk quota.

The Release binary is the default because it includes the ZLMediaKit WebRTC HTTP APIs (`/index/api/webrtc`, `/index/api/whip`, `/index/api/whep`). The older Debug runtime on this server did not expose those endpoints.

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

The current default RK3588 service publishes one H.264 stream with WHIP/WebRTC:

```text
http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=push
```

The matching browser/Flutter playback endpoint is:

```text
http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=play
```

The legacy RTMP fallback can still push one H.264 stream to:

```text
rtmp://43.139.25.165:1935/live/openrd
```

Example shape:

```bash
ffmpeg -re -i INPUT -c:v h264_v4l2m2m -b:v 2500k -f flv rtmp://43.139.25.165:1935/live/openrd
```

After the WHIP push is live, verify WHEP playback first. Use HTTP-FLV only as a fallback diagnostic when WHEP or ICE negotiation is failing.

## Docker Migration Note

The original preference is Docker for repeatable deployment under `~/tools/openrd-video-relay`, but this server already has a native ZLMediaKit instance occupying the default ports. Migration to Docker should be an explicit operation:

1. Record the current config and API secret outside the repo.
2. Stop the native `MediaServer` instance.
3. Start a Docker-based ZLMediaKit with equivalent ports and config.
4. Re-test WHIP ingest, WHEP playback, RTMP ingest, HTTP-FLV, and WebRTC playback.
