# openrd_esp32_bridge

`openrd_esp32_bridge` 负责连接 ROS2 和 ESP32 下位机。

## 职责

- 订阅安全后的驾驶命令 `safe_drive_cmd`；
- 将归一化控制值转换为 ESP32 UART 文本协议；
- 后续负责打开串口并写入命令；
- 后续负责解析 ESP32 状态行并发布 `esp32_state`；
- 当前默认 dry-run，用日志和模拟状态帮助前期联调。

## 输入

```text
safe_drive_cmd  openrd_msgs/msg/DriveCommand
```

## 输出

```text
esp32_state  openrd_msgs/msg/Esp32State
```

## UART 命令格式

当前规划的驾驶命令：

```text
D,<seq>,<throttle_i>,<steering_i>,<brake_i>,<flags>\n
```

示例：

```text
D,120,400,-100,0,1
D,121,0,0,1000,1
D,122,0,0,1000,2
```

## 参数

- `port`：串口设备，默认 `/dev/ttyS0`；
- `baudrate`：波特率，默认 `115200`；
- `dry_run`：是否只模拟不写串口，默认 `true`；
- `esp32_timeout_ms`：ESP32 超时参考值，默认 `500`；
- `publish_hz`：状态发布频率，默认 `20.0`。

## 后续实现重点

- 使用真实串口库或 POSIX 串口接口；
- 处理串口重连；
- 解析 ESP32 `S` 状态行；
- 把串口异常上报到 `vehicle_state`；
- 确保不会绕过 `openrd_safety` 接收原始控制命令。