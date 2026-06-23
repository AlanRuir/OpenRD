# 07 公网底盘控制方案

本文档记录 OpenRD 底盘控制链路从“局域网直连 ESP32/OpenRD-Driver”演进到“公网远程驾驶”的目标方案。

核心原则：控制链路比视频链路安全等级更高。前端不能直连车端或 ESP32，车端应主动连接云端，所有驾驶命令必须经过车端本地安全层，ESP32 仍保留独立超时停车。

## 当前状态

当前已经实车验证的主链路是公网控制闭环：

```text
Flutter Web 前端
  -> HTTP
云端 openrd-control-service
  -> HTTP long-poll
RK3588 openrd-control-agent
  -> HTTP
ESP32 / OpenRD-Driver
  -> UART2
四路编码器电机驱动板
  -> 四轮底盘
```

默认公网控制地址：

```text
http://43.139.25.165:8790
```

局域网直连链路仍作为回退调试路径保留：

```text
Flutter Web 前端
  -> HTTP
ESP32 / OpenRD-Driver
  -> UART2
四路编码器电机驱动板
  -> 四轮底盘
```

回退控制地址：

```text
http://192.168.100.114
```

当前已验证：

- Flutter 前端可通过浏览器 Gamepad API 读取手柄；
- 前端可请求云端 `openrd-control-service` 的 `/drive/status`、`/drive/command`、`/drive/stop`、`/drive/estop`、`/drive/reset_estop`；
- RK3588 `openrd-control-agent.service` 已部署并开机自启，可把云端命令转发给 ESP32；
- 车端 agent 已验证本地 watchdog、急停锁定和急停复位；
- 前端也可回退请求 OpenRD-Driver 的 `/status`、`/control`、`/read_vol`；
- ESP32 到四路电机驱动板的 UART 协议已跑通；
- 当前实车物理映射为 `M1/M2 = 左侧`、`M3/M4 = 右侧`；
- 前进、后退、左转、右转、停止已能通过手柄控制；
- 电池电压和电量显示已接入；
- 公网链路不要求前端和 ESP32 位于同一局域网。

## 目标

- 前端只连接公网云端，不直连 ESP32 或 RK3588 局域网地址；
- 车端主动连接云端，不要求家庭或实验室网络暴露入站端口；
- 云端负责会话、鉴权、车辆在线状态和命令转发；
- RK3588 车端 agent 负责接收云端驾驶命令并做本地安全兜底；
- ESP32/OpenRD-Driver 继续保留独立控制超时停车；
- 公网控制默认限速，急停优先级最高；
- 视频未就绪时禁止远程驾驶或强制低速；
- 后续可从 WebSocket 升级到 WebRTC DataChannel，但上层控制模型不变。

## 非目标

- 不把 ESP32 HTTP 端口暴露到公网；
- 不把 RK3588 局域网 HTTP/WebSocket 端口暴露到公网；
- 不把 SSH 密钥、车端密钥或任意 systemctl 能力放进前端；
- 不提供通用远程命令执行接口；
- 不让云端直接决定最终电机输出，最终安全控制必须落在车端；
- 不用视频链路状态替代控制链路安全判断。

## 目标架构

```text
Flutter 前端
  -> WebSocket / HTTPS
云端 openrd-control-service
  -> WebSocket / HTTP polling / 后续 DataChannel
RK3588 openrd-control-agent
  -> openrd_safety / 或短期 ESP32 HTTP proxy
ESP32 / OpenRD-Driver
  -> UART2
四路电机驱动板
```

关键方向：

- 前端和车端都只面向云端；
- 车端主动出站连接云端；
- 云端只转发控制意图，不直接驱动电机；
- RK3588 本地必须有 watchdog 和停车兜底；
- ESP32 仍必须有自己的控制超时停车；
- 视频和底盘控制底层分开，上层用 driving session 编排。

## 推荐分层

### 云端 control service

职责：

- 管理车辆在线状态；
- 管理远程驾驶 session；
- 接收前端驾驶输入；
- 将驾驶命令转发给当前在线车端 agent；
- 接收并缓存车端状态；
- 对前端广播车辆状态；
- 做鉴权、日志和连接状态管理；
- 当前可复用已部署的 `openrd-control.service`，但应把视频控制和底盘控制在 API/协议层分开。

