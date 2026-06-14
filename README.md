# OpenRD

OpenRD 是一个开放式远程驾驶项目，全称暂定为 **Open Remote Driving**。

项目目标是基于正点原子 ATK-DLRK3588B 开发板、ATK-IMX415 摄像头、ESP32 下位机、电机底盘以及 Flutter 控制端，构建一套可以在局域网内稳定运行，并逐步扩展到公网远程驾驶、视频回传和视觉检测的移动小车系统。

## 项目定位

OpenRD 不是单纯的视频小车，也不是只做 AI 检测的演示项目。它的核心目标是构建一个可扩展的远程驾驶系统，包含：

- 车端 ROS2-first 运行时；
- 车端视频采集与低延迟回传；
- 浏览器、Android、iOS 多端控制；
- 手柄与触屏两类输入方式；
- ESP32 下位机电机控制与安全保护；
- 后续可扩展的公网访问、TURN/WebRTC 中继、YOLO/RKNN、里程计、SLAM/Nav2 等能力。

## 当前硬件

- 车端主控：正点原子 ATK-DLRK3588B；
- 摄像头：2 个 ATK-IMX415；
- 下位机：ESP32；
- 控制输入：盖世小鸡 G7 Pro 无线手柄；
- 移动端：Android 手机、iPhone；
- 控制端：本机电脑浏览器 + Flutter 应用；
- 执行机构：底盘 + 电机 + 电机驱动模块。

## MVP 目标

第一阶段只做局域网 MVP，不直接引入公网、双摄、YOLO 或复杂云端架构。

MVP 成功标准：

- 控制端可以连接车端；
- 控制端可以发送前、后、左、右、停等基础驾驶指令；
- RK3588 上的 ROS2 节点可以接收控制命令；
- ROS2 内部控制 topic 可以完成从 WebSocket bridge 到 safety 再到 ESP32 bridge 的流转；
- RK3588 可以通过 UART 将安全后的控制命令转发给 ESP32；
- ESP32 可以控制电机完成基础动作；
- 控制链路断开或超时时，小车可以自动停车；
- 单路摄像头视频可以在控制端显示，用于辅助驾驶。

## 初始技术路线

### 车端

- 运行平台：ATK-DLRK3588B Linux；
- 车端框架：ROS2-first；
- 节点语言：优先 C++ / `rclcpp`；
- 职责：WebSocket 控制桥接、安全状态机、ESP32 串口桥接、状态聚合、后续视频管理与视觉检测；
- 与 ESP32 通信：优先使用 UART 串口；
- 说明：视频回传不强制走 ROS2 image topic，低延迟驾驶视频优先保留 GStreamer/RTSP/WebRTC 路线。

### 下位机

- 运行平台：ESP32；
- 职责：电机 PWM、方向控制、急停、控制超时保护；
- 安全策略：ESP32 必须独立实现控制超时自动停车。

### 控制端

- 前端框架：Flutter；
- 支持平台：Web、Android、iOS；
- 初期控制输入：浏览器 + 手柄、手机触屏；
- 初期控制链路：WebSocket；
- 后续升级方向：WebRTC DataChannel；
- 说明：Flutter 不直接接入 ROS2 DDS，而是通过 WebSocket/DataChannel bridge 与车端 ROS2 graph 通信。

### 视频链路

- 当前默认：单路前摄 `/dev/openrd-cam-front`，也就是当前板端 `/dev/video22` / `rkisp0-vir0`，GStreamer 直接以 RTSP publisher 推送到本机 MediaMTX 的 `live` 路径；
- 局域网 RTSP 调试地址：`rtsp://192.168.100.108:8554/live`；
- 浏览器 WebRTC 播放地址：`http://192.168.100.108:8889/live/`；
- `openrd-video-native.service`、`mediamtx.service`、`rkaiq_3A.service` 均启用 systemd 开机自启动；
- 视频 watchdog 使用真实 RTSP 读帧健康检查；默认只做有限自恢复，仍失败时进入 `faulted` 并停止 systemd 自动重启，避免持续反复拉起不稳定的 camera/ISP 链路；
- 公网阶段：WebRTC + TURN/中继。

## 推荐目录结构

