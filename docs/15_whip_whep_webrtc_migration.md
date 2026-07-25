# WHIP/WHEP WebRTC 视频链路迁移

日期：2026-07-14

本文记录 OpenRD 视频链路从 `RTMP -> HTTP-FLV` 切换到 `WHIP/WebRTC -> WHEP/WebRTC` 的当前实现。

## 目标链路

```text
RK3588 /dev/openrd-cam-uvc
  -> V4L2 MJPG
  -> jpegparse / mppjpegdec
  -> mpph264enc H.264
  -> h264parse
  -> rtph264pay
  -> openrd-video-whip-client.py (webrtcbin)
  -> ZLMediaKit WHIP ingest
  -> ZLMediaKit WHEP playback
  -> Flutter Web RTCPeerConnection
```

默认端点：

```text
WHIP ingest: http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=push
WHEP play:   http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=play
```

浏览器部署入口在 `:8080`，实际播放时前端会把同主机 `:8888` 的 WHEP URL 改写为同源代理：

```text
Browser WHEP play: http://43.139.25.165:8080/index/api/webrtc?app=live&stream=openrd&type=play
Caddy upstream:    127.0.0.1:8888 ZLMediaKit
```

RTMP、RTSP 和 HTTP-FLV 仍保留为排障 fallback，不再是默认播放链路。

## 车端实现

`vehicle/native_video/openrd-video-native` 新增 `whip` 模式：

- 新增参数：`--whip-url`、`--whep-url`、`--whip-auth-token`；
- `webrtc` 作为 `whip` 的兼容别名；
- `whip` 模式依赖 `rtph264pay` 和 `webrtcbin`/`nice` + `openrd-video-whip-client.py`；
- pipeline 使用 `rtph264pay -> openrd-video-whip-client.py (webrtcbin)` 发布 RTP/H264；
- `status --json` 新增 `transport`、`whip_url`、`whep_url`；
- `WHIP_AUTH_TOKEN` 不写入状态文件，避免 token 泄漏。

示例：

```bash
./openrd-video-native start \
  --mode whip \
  --device /dev/openrd-cam-uvc \
  --input-format mjpg \
  --whip-url 'http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=push'
```

## systemd 与 agent

`infra/systemd/openrd-video-native.service` 默认 `OPENRD_VIDEO_MODE=whip`，并透传 `OPENRD_VIDEO_WHIP_URL` 与 `OPENRD_VIDEO_WHEP_URL`。

`vehicle/video_agent/openrd-video-agent` 现在会在收到云端 `video.start` 后：

- 写入 `vehicle/native_video/run/openrd-video-native-service.env`；
- 强制更新 `OPENRD_VIDEO_MODE=whip`、`OPENRD_VIDEO_WHIP_URL`、`OPENRD_VIDEO_WHEP_URL`；
- 如果当前 runtime 已运行但模式或 URL 不匹配，执行 `systemctl restart openrd-video-native.service`；
- 上报 `mode`、`transport`、`whip_url`、`whep_url` 给云端控制服务。

## 云端控制服务

`server/openrd_control_service/openrd_control_service.py` 默认下发：

```json
{
  "mode": "whip",
  "transport": "webrtc",
  "whip_url": "http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=push",
  "whep_url": "http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=play"
}
```

`play_url` 仍返回 HTTP-FLV 地址，作为旧播放器和桌面排障 fallback。

可覆盖环境变量：

```text
OPENRD_CONTROL_VIDEO_MODE=whip
OPENRD_CONTROL_WHIP_URL=http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=push
OPENRD_CONTROL_WHEP_URL=http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=play
OPENRD_CONTROL_RTMP_URL=rtmp://43.139.25.165:1935/live/openrd
OPENRD_CONTROL_PLAY_URL=http://43.139.25.165:8888/live/openrd.live.flv
```

## Flutter 前端

`frontend/openrd_frontend/lib/video_stream_web.dart` 改为 WHEP 优先播放器：

- `whepUrl` 非空时创建 `RTCPeerConnection`；
- 添加 `video recvonly` transceiver；
- 生成 SDP offer，等待本地 ICE gathering 后 POST 到 WHEP endpoint；
- 兼容标准 `application/sdp` answer 和 JSON 包装 answer；
- 远端 track 绑定到 `<video>`；
- iframe `pointer-events: none`，避免移动端 HUD 控件被视频层拦截；
- `whepUrl` 为空时才回退到旧 HTTP-FLV/mpegts.js 播放。

`main.dart` 会优先使用云端返回的 `whep_url`。如果云端暂未返回，则按当前 `ZLM Host` 和 `Path` 自动拼接：

```text
http://<ZLM Host>:8888/index/api/webrtc?app=<app>&stream=<stream>&type=play
```

当页面运行在同一台公网主机的 `:8080` 静态入口时，前端会把该 URL 改写到 `:8080/index/api/webrtc?...`，通过 Caddy 同源反代避免浏览器跨端口 CORS。

桌面端视频面板和手机端 HUD 都复用同一个 WHEP 播放器。

## ROS2 状态

`openrd_bringup/config/video.yaml` 默认 `mode: whip`。

`openrd_msgs/msg/VideoState.msg` 新增：

```text
string whip_url
string whep_url
string transport
```

`openrd_video_node` 会解析 runtime JSON 中的 `whip_url`、`whep_url`、`transport`，并在启动 runtime 时透传 `--whip-url` 与 `--whep-url`。

## 验证清单

车端：

```bash
gst-inspect-1.0 webrtcbin
gst-inspect-1.0 nice
gst-inspect-1.0 rtph264pay
./vehicle/native_video/openrd-video-native pipeline --mode whip
./vehicle/native_video/openrd-video-native status --json
```

云端：

```bash
curl -I 'http://43.139.25.165:8888/'
curl -s 'http://43.139.25.165:8790/api/vehicles/openrd-001/video/status'
```

说明：`/index/api/webrtc?type=push` 和 `/index/api/webrtc?type=play` 不是普通 GET 播放页，验证重点是浏览器 Network 里是否出现 SDP `POST`，以及 SDP answer 后 ICE/track 是否建立成功。

前端：

- 点击“启动视频推流”；
- 确认 control service 返回 `mode=whip`、`transport=webrtc`、`whep_url`；
- 浏览器 Network 中能看到 WHEP SDP POST；
- 视频画面开始播放；
- 手机 HUD 横屏下按钮、STOP/ESTOP、摇杆仍可触发。

## 风险与后续

- RK3588 上必须安装包含 `webrtcbin`/`nice` + `openrd-video-whip-client.py` 的 GStreamer WebRTC/rswebrtc 插件；
- 如果 ZLMediaKit WHEP 在跨网环境 ICE 不稳定，需要补 TURN；
- 如果 WHEP SDP POST 被 CORS 拦截，优先确认 Caddy `/index/api/webrtc` 同源反代和前端 URL 改写是否生效；
- WebRTC 端到端延迟需要重新实测，不能沿用 HTTP-FLV 延迟结论。
