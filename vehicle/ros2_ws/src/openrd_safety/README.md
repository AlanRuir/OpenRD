# openrd_safety

`openrd_safety` 是 RK3588 车端的上层安全节点。

## 职责

- 订阅原始驾驶命令 `drive_cmd`；
- 处理限幅、死区、刹车、控制超时；
- 处理急停锁定和急停复位；
- 发布安全后的驾驶命令 `safe_drive_cmd`；
- 发布车辆聚合状态 `vehicle_state`。

## 输入

```text
drive_cmd    openrd_msgs/msg/DriveCommand
reset_estop  std_srvs/srv/Trigger
```

## 输出

```text
safe_drive_cmd  openrd_msgs/msg/DriveCommand
vehicle_state   openrd_msgs/msg/VehicleState
```

## 安全规则

- 没有收到控制命令时，输出停车；
- 超过 `control_timeout_ms` 没收到新命令时，输出停车；
- 收到 `estop=true` 后进入急停锁定；
- 急停复位默认要求输入归零；
- 输出值会被 `max_output` 限制，调试阶段默认不超过 40%。

## 参数

- `control_timeout_ms`：控制超时时间，默认 `300`；
- `publish_hz`：安全命令发布频率，默认 `20.0`；
- `max_output`：最大输出比例，默认 `0.4`；
- `deadzone`：摇杆死区，默认 `0.05`；
- `require_zero_before_reset_estop`：急停复位前是否要求输入归零，默认 `true`。

## 边界

该节点不能替代 ESP32 固件里的独立超时停车。即使 ROS2 节点崩溃，ESP32 也必须在自己的超时时间内停车。