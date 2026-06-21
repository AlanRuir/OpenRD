# 06 公网视频按需启停方案

本文档记录 OpenRD 从“局域网视频预览”演进到“公网视频中继 + 按需推流控制”的目标方案。

核心原则：既然媒体播放已经走公网 ZLMediaKit，视频启停控制也应按公网目标设计，不再依赖前端直连 RK3588 局域网 IP。

## 背景

当前视频链路已经验证：

```text
RK3588 openrd-video-native.service
  -> RTMP
腾讯云 ZLMediaKit
  -> HTTP-FLV / RTSP
Flutter 前端
```

当前公网地址：

```text
RTMP ingest:   rtmp://43.139.25.165:1935/live/openrd
HTTP-FLV play: http://43.139.25.165:8888/live/openrd.live.flv
RTSP play:     rtsp://43.139.25.165/live/openrd
```

这个链路解决了远程观看问题，但如果 RK3588 一直推流，会持续消耗车端上行带宽、云服务器流量和编码资源。因此视频推流应从“常开”改成“前端观看时按需启停”。

## 目标

- 前端只访问公网服务，不直连 RK3588 局域网地址；
- 车端主动连接云端，不要求家庭或实验室网络暴露入站端口；
- RK3588 视频采集、编码、推流继续运行在宿主 Debian 系统；
- Docker / chroot / ROS2 不直接访问摄像头驱动和 Rockchip MPP 视频栈；
- 云端负责公网 API、会话、鉴权、观看心跳和命令转发；
- 车端本地保留 idle timeout 兜底，避免异常情况下长时间空推流；
- ZLMediaKit 只做直播转发，保持 HLS/MP4 录制关闭，避免占满磁盘。

## 非目标

- 不把 SSH 密钥、服务器密钥或 systemctl 能力放进前端；
- 不把 RK3588 局域网 HTTP agent 暴露到公网；
- 不做通用远程命令执行接口；
- 不把每帧驾驶视频强行塞入 ROS2 `sensor_msgs/Image` 主链路；
- 短期不要求一次性完成多车、多用户、计费、权限体系。

## 目标架构

```text
Flutter 前端
  -> HTTPS / WebSocket
云端 OpenRD control service
  -> WebSocket / MQTT / HTTPS 长连接
RK3588 宿主机 openrd-video-agent
  -> systemctl start/stop/status openrd-video-native.service
RK3588 openrd-video-native.service
  -> RTMP
腾讯云 ZLMediaKit
  -> HTTP-FLV / RTSP
Flutter 前端
```

关键方向：

- 前端的控制面和媒体面都走公网；
- 车端 agent 主动出站连接云端；
- 云端不需要主动打进车端局域网；
- 宿主机 agent 只白名单管理视频 service；
- ROS2 视频节点后续通过 agent 获取状态或发控制请求，不直接碰驱动。

## 组件边界

### Flutter 前端

职责：

- 展示视频面板；
- 点击“启动视频”时调用云端 API；
- 等待云端返回车端状态和播放地址；
- 探测 HTTP-FLV 可用后开始播放；
- 播放期间发送观看心跳或续约；
- 点击“停止视频”或页面退出时请求云端停止推流；
- 显示启动中、播放中、停止中、异常等状态。

不负责：

- 不保存 SSH 密钥；
- 不直接访问 RK3588 局域网 IP；
- 不直接执行 `systemctl`；
- 不承担最终停止推流兜底。

### 云端 control service

职责：

- 对前端提供公网 HTTPS API；
- 维护车辆在线状态；
- 维护视频观看 session；
- 将 `start_video`、`stop_video`、`status`、`renew` 指令下发给车端 agent；
- 聚合车端 agent 返回的运行状态；
- 对前端返回播放 URL；
- 根据观看心跳做 idle timeout；
- 记录必要的操作日志。

不负责：

- 不保存视频文件；
- 不直接访问摄像头；
- 不直接运行 GStreamer；
- 不做通用 shell relay。

### RK3588 openrd-video-agent

运行位置：RK3588 宿主 Debian 系统。

职责：

- 主动连接云端 control service；
- 接收云端下发的白名单命令；
- 管理 `openrd-video-native.service`；
- 查询 `openrd-video-native status --json`；
- 上报 service 状态、PID、模式、RTMP 地址、错误摘要；
- 实现本地 lease / idle timeout 兜底；
- 断开云端连接一段时间后自动停止推流。

不负责：

- 不做视频采集、编码、推流；
- 不作为公网 HTTP server；
- 不提供任意命令执行；
- 不替代 ROS2 video node 的状态发布职责。

### openrd-video-native.service

