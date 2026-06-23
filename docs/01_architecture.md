# 01 系统架构

本文档描述 OpenRD 的整体架构、模块职责、数据流和后续演进方向。

## 总体架构

OpenRD 的目标车端架构仍是 ROS2-first。基础 v0.1 设计面向局域网 WebSocket -> ROS2 -> UART 闭环；当前实车公网 Phase 1 为了快速验证远程驾驶体验，先使用云端 HTTP API + RK3588 agent 主动轮询 + ESP32 OpenRD-Driver HTTP proxy。两条链路共用同一套上层驾驶输入模型，后续应把公网控制接回 ROS2 safety + UART 正式链路。

```text
目标正式链路：

Flutter 控制端
  ├─ 浏览器 / 手机触屏 / 手柄输入
  ├─ WebSocket 控制命令
  └─ 视频显示
        │
        ▼
RK3588 车端 ROS2 graph
  ├─ openrd_web_bridge_node
  │    └─ WebSocket <-> ROS2
  ├─ openrd_safety_node
  │    └─ 限幅 / 超时 / 急停状态机
  ├─ openrd_esp32_bridge_node
  │    └─ ROS2 <-> UART <-> ESP32
  ├─ openrd_state_node         # 可选，状态聚合
  └─ openrd_video_node         # 原生视频 runtime 管理
        │
        ▼
ESP32 下位机
  ├─ 串口命令解析
  ├─ 电机控制
  ├─ 超时停车
  └─ 急停保护
```

```text
当前公网 Phase 1 实车链路：

Flutter Web 前端
  -> HTTP
云端 openrd-control-service
  -> HTTP long-poll
RK3588 openrd-control-agent
  -> HTTP
ESP32 OpenRD-Driver
  -> UART2
四路电机驱动板
```

## ROS2 package 规划

建议车端 workspace 结构：

```text
vehicle/
  ros2_ws/
    src/
      openrd_msgs/
      openrd_bringup/
      openrd_web_bridge/
      openrd_safety/
      openrd_esp32_bridge/
      openrd_video/
```

package 职责：

- `openrd_msgs`：自定义 `msg` / `srv`，定义控制命令、车辆状态、ESP32 状态；
- `openrd_bringup`：launch 文件、参数文件、启动组合；
- `openrd_web_bridge`：WebSocket 与 ROS2 topic/service 的桥接；
- `openrd_safety`：限幅、死区、超时、急停锁定、安全状态机；
- `openrd_esp32_bridge`：订阅安全控制命令，转发 UART，读取 ESP32 状态；
- `openrd_video`：原生视频 runtime 管理，负责启动、停止和状态上报。

## 模块职责

### Flutter 控制端

Flutter 控制端负责用户交互和控制命令生成。

职责：

- 提供驾驶 UI；
- 支持触屏虚拟摇杆；
- 支持浏览器手柄输入；
- 目标正式链路连接 RK3588 WebSocket 控制入口；
- 当前公网 Phase 1 默认连接云端 `openrd-control-service` HTTP API，局域网回退时可直连 ESP32 OpenRD-Driver；
- 按固定频率发送驾驶命令；
- 显示车端状态；
- 显示视频画面；
- 后续支持 WebRTC 视频和 DataChannel 控制。

不负责：

- 不直接控制电机；
- 不直接接入 ROS2 DDS；
- 不执行最终安全停车逻辑；
- 不依赖本地时间实现安全判断。

### openrd_web_bridge_node

Web bridge 是控制端进入 ROS2 graph 的入口。

职责：

- 提供 WebSocket Server；
- 接收 Flutter 的 `hello`、`drive`、`ping`、`estop`、`reset_estop` 消息；
- 校验 WebSocket JSON 基本格式；
- 将 `drive` 映射为 `/openrd/drive_cmd`；
- 将 `estop` 或 `reset_estop` 映射为 ROS2 topic/service；
- 将 ROS2 状态消息转发为 WebSocket `state`；
- 记录连接状态和命令序号。

不负责：

- 不直接打开 UART；
- 不直接输出电机控制；
- 不实现最终限幅和安全状态机。

### openrd_safety_node

Safety node 是 RK3588 侧安全策略核心。

职责：