不负责：

- 不直接连接 ESP32；
- 不做最终限幅和安全停车；
- 不保存车端 SSH 密钥；
- 不提供任意命令转发。

### RK3588 control agent

职责：

- 主动连接云端；
- 接收 `drive`、`stop`、`estop`、`reset_estop` 等白名单命令；
- 对命令做本地限频、限幅和超时检查；
- 断开云端或前端超时后立即输出停车；
- 将安全后的命令转发到当前底盘控制后端；
- 上报控制状态、电池、电机目标值、最近命令延迟、急停状态；
- 后续接入 ROS2 `openrd_safety_node`。

不负责：

- 不作为公网 HTTP server；
- 不绕过 safety 直接输出高风险命令；
- 不依赖前端页面正常关闭来停车。

### 底盘控制后端

短期后端：

```text
RK3588 control agent
  -> HTTP
ESP32 OpenRD-Driver http://192.168.100.114/control
```

长期后端：

```text
RK3588 control agent / openrd_web_bridge
  -> ROS2 /openrd/drive_cmd
openrd_safety_node
  -> /openrd/safe_drive_cmd
openrd_esp32_bridge_node
  -> UART
ESP32
```

短期 HTTP proxy 方案用于快速验证公网手柄控制体验；长期应接回 ROS2 safety + UART 正式链路。

## 短期最小闭环

Phase 1 不直接改 ESP32 固件，不暴露 ESP32 公网端口，而是在 RK3588 上增加控制 agent：

```text
Flutter 前端
  -> WebSocket
云端 openrd-control-service
  -> 车端主动连接
RK3588 openrd-control-agent
  -> HTTP
ESP32 OpenRD-Driver
```

这样可以复用当前已经验证的 OpenRD-Driver HTTP 接口：

```text
GET  /status
POST /control
POST /read_vol
```

云端和车端之间优先使用 WebSocket。若 RK3588 环境短期缺少依赖，也可以像视频 Phase 1 一样先使用 HTTP polling，但控制链路目标应尽快切到 WebSocket 或 DataChannel，因为驾驶命令需要更低延迟和更稳定的连续传输。

当前已先落地 HTTP long-poll 版本，原因是它只依赖 Python 标准库，和已验证的视频按需启停链路一致：

```text
Flutter Web
  -> HTTP POST /api/vehicles/openrd-001/drive/command
云端 openrd-control-service
  -> /api/agent/poll long-poll
RK3588 openrd-control-agent
  -> HTTP POST http://192.168.100.114/control
ESP32 OpenRD-Driver
```

已实现的文件：

```text
server/openrd_control_service/openrd_control_service.py
vehicle/control_agent/openrd-control-agent
infra/systemd/openrd-control-agent.service
tools/rk3588/install_openrd_control_agent.sh
frontend/openrd_frontend/lib/control_link_web.dart
```

当前前端控制地址默认改为：

```text
http://43.139.25.165:8790
```

如需回退局域网直连，调试面板中把控制地址改为：

```text
http://192.168.100.114
```

### 历史部署验证记录

以下记录是 2026-06-22 的 Phase 1 HTTP long-poll 部署与低速闭环验证结果，用于追溯当时的实车状态；它不是实时在线状态。实时状态应以 `GET /api/vehicles/openrd-001/drive/status`、`GET /api/vehicles/openrd-001/video/status` 和 RK3588 systemd 状态为准。

```text
云端 openrd-control-service:
  http://43.139.25.165:8790

RK3588:
  host: ATK-DLRK3588
  ip: 192.168.100.108 / 192.168.100.110
  service: openrd-control-agent.service
  state: enabled + active

ESP32 OpenRD-Driver:
  http://192.168.100.114
```

低速闭环验证结果：

```text
POST /drive/stop
  -> target [0,0,0,0]

POST /drive/command throttle=0.35 speed_limit=120
  -> target [42,42,42,42]

POST /drive/stop
  -> target [0,0,0,0]
```