运行位置：RK3588 宿主 Debian 系统。

职责：

- 访问 `/dev/openrd-cam-uvc` 或后续 CSI 摄像头别名；
- 使用 GStreamer、Rockchip MPP、V4L2 等宿主视频栈；
- 编码 H.264；
- 主动推 RTMP 到 ZLMediaKit；
- 通过现有 CLI 提供 `start`、`stop`、`restart`、`status --json`。

### ROS2 openrd_video_node

后续定位：

- 运行在 Ubuntu chroot / ROS2 环境；
- 通过宿主 agent 或 `openrd-video-systemd` 获取视频 runtime 状态；
- 发布 `/openrd/video_state`；
- 后续可将 ROS2 service 转成 agent 指令；
- 不直接访问摄像头、不直接运行 MPP/GStreamer pipeline。

## 控制协议草案

### 前端到云端

建议先用 HTTPS JSON API，后续可增加 WebSocket 状态推送。

```text
GET  /api/vehicles/{vehicle_id}/video/status
POST /api/vehicles/{vehicle_id}/video/start
POST /api/vehicles/{vehicle_id}/video/stop
POST /api/vehicles/{vehicle_id}/video/renew
```

`start` 请求：

```json
{
  "viewer_id": "frontend-session-id",
  "stream": "openrd",
  "ttl_sec": 120
}
```

`start` 响应：

```json
{
  "ok": true,
  "vehicle_id": "openrd-001",
  "state": "starting",
  "play_url": "http://43.139.25.165:8888/live/openrd.live.flv",
  "rtsp_url": "rtsp://43.139.25.165/live/openrd",
  "lease_expires_in_sec": 120
}
```

`status` 响应：

```json
{
  "ok": true,
  "vehicle_id": "openrd-001",
  "vehicle_online": true,
  "video_state": "running",
  "service_active": true,
  "mode": "rtmp",
  "play_url": "http://43.139.25.165:8888/live/openrd.live.flv",
  "last_agent_seen_ms": 1710000000000,
  "last_error": ""
}
```

推荐状态枚举：

```text
offline
stopped
starting
running
stopping
faulted
unknown
```

### 云端到车端 agent

建议使用车端主动发起的 WebSocket 长连接。MQTT 也可行，但短期 WebSocket 更直接，便于和现有 Web 技术栈对齐。

连接方向：

```text
RK3588 openrd-video-agent -> 云端 control service
```

agent 上线后发送：

```json
{
  "type": "hello",
  "vehicle_id": "openrd-001",
  "agent": "openrd-video-agent",
  "version": 1,
  "capabilities": ["video.status", "video.start", "video.stop"]
}
```

云端下发启动命令：

```json
{
  "type": "video.start",
  "request_id": "req-001",
  "stream": "openrd",
  "lease_sec": 120
}
```

agent 返回：

```json
{
  "type": "video.result",
  "request_id": "req-001",
  "ok": true,
  "state": "running",
  "service": "openrd-video-native.service",
  "rtmp_url": "rtmp://43.139.25.165:1935/live/openrd",
  "pid": 5066,
  "last_error": ""
}
```

agent 周期状态上报：

```json
{
  "type": "video.state",
  "vehicle_id": "openrd-001",
  "state": "running",
  "runtime_running": true,
  "pid": 5066,
  "mode": "rtmp",
  "last_seen_ms": 1710000000000,
  "lease_expires_in_sec": 87
}
```

## 启动流程

```text
1. 前端点击“启动视频”
2. 前端 POST /video/start 到云端
3. 云端确认车辆 agent 在线
4. 云端下发 video.start 到 RK3588 agent
5. agent 执行 systemctl start openrd-video-native.service
6. agent 查询 openrd-video-native status --json
7. agent 返回 running / starting / faulted
8. 云端返回 play_url 给前端
9. 前端轮询 /video/status 或探测 HTTP-FLV
10. ZLMediaKit 收到 RTMP publisher 后，HTTP-FLV 可播放
11. 前端播放器开始播放
12. 前端定期 POST /video/renew 保持 lease
```

## 停止流程

```text
1. 前端点击“停止视频”或离开视频页面
2. 前端 POST /video/stop 到云端
3. 云端下发 video.stop 到 RK3588 agent
4. agent 执行 systemctl stop openrd-video-native.service
5. agent 上报 stopped
6. 云端更新视频状态
7. 前端停止播放器并显示已停止
```

异常兜底：

- 前端关闭浏览器但未发送 stop：云端 lease 超时后下发 stop；
- 云端断开：agent 本地 lease 超时后停止推流；
- agent 进程异常：systemd 可拉起 agent，但视频 service 不应因为 agent 异常永久保持推流；
- 视频 service faulted：agent 上报 faulted，前端显示错误，不无限重启。

