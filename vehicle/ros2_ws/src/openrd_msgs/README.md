# openrd_msgs

`openrd_msgs` 定义 OpenRD 车端 ROS2 graph 内部使用的自定义消息。

## 职责

- 固定车端控制命令结构；
- 固定车辆状态结构；
- 固定 ESP32 下位机状态结构；
- 为 Flutter bridge、safety、ESP32 bridge 和后续感知模块提供统一接口。

## 当前消息

### DriveCommand

路径：`msg/DriveCommand.msg`

用途：表示归一化驾驶命令。

字段重点：

- `throttle`：油门，范围 `-1.0` 到 `1.0`；
- `steering`：转向，范围 `-1.0` 到 `1.0`；
- `brake`：刹车，范围 `0.0` 到 `1.0`；
- `enable`：是否允许驱动输出；
- `estop`：是否请求急停；
- `source`：命令来源，例如 `websocket`、`safety`、`test_cli`。

### VehicleState

路径：`msg/VehicleState.msg`

用途：表示车端聚合状态，主要给 Web bridge 和前端显示。

### Esp32State

路径：`msg/Esp32State.msg`

用途：表示 ESP32 下位机状态，当前由 `openrd_esp32_bridge` 发布。

### VideoState

路径：`msg/VideoState.msg`

用途：表示原生视频 runtime 的运行状态，由 `openrd_video` 发布。

## 设计原则

- 不直接使用 `geometry_msgs/Twist` 作为主控制命令，因为 OpenRD 需要 `brake`、`enable`、`estop` 等安全字段；
- 后续如果接入 Nav2 或键盘遥控，可以新增 `/cmd_vel -> /openrd/drive_cmd` 转换节点；
- 消息一旦被多个 package 使用，字段修改要谨慎，避免破坏兼容性。
