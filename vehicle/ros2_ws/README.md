# OpenRD Vehicle ROS2 Workspace

这是 OpenRD 的 RK3588 车端 ROS2 workspace。

## Package 索引

- `src/openrd_msgs/README.md`：自定义消息定义；
- `src/openrd_bringup/README.md`：launch 与参数配置；
- `src/openrd_web_bridge/README.md`：WebSocket 与 ROS2 的桥接入口；
- `src/openrd_safety/README.md`：限幅、超时、急停状态机；
- `src/openrd_esp32_bridge/README.md`：ROS2 与 ESP32 UART 桥接；
- `src/openrd_video/README.md`：视频链路管理占位。

## Package

- `openrd_msgs`：自定义消息；
- `openrd_bringup`：launch 与参数配置；
- `openrd_web_bridge`：WebSocket 与 ROS2 的桥接入口，当前为骨架节点；
- `openrd_safety`：限幅、超时、急停状态机；
- `openrd_esp32_bridge`：ROS2 与 ESP32 UART 的桥接，当前默认 dry-run；
- `openrd_video`：视频链路管理，当前为占位节点。

## 预期构建

在安装 ROS2 的 Linux/RK3588 环境中执行：

```bash
cd vehicle/ros2_ws
colcon build --symlink-install
source install/setup.bash
ros2 launch openrd_bringup openrd_vehicle.launch.py
```

## 当前状态

当前 workspace 是 v0.1 骨架，重点先固定 ROS2 package、topic、message、launch 和 safety 基础逻辑。

代码中已经补充中文注释，优先解释节点职责、关键安全逻辑和后续 TODO，避免注释重复描述每一行实现。