当时云端状态可看到：

```text
drive_agent_online=true
esp32_online=true
drive_state=idle
battery_voltage_v≈11.5
```

## 前端到云端协议草案

建议前端通过 WebSocket 连接云端：

```text
wss://<cloud>/api/vehicles/openrd-001/drive/ws
```

当前没有域名和 TLS 时，可临时使用：

```text
ws://43.139.25.165:<port>/api/vehicles/openrd-001/drive/ws
```

上线前应切到 TLS，并加入鉴权。

### hello

```json
{
  "type": "hello",
  "version": 1,
  "client_id": "openrd-web-001",
  "vehicle_id": "openrd-001",
  "client_time_ms": 1780000000000
}
```

### drive

前端目标发送频率为 20Hz：

```json
{
  "type": "drive",
  "version": 1,
  "seq": 1024,
  "vehicle_id": "openrd-001",
  "client_time_ms": 1780000000100,
  "steering": 0.2,
  "throttle": 0.4,
  "brake": 0.0,
  "speed_limit": 300,
  "enable": true,
  "estop": false,
  "source": "gamepad"
}
```

字段规则：

- `steering` 范围 `[-1.0, 1.0]`；
- `throttle` 范围 `[-1.0, 1.0]`；
- `brake` 范围 `[0.0, 1.0]`；
- `speed_limit` 公网默认建议不超过 `300`；
- `enable=false` 时车端必须停车；
- `estop=true` 时进入急停锁定。

### stop

```json
{
  "type": "stop",
  "version": 1,
  "seq": 1025,
  "vehicle_id": "openrd-001",
  "client_time_ms": 1780000000150
}
```

### estop

```json
{
  "type": "estop",
  "version": 1,
  "seq": 1026,
  "vehicle_id": "openrd-001",
  "client_time_ms": 1780000000200
}
```

### vehicle_state

云端向前端广播：

```json
{
  "type": "vehicle_state",
  "version": 1,
  "vehicle_id": "openrd-001",
  "control_state": "active",
  "video_state": "running",
  "vehicle_online": true,
  "agent_online": true,
  "last_cmd_age_ms": 35,
  "speed_limit": 300,
  "target": [120, 120, 80, 80],
  "battery_v": 11.6,
  "estop": false,
  "server_time_ms": 1780000000250
}
```

## 云端到车端协议草案

连接方向：

```text
RK3588 openrd-control-agent -> 云端 openrd-control-service
```

agent 上线：

```json
{
  "type": "hello",
  "version": 1,
  "vehicle_id": "openrd-001",
  "agent": "openrd-control-agent",
  "capabilities": ["drive", "stop", "estop", "status"]
}
```

云端下发驾驶命令：

```json
{
  "type": "drive",
  "request_id": "cmd-001",
  "seq": 2048,
  "steering": 0.2,
  "throttle": 0.4,
  "brake": 0.0,
  "speed_limit": 300,
  "enable": true,
  "estop": false,
  "deadline_ms": 1780000000500
}
```

车端状态上报：

```json
{
  "type": "drive_state",
  "vehicle_id": "openrd-001",
  "state": "active",
  "last_cmd_seq": 2048,
  "last_cmd_age_ms": 20,
  "backend": "esp32_http",
  "esp32_online": true,
  "estop": false,
  "target": [120, 120, 80, 80],
  "last_error": ""
}
```

## 安全规则

最低要求：

- 前端命令间隔超过 `200ms-500ms`，车端 agent 必须输出停车；
- 云端到车端连接断开，车端 agent 必须输出停车；
- 前端断开，云端必须通知车端停车；
- 车端 agent 自己必须有 watchdog，不能依赖云端或前端；
- ESP32/OpenRD-Driver 必须保留自己的控制超时停车；
- 公网控制默认限速，建议 `200` 或 `300` 起步；
- 急停命令优先级最高；
- 急停触发后必须显式复位才能继续驾驶；
- 视频未 ready 时禁止远程驾驶，或强制低速并明显提示；
- 云端 API/WS 必须加 token 或 session 鉴权，不能裸奔；
- 所有命令带 `seq`，车端可丢弃明显过期或乱序命令；
- stop/estop 必须幂等，重复调用仍返回安全状态。

