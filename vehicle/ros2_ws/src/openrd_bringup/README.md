# openrd_bringup

`openrd_bringup` 负责统一启动 OpenRD 车端 ROS2 节点，并集中管理参数配置。

## 职责

- 提供车端 launch 文件；
- 维护 Web bridge、safety、serial、vehicle 等参数文件；
- 作为 RK3588 车端运行入口。

## 当前文件

- `launch/openrd_vehicle.launch.py`：启动车端主要节点；
- `config/vehicle.yaml`：车辆通用参数；
- `config/web_bridge.yaml`：WebSocket bridge 参数；
- `config/safety.yaml`：安全策略参数；
- `config/serial.yaml`：ESP32 串口参数。
- `config/video.yaml`：原生视频 runtime 参数。

## 预期启动方式

```bash
cd vehicle/ros2_ws
colcon build --symlink-install
source install/setup.bash
ros2 launch openrd_bringup openrd_vehicle.launch.py
```

## 默认节点

Launch 默认启动：

- `openrd_web_bridge_node`；
- `openrd_safety_node`；
- `openrd_esp32_bridge_node`；
- `openrd_video_node`。

## 注意事项

- 当前 `serial.yaml` 默认 `dry_run: true`，不会真实打开串口；
- 接入真实 ESP32 前，需要确认 RK3588 上的串口设备名；
- 调试阶段建议保持 `safety.yaml` 中的 `max_output: 0.4` 或更低。
