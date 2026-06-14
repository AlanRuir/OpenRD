# 01 系统架构

本文档描述 OpenRD 的整体架构、模块职责、数据流和后续演进方向。

## 总体架构

OpenRD v0.1 采用局域网 ROS2-first 车端架构。

```text
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
- 连接 RK3588 WebSocket 控制入口；
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

v0.1 控制链路：

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

## 视频数据流

当前 v0.1 默认视频链路：

```text
ATK-IMX415
  -> RK3588 camera / ISP / V4L2
  -> GStreamer v4l2src
  -> mpph264enc
  -> h264parse
  -> rtspclientsink rtsp://127.0.0.1:8554/live
  -> MediaMTX live
  -> RTSP:   rtsp://192.168.100.108:8554/live
  -> WebRTC: http://192.168.100.108:8889/live/
  -> Flutter Web / App / browser
```

说明：

- RTSP publisher 是车端 service 到 MediaMTX 的默认链路；
- WebRTC 是当前浏览器播放入口，MediaMTX 从同一路 `live` 转发；
- `openrd-video-native.service`、`mediamtx.service`、`rkaiq_3A.service` 均开机自启动；
- `openrd-video-native` 使用真实 RTSP 读帧健康检查，断流后自动重启 runtime，连续失败时重启 `rkaiq_3A.service`；
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

v0.1 局域网拓扑：

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
- 初期不暴露任何端口到公网。

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

- 引入信令服务；
- 引入 WebRTC；
- 部署 TURN；
- 评估 DataChannel 替换 WebSocket。

### v0.5 视觉与机器人能力

- YOLO/RKNN 检测；
- 检测结果 ROS2 topic 化；
- 编码器、里程计、IMU；
- TF、SLAM/Nav2 或其他机器人生态能力。