建议参数：

```text
frontend drive rate:        20Hz
cloud command timeout:      300ms
vehicle agent timeout:      300ms
ESP32/OpenRD-Driver timeout:500ms
public default speed limit: 200-300
max accepted rate:          50Hz
```

## 驾驶会话

视频和底盘控制底层分开，但前端产品体验应是一个远程驾驶 session。

```text
start_session
  -> 检查车辆 agent 在线
  -> 启动视频推流
  -> 等视频 ready
  -> 建立控制通道
  -> 允许驾驶输入

renew_session
  -> 视频 lease 续约
  -> 控制心跳续约

end_session
  -> 发送停车
  -> 关闭控制通道
  -> 停止视频推流
```

这样可以避免“视频已停但仍能远程驾驶”或“控制断开但视频还在无意义推流”等状态失配。

## 与视频链路的关系

底盘控制和视频链路不是同一个底层服务：

```text
video plane:
  openrd-video-agent
  openrd-video-native.service
  ZLMediaKit

drive plane:
  openrd-control-agent
  safety / ESP32 bridge
  OpenRD-Driver / ESP32

session orchestration:
  云端 control service
  前端驾驶会话 UI
```

设计原则：

- 视频重启不应直接破坏底盘安全控制；
- 控制断开必须停车，但不一定立即杀视频，用户可能还需要看现场；
- 开始远程驾驶时，应优先要求视频 ready；
- 结束远程驾驶时，应先停车，再停止视频；
- 后续可以由统一 session 管理器编排两条链路。

## 分阶段实现建议

### Phase 1：公网控制最小闭环

```text
前端 HTTP
  -> 云端 control service
  -> RK3588 control agent
  -> ESP32 OpenRD-Driver HTTP
```

实现内容：

- 云端增加前端控制 API；
- 云端增加车端 control agent 轮询通道；
- RK3588 增加 `openrd-control-agent`；
- agent 将安全后的四轮速度转发到 `http://192.168.100.114/control`；
- agent 实现本地超时停车；
- 前端 HTTP 控制链路自动识别云端 API 或 ESP32 直连；
- 默认限速 `300`；
- 实现 stop、estop 和 reset_estop。

验收：

- 前端不访问 `192.168.100.114`；
- RK3588 和云端断开时小车停车；
- 前端关闭页面时小车停车；
- 云端服务重启时小车停车；
- ESP32/OpenRD-Driver 超时保护仍生效；
- 实车低速前进、后退、左转、右转、停止正常。

### Phase 2：安全增强

- 加入 token/session 鉴权；
- 加入急停锁定和复位流程；
- 加入控制状态回传；
- 加入控制日志；
- 加入视频 ready gate；
- 加入多客户端互斥，避免多人同时控制同一辆车；
- 加入云端状态面板和运维检查。

### Phase 3：接回 ROS2 正式链路

```text
云端
  -> RK3588 control agent / openrd_web_bridge
  -> openrd_safety_node
  -> openrd_esp32_bridge_node
  -> UART
  -> ESP32
```

目标：

- 把临时 ESP32 HTTP proxy 替换为 ROS2-first 正式架构；
- 统一 `/openrd/drive_cmd`、`/openrd/safe_drive_cmd` 和 `/openrd/vehicle_state`；
- 保留 ESP32 独立超时停车。

### Phase 4：低延迟升级

- 控制从 WebSocket 评估升级到 WebRTC DataChannel；
- 视频从 HTTP-FLV 评估升级到 WebRTC；
- driving session 继续保留同一套安全规则和状态机。

## 当前建议

Phase 1 最小闭环已经完成过实车低速验证，当前代码已包含：

- 车端 watchdog；
- 前端断开停车；
- 云端断开停车；
- 默认低速；
- stop/estop；
- ESP32 超时保护验证。

后续进入 Phase 2：补 token/session 鉴权、驾驶会话互斥、视频 ready gate、状态面板和更完整的运维日志。控制链路不能只以“能动”为验收标准，最低验收标准必须是“失联必停”。