- 订阅 `/openrd/drive_cmd`；
- 对 `throttle`、`steering`、`brake` 做限幅；
- 处理死区、速度限制和可选加速度限制；
- 检测控制命令超时；
- 处理急停锁定与复位；
- 发布 `/openrd/safe_drive_cmd`；
- 发布安全状态。

不负责：

- 不直接处理 WebSocket；
- 不直接处理 UART；
- 不能替代 ESP32 的独立超时停车。

### openrd_esp32_bridge_node

ESP32 bridge 是 ROS2 与下位机之间的桥。

职责：

- 订阅 `/openrd/safe_drive_cmd`；
- 将安全控制命令转换为 UART `D` 命令；
- 发送急停与解除急停命令；
- 读取 ESP32 `S` 状态行；
- 发布 `/openrd/esp32_state`；
- 检测串口连接异常。

不负责：

- 不接收 Flutter 连接；
- 不绕过 `openrd_safety_node` 接收原始控制命令；
- 不把 ESP32 的安全职责上移到 RK3588。

### ESP32 下位机

ESP32 是实时控制和安全保护层。

职责：

- 接收 RK3588 串口命令；
- 输出电机 PWM、方向控制信号；
- 实现控制命令超时停车；
- 实现急停锁定；
- 可选读取电池、电流、编码器等状态；
- 通过串口回传状态。

不负责：

- 不连接互联网；
- 不处理视频；
- 不理解 Flutter/WebSocket/ROS2 topic 的上层协议。

## ROS2 topic 与 service

v0.1 建议使用以下接口：

```text
/openrd/drive_cmd          openrd_msgs/msg/DriveCommand
/openrd/safe_drive_cmd     openrd_msgs/msg/DriveCommand
/openrd/vehicle_state      openrd_msgs/msg/VehicleState
/openrd/esp32_state        openrd_msgs/msg/Esp32State
/openrd/video_state        openrd_msgs/msg/VideoState
/openrd/reset_estop        std_srvs/srv/Trigger 或后续自定义 srv
```

补充服务：

```text
/openrd/start_runtime      std_srvs/srv/Trigger
/openrd/stop_runtime       std_srvs/srv/Trigger
/openrd/restart_runtime    std_srvs/srv/Trigger
```

QoS 建议：

- 控制命令只关心最新值，使用 `keep_last(1)`；
- 状态消息只关心最新值，使用 `keep_last(1)`；
- 控制命令不允许队列堆积旧消息；
- 可以在 safety node 内用时间戳和 timer 实现超时，不依赖 DDS 自动处理安全逻辑。

## 控制数据流

目标 v0.1 ROS2 控制链路：

```text
手柄 / 触屏
  -> Flutter 输入归一化
  -> WebSocket JSON
  -> openrd_web_bridge_node
  -> /openrd/drive_cmd
  -> openrd_safety_node
  -> /openrd/safe_drive_cmd
  -> openrd_esp32_bridge_node
  -> UART 文本协议
  -> ESP32
  -> 电机驱动
```

关键约束：

- Flutter 只生成归一化控制意图；
- Web bridge 只做外部协议到 ROS2 的桥接；
- Safety node 负责 RK3588 层安全策略；
- ESP32 bridge 负责 UART 协议转换；
- ESP32 负责最终电机输出和独立安全保护；
- 控制命令要带序号；
- 控制端按固定频率持续发送命令，而不是只在按键变化时发送；
- 任意一层检测到异常都应进入停车或急停状态。

当前公网 Phase 1 控制链路：

```text
手柄 / 触屏
  -> Flutter 输入归一化
  -> HTTP POST /api/vehicles/openrd-001/drive/command
  -> 云端 openrd-control-service
  -> RK3588 openrd-control-agent 主动 long-poll
  -> HTTP POST http://192.168.100.114/control
  -> ESP32 OpenRD-Driver
  -> UART2
  -> 四路电机驱动板
```

这条短期链路用于公网实车验证。它不能替代长期 ROS2 safety + UART 架构，后续应把 `openrd-control-agent` 的底盘后端从 ESP32 HTTP proxy 切到 ROS2 `/openrd/drive_cmd` 或等效安全入口。

## 视频数据流

当前 v0.1 默认视频链路：

