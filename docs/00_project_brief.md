# 00 项目简述

本文档定义 OpenRD 的项目目标、边界、MVP 成功标准和当前阶段的基本约束。

## 项目名称

OpenRD = Open Remote Driving。

OpenRD 是一个开放式远程驾驶项目，当前目标是使用正点原子 ATK-DLRK3588B、ATK-IMX415 摄像头、ESP32 下位机、Flutter 控制端和电机底盘，构建一套可逐步演进的远程驾驶小车系统。

## 当前目标

当前阶段只面向局域网 MVP，目标不是一次性完成所有能力，而是先跑通最小驾驶闭环。

MVP 目标：

- 控制端可以连接车端；
- 控制端可以发出前、后、左、右、停等基础驾驶指令；
- RK3588 上的 ROS2 节点可以稳定接收控制命令；
- ROS2 内部控制 topic 可以完成从 WebSocket bridge 到 safety 再到 ESP32 bridge 的流转；
- RK3588 可以通过 UART 将安全后的控制命令转发给 ESP32；
- ESP32 可以驱动电机完成基础动作；
- 控制链路中断或超时时，小车可以自动停车；
- 单路摄像头视频可以回传到控制端用于辅助驾驶。

## 当前不做什么

为了降低第一阶段复杂度，以下内容不纳入 v0.1 MVP：

- 不做公网远程驾驶；
- 不做 TURN/STUN/WebRTC 公网穿透；
- 不做双摄同时回传；
- 不做 YOLO/RKNN 视觉检测；
- 不做自动驾驶或路径规划；
- 不做完整 SLAM/Nav2 集成；
- 不做复杂账号系统和云端权限系统；
- 不让 Flutter 直接接入 ROS2 DDS；
- 不把驾驶视频强制封装为 ROS2 image topic；
- 不追求极限低延迟，只要求局域网内可驾驶、可调试、可扩展。

## 核心硬件

- 车端主控：正点原子 ATK-DLRK3588B；
- 摄像头：ATK-IMX415，第一阶段只使用一路；
- 下位机：ESP32；
- 控制输入：盖世小鸡 G7 Pro 无线手柄、手机触屏；
- 控制端：电脑浏览器、Android 手机、iPhone；
- 执行机构：底盘、电机、电机驱动模块。

## 软件分层

OpenRD 当前按以下层次组织：

- `frontend/`：Flutter 控制端，负责 UI、手柄/触屏输入、视频显示和控制命令发送；
- `vehicle/`：RK3588 ROS2 workspace，负责 WebSocket bridge、安全状态机、ESP32 串口桥接、状态聚合、后续视频管理与视觉检测；
- `firmware/`：ESP32 固件，负责电机控制、超时停车、底层安全保护；
- `server/`：后续信令、中转或控制服务，v0.1 可为空；
- `docs/`：项目文档、协议、架构和实施计划；
- `infra/`：公网和部署相关配置，v0.1 可为空；
- `models/`：后续 YOLO/RKNN 模型文件和转换说明；
- `tools/`：调试、测试、部署辅助工具。

## 车端 ROS2-first 决策

OpenRD 车端从 v0.1 开始采用 ROS2-first 架构。

原因：

- 后续可能接入里程计、IMU、雷达、SLAM/Nav2、YOLO 检测等机器人能力；
- ROS2 topic/service/parameter/launch 适合组织车端模块；
- 控制、安全、串口桥接、状态聚合可以自然拆成独立节点；
- 可以避免先写普通车端进程、后续再重构成 ROS2 的重复工作。

约束：

- ROS2-first 不代表所有数据都必须走 ROS2；
- Flutter 仍通过 WebSocket 或未来 DataChannel 与车端通信；
- 低延迟视频链路优先使用 GStreamer/RTSP/WebRTC，不强制走 ROS2 image topic；
- ESP32 的超时停车仍是最后安全保护，不能依赖 ROS2 正常运行。

## 关键原则

- 安全优先：小车失联必须自动停车；
- 分层清晰：Flutter、RK3588 ROS2、ESP32 各司其职；
- 先简单闭环，再逐步增强；
- 控制协议与传输方式解耦；
- v0.1 使用 WebSocket，未来可升级 WebRTC DataChannel；
- v0.1 使用单摄，未来可扩展双摄；
- v0.1 使用局域网，未来可扩展公网；
- 车端节点优先使用 C++ / `rclcpp`。

## MVP 验收标准

v0.1 MVP 通过需要满足以下条件：

- Flutter Web 或调试控制端能连接 RK3588 车端；
- 控制端能以固定频率发送控制命令；
- `openrd_web_bridge_node` 能发布 `/openrd/drive_cmd`；
- `openrd_safety_node` 能发布 `/openrd/safe_drive_cmd`；
- `openrd_esp32_bridge_node` 能通过 UART 转发到 ESP32；
- ESP32 能解析命令并输出电机控制信号；
- 小车能完成前进、后退、左转、右转、停车；
- 控制端停止发送命令后，ESP32 能在约定超时时间内停车；
- 急停命令可以让小车立即停车；
- 基础状态可以回传到控制端或日志中；
- 单路摄像头视频链路至少完成一次端到端验证。

## 风险列表

- RK3588 当前系统镜像的 ROS2 发行版兼容性需要确认；
- ROS2 安装、交叉编译或本机编译流程需要规范化；
- 视频链路延迟过高，影响驾驶体验；
- RK3588 摄像头驱动、编码、推流链路需要单独验证；
- ESP32 与电机驱动模块的接线和供电需要可靠；
- 电机启动电流可能影响控制板供电；
- 浏览器手柄输入在不同浏览器上的表现可能不同；
- Windows、WSL、RK3588 三个环境的构建和部署路径需要后续规范化。

## 当前决策

- Workspace 路径：`D:\Projects\OpenRD`；
- 项目文档使用中文；
- 车端采用 ROS2-first 架构；
- 车端节点优先使用 C++ / `rclcpp`；
- 控制端使用 Flutter 单工程支持 Web、Android、iOS；
- 控制链路 v0.1 使用 WebSocket；
- 电机控制使用 ESP32 下位机；
- RK3588 与 ESP32 优先使用 UART 通信；
- 公网、WebRTC、YOLO 放到后续阶段。