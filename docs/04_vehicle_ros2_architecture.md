# 04 车端 ROS2 架构

本文档专门定义 RK3588 车端的 ROS2-first 架构，作为后续创建 `vehicle/ros2_ws` 的依据。

## 架构原则

- 车端从 v0.1 开始采用 ROS2-first；
- 每个 ROS2 node 只负责一类明确职责；
- Flutter 不直接接 ROS2 DDS，而是通过 bridge 进入 ROS2 graph；
- ESP32 仍是最终电机安全保护层；
- 视频链路不强制 ROS2 化，低延迟驾驶视频优先走 GStreamer/RTSP/WebRTC；
- 所有安全相关默认值必须保守，调试阶段默认限速。

## Workspace 结构

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

## Package 说明

### openrd_msgs

职责：定义 OpenRD 车端内部接口。

v0.1 建议包含：

- `msg/DriveCommand.msg`；
- `msg/VehicleState.msg`；
- `msg/Esp32State.msg`。

后续可扩展：

- `msg/Detection2D.msg`；
- `msg/BatteryState.msg`；
- `srv/ResetEstop.srv`；
- `srv/SetDriveMode.srv`。

### openrd_bringup

职责：统一启动和参数管理。

v0.1 建议包含：

- `launch/openrd_vehicle.launch.py`；
- `config/vehicle.yaml`；
- `config/safety.yaml`；
- `config/serial.yaml`；
- `config/web_bridge.yaml`。

### openrd_web_bridge

职责：外部控制协议与 ROS2 graph 的桥接。

节点：

```text
openrd_web_bridge_node
```

输入：

- WebSocket JSON：`hello`、`drive`、`ping`、`estop`、`reset_estop`。

输出：

- `/openrd/drive_cmd`；
- `/openrd/reset_estop` service call；
- WebSocket `state` / `hello_ack` / `pong`。

### openrd_safety

职责：RK3588 层安全状态机。

节点：

```text
openrd_safety_node
```

输入：

- `/openrd/drive_cmd`；
- `/openrd/reset_estop`；
- 可选 `/openrd/esp32_state`。

输出：

- `/openrd/safe_drive_cmd`；
- `/openrd/vehicle_state` 或安全状态字段。

核心逻辑：

- 输入限幅；
- 死区处理；
- 最大速度限制；
- 控制超时停车；
- 急停锁定；
- 急停复位条件检查。

### openrd_esp32_bridge

职责：ROS2 与 ESP32 UART 桥接。

节点：

```text
openrd_esp32_bridge_node
```

输入：

- `/openrd/safe_drive_cmd`。

输出：

- UART `D` / `R` / `P` 命令；
- `/openrd/esp32_state`。

核心逻辑：

- 打开和维护串口；
- 将归一化控制值转换为整数值；
- 解析 ESP32 状态行；
- 上报串口异常；
- 不绕过 safety node 接受原始控制命令。

### openrd_video

职责：原生视频 runtime 管理。

当前实现：

- 调用 `vehicle/native_video/openrd-video-systemd`；
- 发布 `/openrd/video_state`；
- 暴露 `start_runtime`、`stop_runtime`、`restart_runtime` service；
- 读取 runtime 的 JSON 状态并转成 ROS2 message。

部署边界：

- `openrd_video_node` 运行在 Ubuntu 22.04 chroot；
- `openrd-video-systemd` 负责在 chroot 内调用宿主 `systemctl`；
- `openrd-video-native.service` 和真正的 GStreamer / MPP 编码进程运行在 RK3588 原生 Debian。
- `openrd-video-native.service` 默认以 `rtsp` publisher 模式把 `/dev/openrd-cam-rear` 推送到 MediaMTX `live`；
- `mediamtx.service` 把同一路 `live` 暴露为 `rtsp://192.168.100.108:8554/live` 和 `http://192.168.100.108:8889/live/`；
- `openrd-video-native.service`、`mediamtx.service`、`rkaiq_3A.service` 均应保持开机自启动；
- 视频 watchdog 使用真实 RTSP 读帧健康检查，连续失败时先重启视频 runtime，再联动重启 `rkaiq_3A.service`。