```text
/dev/openrd-cam-uvc
  -> RK3588 V4L2
  -> GStreamer v4l2src MJPG
  -> mppjpegdec
  -> mpph264enc
  -> h264parse
  -> flvmux
  -> rtmpsink rtmp://43.139.25.165:1935/live/openrd
  -> ZLMediaKit live/openrd
  -> RTSP:     rtsp://43.139.25.165/live/openrd
  -> HTTP-FLV: http://43.139.25.165:8888/live/openrd.live.flv
  -> Flutter Web / App / browser
```

说明：

- RTMP publisher 是车端 service 到腾讯云 ZLMediaKit 的默认链路；
- 本机 MediaMTX 保留为局域网 RTSP/WebRTC 回退调试链路；
- `openrd-video-native.service` 开机自启动，`mediamtx.service` 和 `rkaiq_3A.service` 按回退或 CSI 调试需要保留；
- `openrd-video-native` 默认关闭公网拉流健康重启，避免公网抖动导致频繁重启；需要时可通过 `OPENRD_VIDEO_RTMP_HEALTHCHECK_URL` 打开；
- 不建议为了“统一”而把低延迟驾驶视频强制改成 ROS2 `sensor_msgs/Image` 主链路；
- `openrd_video` 可以作为视频进程管理、状态上报、参数管理节点，而不是必须承载每一帧图像；
- RK3588 上的硬件视频进程运行在原生 Debian，ROS2 chroot 通过 `openrd-video-systemd` 管理宿主 `openrd-video-native.service`。

## 状态数据流

状态链路：

```text
ESP32 状态
  -> UART
  -> openrd_esp32_bridge_node
  -> /openrd/esp32_state
  -> openrd_state_node 或 openrd_web_bridge_node
  -> WebSocket state 消息
  -> Flutter 控制端显示
```

v0.1 状态建议包含：

- 车端连接状态；
- ROS2 节点运行状态；
- ESP32 连接状态；
- 最近控制命令序号；
- 是否处于急停；
- 是否处于超时停车；
- 可选电池电压；
- 可选电机输出值。

## 安全架构

安全保护分三层：

1. Flutter 控制端：松手归零、急停按钮、连接断开提示；
2. RK3588 ROS2：`openrd_safety_node` 超时、限幅、急停锁定；
3. ESP32 下位机：串口命令超时后独立停车。

最低要求：

- ESP32 的超时停车不能依赖 ROS2 或 RK3588 正常运行；
- 急停命令应优先级最高；
- 急停触发后，必须显式复位才能重新驾驶；
- 调试阶段应限制最大速度。

## 网络拓扑

基础 v0.1 局域网拓扑：

```text
电脑 / 手机
  -> 同一局域网 Wi-Fi / 有线网络
  -> RK3588 车端 IP
```

建议：

- RK3588 使用固定 IP 或 DHCP 保留地址；
- WebSocket 控制端口默认规划为 `8080`；
- ROS2 graph 默认只在车端本机运行；
- 初期不把 ROS2 DDS 暴露给外部网络；
- 基础局域网 MVP 不暴露任何端口到公网。

当前公网 Phase 1 拓扑：

```text
Flutter Web / 手机浏览器
  -> 43.139.25.165 openrd-control-service
RK3588 video/control agent
  -> 主动出站访问云端
RK3588 / ESP32 所在局域网
  -> 不暴露入站端口
```

公网阶段的原则是车端主动出站，前端只访问云端，不把 ESP32 HTTP、RK3588 SSH、ROS2 DDS 或其他局域网服务直接暴露到公网。

## 后续演进

### v0.2 视频增强

- 单路 IMX415 稳定采集；
- 低延迟编码；
- 浏览器端显示；
- 延迟测量。

### v0.3 控制体验增强

- 接入 G7 Pro 手柄；
- 虚拟摇杆优化；
- 状态面板；
- 日志记录。

### v0.4 公网能力

- 已提前完成 Phase 1：云端控制服务、ZLMediaKit 视频中继、RK3588 video/control agent、视频按需启停和底盘 HTTP proxy 控制；
- 后续补 token/session 鉴权、驾驶会话互斥、视频 ready gate 和状态面板；
- 引入 WebRTC；
- 部署 TURN；
- 评估 DataChannel 替换 WebSocket。

### v0.5 视觉与机器人能力

- YOLO/RKNN 检测；
- 检测结果 ROS2 topic 化；
- 编码器、里程计、IMU；
- TF、SLAM/Nav2 或其他机器人生态能力。