## Lease 与 idle timeout

建议短期参数：

```text
frontend renew interval: 30s
cloud viewer lease:      120s
agent local lease:       150s
agent status interval:   3s
start wait timeout:      10s
stop wait timeout:       5s
```

规则：

- 有至少一个有效 viewer lease 时，云端允许视频保持 running；
- 所有 viewer lease 过期后，云端下发 stop；
- agent 超过本地 lease 没收到 renew/start，也主动 stop；
- stop 是幂等操作，重复调用应返回 stopped；
- start 是幂等操作，已经 running 时只刷新 lease。

## 安全约束

- 前端只拿公网 API token，不拿车端密钥；
- 车端 agent 使用单独的车端 token 或证书连接云端；
- 云端按 `vehicle_id` 和权限限制操作范围；
- agent 只允许控制 `openrd-video-native.service`；
- 不提供命令字符串透传；
- 不记录 SSH 私钥、云账号密钥、防火墙细节到仓库；
- ZLMediaKit 保持 `enable_hls=0`、`enable_hls_fmp4=0`、`enable_mp4=0`，避免落盘；
- control service 日志只记录状态和错误摘要，不记录敏感 token。

## 与当前系统的关系

当前已经具备：

- RK3588 原生视频 runtime；
- `openrd-video-native.service`；
- 云端 ZLMediaKit；
- HTTP-FLV 前端播放；
- 推流手动 start/stop 运维命令。

需要新增：

- 云端 OpenRD control service；
- RK3588 宿主 `openrd-video-agent`；
- 前端视频启停按钮、状态机和 lease 续约；
- 云端和车端之间的命令协议；
- agent 本地 idle timeout。

需要调整：

- `openrd-video-native.service` 不应作为长期常开服务；
- 可保留 `enabled` 用于故障恢复策略，但默认业务策略应由 agent 按 lease 控制；
- 前端从“打开页面立即播放”改成“请求启动视频 -> 等流可用 -> 播放”。

## 分阶段实现建议

### Phase 1：最小公网按需启停闭环

- 在云服务器增加最小 control service；
- RK3588 增加 `openrd-video-agent`，主动 WebSocket 连接云端；
- 支持 `status/start/stop` 三个命令；
- 前端增加“启动视频 / 停止视频”按钮；
- 前端启动后播放现有 HTTP-FLV；
- agent 实现本地 lease 超时自动 stop。

验收：

- 前端不访问 `192.168.100.108`；
- 点击启动后 RK3588 开始 RTMP 推流；
- 点击停止后 RK3588 停止推流；
- 关闭前端后 lease 超时自动停推；
- ZLMediaKit 不生成 HLS/MP4 文件。

### Phase 2：状态与体验完善

- 云端保存最近一次 agent 状态；
- 前端显示车辆在线、视频启动中、播放中、故障；
- 加入 HTTP-FLV 可用性探测；
- 加入启动失败错误摘要；
- 加入多 viewer 引用计数，只有最后一个 viewer 离开才停流；
- 补充日志和运维检查脚本。

### Phase 3：接入 ROS2 控制面

- `openrd_video_node` 发布 `/openrd/video_state`；
- ROS2 service 可转发到 agent 或云端控制面；
- 统一车端状态聚合；
- 为后续远程驾驶控制 plane 做同类模式复用。

### Phase 4：视频低延迟升级

- HTTP-FLV 保留为兼容播放链路；
- 评估 ZLMediaKit WebRTC / WHIP / WHEP；
- 前端播放器切到更低延迟链路；
- control service 继续负责按需启停和观看 lease。

## 待决问题

- 云端 control service 使用 Node.js、Go 还是 Python；
- 车端 agent 使用 Python 还是 Go；
- 车端认证使用静态 token 还是 mTLS；
- 是否需要多车 `vehicle_id` 规划；
- 前端用户认证何时引入；
- `openrd-video-native.service` 是否保留开机 enabled，还是改为 disabled 后完全由 agent 控制；
- 云端 control service 是否与后续驾驶控制 relay 合并。

## 当前建议

短期直接做 Phase 1，不再实现“前端局域网 HTTP 调 RK3588 agent”的临时方案。

这样能保持架构目标一致：

```text
媒体面：前端 <-> 云端 ZLMediaKit <-> 车端主动推流
控制面：前端 <-> 云端 control service <-> 车端主动连接 agent
```

车端对外只做主动出站连接，前端不依赖车端所在局域网，后续从本机浏览器扩展到手机或异地浏览器时不需要推翻设计。