```text
OpenRD/
  README.md
  docs/        # 架构、协议、硬件接线、阶段计划
  frontend/    # Flutter Web / Android / iOS 控制端
  vehicle/     # RK3588 ROS2 workspace、原生视频 runtime 与车端节点
  firmware/    # ESP32 下位机固件
  server/      # WebSocket、信令、中转服务
  infra/       # VPS、TURN、Docker、部署配置
  models/      # YOLO / RKNN 模型与转换说明
  tools/       # 调试脚本、延迟测试、手柄测试工具
```

建议的车端 ROS2 workspace：

```text
vehicle/
  ros2_ws/
    src/
      openrd_msgs/           # 自定义 msg / srv
      openrd_bringup/        # launch、参数、启动配置
      openrd_web_bridge/     # WebSocket <-> ROS2
      openrd_safety/         # 限幅、超时、急停状态机
      openrd_esp32_bridge/   # ROS2 <-> UART <-> ESP32
      openrd_video/          # 原生视频 runtime 管理、状态上报与后续 RTSP/WebRTC 接口
```

## 阶段计划

### v0.1：局域网基础驾驶闭环

- 建立项目 workspace 和文档；
- 建立 `vehicle/ros2_ws` 与基础 ROS2 packages；
- 定义 WebSocket、ROS2 topic、UART 三段控制协议；
- 实现 Flutter 控制端基础 UI；
- 实现 `openrd_web_bridge_node` 接收 WebSocket 控制命令；
- 实现 `openrd_safety_node` 处理限幅、超时、急停；
- 实现 `openrd_esp32_bridge_node` 转发 UART 命令；
- 实现 ESP32 电机控制与超时停车；
- 完成前、后、左、右、停的基础驾驶。

### v0.2：单路视频回传

- 验证 ATK-IMX415 在 RK3588 上的采集；
- 验证硬件编码链路；
- 实现控制端视频显示；
- 初步评估端到端延迟。

### v0.3：控制体验优化

- 接入 G7 Pro 手柄输入；
- 优化触屏虚拟摇杆；
- 增加心跳、重连、急停、限速；
- 记录控制日志和状态信息。

### v0.4：公网与 WebRTC

- 引入 WebRTC 视频链路；
- 引入信令服务；
- 规划 TURN 中继；
- 评估 WebSocket 控制升级到 WebRTC DataChannel。

### v0.5：视觉检测与机器人能力

- 选择轻量 YOLO 模型；
- 转换 RKNN；
- 在 RK3588 NPU 上运行检测；
- 将检测结果叠加或作为元数据发送到控制端；
- 根据需要扩展 ROS2 topic，接入里程计、TF、SLAM/Nav2 等能力。

## 当前原则

- 车端采用 ROS2-first 架构，避免后续重复重构；
- 先跑通局域网闭环，再做公网能力；
- 先实现单摄，再扩展双摄；
- 先实现基础驾驶，再优化控制体验；
- 先保证安全停车，再追求性能；
- 视频、控制、电机、安全保护分层设计；
- 控制协议尽量与具体传输方式解耦，便于后续从 WebSocket 升级到 WebRTC DataChannel；
- 不把低延迟视频强行塞进 ROS2 topic，视频链路按驾驶体验单独优化。

## 核心文档

当前已落盘以下核心文档：

- `docs/00_project_brief.md`：项目目标、边界和阶段定义；
- `docs/01_architecture.md`：整体架构和模块职责；
- `docs/02_mvp_plan.md`：局域网 MVP 实施计划；
- `docs/03_control_protocol.md`：WebSocket、ROS2 topic、UART 控制协议；
- `docs/04_vehicle_ros2_architecture.md`：RK3588 车端 ROS2-first 架构；
- `docs/05_rk3588_deployment.md`：RK3588 原生视频与 ROS2 chroot 部署边界。`vehicle/native_video/README.md` 记录原生视频 runtime，`openrd_video_node` 负责管理它。

## 下一步

建议下一步开始搭建 `vehicle/ros2_ws`，优先创建 `openrd_msgs`、`openrd_web_bridge`、`openrd_safety`、`openrd_esp32_bridge` 和 `openrd_bringup` 的基础骨架。