不建议职责：

- v0.1 不把每帧驾驶视频强制发布为 ROS2 image topic；
- 不把硬件视频链路塞进 Ubuntu chroot；
- 不让视频处理阻塞控制链路。

## Topic 约定

```text
/openrd/drive_cmd          openrd_msgs/msg/DriveCommand
/openrd/safe_drive_cmd     openrd_msgs/msg/DriveCommand
/openrd/vehicle_state      openrd_msgs/msg/VehicleState
/openrd/esp32_state        openrd_msgs/msg/Esp32State
/openrd/video_state        openrd_msgs/msg/VideoState
```

## Service 约定

```text
/openrd/reset_estop        std_srvs/srv/Trigger
/openrd/start_runtime      std_srvs/srv/Trigger
/openrd/stop_runtime       std_srvs/srv/Trigger
/openrd/restart_runtime    std_srvs/srv/Trigger
```

后续如果 `std_srvs/srv/Trigger` 不够表达，可以切换到自定义 service。

## 参数约定

### web_bridge

- `listen_host`：默认 `0.0.0.0`；
- `listen_port`：默认 `8080`；
- `control_path`：默认 `/control`；
- `client_timeout_ms`：默认 `300`。

### safety

- `control_timeout_ms`：默认 `300`；
- `max_output`：默认 `0.4`；
- `deadzone`：默认 `0.05`；
- `max_accel_per_sec`：后续可启用；
- `require_zero_before_reset_estop`：默认 `true`。

### serial

- `port`：待按 RK3588 实际串口确认；
- `baudrate`：默认 `115200`；
- `esp32_timeout_ms`：默认 `500`；
- `line_ending`：默认 `\n`。

## 启动方式

v0.1 目标启动方式：

```text
ros2 launch openrd_bringup openrd_vehicle.launch.py
```

该 launch 应启动：

- `openrd_web_bridge_node`；
- `openrd_safety_node`；
- `openrd_esp32_bridge_node`；
- 可选 `openrd_state_node`；
- `openrd_video_node`。

## ROS2 发行版选择

当前不在文档中强行锁死 ROS2 发行版，先按 RK3588 实际系统镜像决定：

- 如果车端系统是 Ubuntu 22.04，优先考虑 ROS2 Humble；
- 如果车端系统是 Ubuntu 24.04，优先考虑 ROS2 Jazzy；
- 如果使用其他 Debian/Ubuntu 派生镜像，需要验证官方包、源码构建或容器方案。

## 与标准 ROS2 生态的关系

v0.1 使用自定义 `DriveCommand`，因为它包含 `brake`、`enable`、`estop` 等驾驶安全字段。

后续如果需要接入标准机器人生态，可以新增转换节点：

```text
/cmd_vel geometry_msgs/msg/Twist
  -> openrd_cmd_vel_bridge_node
  -> /openrd/drive_cmd openrd_msgs/msg/DriveCommand
```

这样既保留 OpenRD 的安全字段，又可以兼容 Nav2、键盘遥控、仿真等标准工具。

## 实现顺序

建议实现顺序：

1. `openrd_msgs`；
2. `openrd_safety_node`，先用命令行 topic 测试；
3. `openrd_esp32_bridge_node`，先不接电机，只看串口日志；
4. `openrd_web_bridge_node`；
5. `openrd_bringup` launch；
6. Flutter 控制端联调；
7. 视频链路验证。

## 不变的安全底线

- ESP32 上电默认停车；
- ESP32 必须独立实现串口超时停车；
- ROS2 节点崩溃时，ESP32 必须自动停车；
- 急停必须显式复位；
- 调试阶段默认限速；
- 真实落地测试前必须先架空轮子验证方向和急停。
