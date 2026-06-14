# 03 控制协议

本文档定义 OpenRD v0.1 的控制协议。协议分为三段：控制端到 RK3588 的 WebSocket JSON 协议、RK3588 内部 ROS2 topic/service 协议，以及 RK3588 到 ESP32 的 UART 文本协议。

## 设计目标

- 简单可调试；
- 控制命令可连续发送；
- 支持前、后、左、右、停；
- 支持急停和超时停车；
- 支持基础状态回传；
- 不把上层控制逻辑绑定到具体传输方式；
- 后续可以从 WebSocket 平滑升级到 WebRTC DataChannel；
- 车端内部从 v0.1 开始采用 ROS2-first 接口，避免后续重构。

## 控制模型

OpenRD 使用归一化控制模型：

- `throttle`：油门，范围 `-1.0` 到 `1.0`；
- `steering`：转向，范围 `-1.0` 到 `1.0`；
- `brake`：刹车，范围 `0.0` 到 `1.0`；
- `enable`：是否允许驱动输出；
- `estop`：是否触发急停。

含义：

- `throttle > 0`：前进；
- `throttle < 0`：后退；
- `steering < 0`：左转；
- `steering > 0`：右转；
- `throttle = 0` 且 `steering = 0`：停车或保持静止；
- `brake = 1.0`：强制停车；
- `estop = true`：进入急停锁定状态。

## 默认控制频率

- 控制端目标发送频率：20 Hz；
- 允许最高发送频率：50 Hz；
- 控制端必须持续发送当前控制状态，而不是只在输入变化时发送；
- 控制端松手后应持续发送若干帧归零命令；
- `openrd_safety_node` 超过 300 ms 没收到有效控制命令，应发布停车命令；
- ESP32 超过 500 ms 没收到有效 `D` 命令，应独立停车。

## WebSocket 协议

### 连接地址

v0.1 默认地址：

```text
ws://<vehicle-ip>:8080/control
```

WebSocket 服务由 `openrd_web_bridge_node` 提供。

### 通用字段

所有 WebSocket JSON 消息建议包含：

- `type`：消息类型；
- `version`：协议版本，v0.1 使用 `1`；
- `seq`：发送端递增序号，使用非负整数；
- `client_time_ms` 或 `server_time_ms`：发送端本地毫秒时间戳，用于日志和延迟估计，不用于安全判断。

### hello

控制端连接后发送：

```json
{
  "type": "hello",
  "version": 1,
  "seq": 1,
  "client_id": "flutter-web-001",
  "client_name": "OpenRD Flutter Web",
  "client_time_ms": 1710000000000
}
```

车端回应：

```json
{
  "type": "hello_ack",
  "version": 1,
  "seq": 1,
  "server_time_ms": 1710000000100,
  "vehicle_name": "openrd-rk3588",
  "control_hz": 20,
  "rk3588_timeout_ms": 300,
  "esp32_timeout_ms": 500
}
```

### drive

控制端持续发送驾驶命令：

```json
{
  "type": "drive",
  "version": 1,
  "seq": 120,
  "client_time_ms": 1710000001000,
  "throttle": 0.5,
  "steering": -0.2,
  "brake": 0.0,
  "enable": true,
  "estop": false
}
```

字段约束：

- `throttle` 必须限制在 `[-1.0, 1.0]`；
- `steering` 必须限制在 `[-1.0, 1.0]`；
- `brake` 必须限制在 `[0.0, 1.0]`；
- `enable = false` 时，ROS2 safety 层必须输出停车命令；
- `estop = true` 时，ROS2 safety 层必须进入急停锁定，并最终让 ESP32 急停。

常见动作映射：

| 动作 | throttle | steering | brake | enable | estop |
| --- | ---: | ---: | ---: | --- | --- |
| 停车 | 0.0 | 0.0 | 1.0 | true | false |
| 前进 | 0.4 | 0.0 | 0.0 | true | false |
| 后退 | -0.4 | 0.0 | 0.0 | true | false |
| 左转 | 0.2 | -0.5 | 0.0 | true | false |
| 右转 | 0.2 | 0.5 | 0.0 | true | false |
| 急停 | 0.0 | 0.0 | 1.0 | false | true |

### ping / pong

控制端可定期发送 ping：

```json
{
  "type": "ping",
  "version": 1,
  "seq": 200,
  "client_time_ms": 1710000002000
}
```

车端回应：

```json
{
  "type": "pong",
  "version": 1,
  "seq": 200,
  "server_time_ms": 1710000002050
}
```

说明：

- `ping/pong` 用于显示连接质量；
- `ping/pong` 不能替代 `drive` 控制命令；
- 只有持续有效的 `drive` 命令才能保持车辆可驾驶。

### estop

控制端可以单独发送急停消息：

```json
{
  "type": "estop",
  "version": 1,
  "seq": 300,
  "client_time_ms": 1710000003000,
  "reason": "user_pressed_button"
}
```

要求：

- `openrd_web_bridge_node` 收到后必须通知 ROS2 safety 层；
- `openrd_safety_node` 必须立即进入急停锁定；
- `openrd_esp32_bridge_node` 必须向 ESP32 发送急停命令；
- ESP32 收到急停后进入锁定状态；
- 急停状态必须通过显式复位解除。

### reset_estop

控制端可以请求解除急停：

```json
{
  "type": "reset_estop",
  "version": 1,
  "seq": 301,
  "client_time_ms": 1710000004000
}
```

要求：

- 只有在控制输入归零时才允许解除急停；
- `openrd_safety_node` 应先确认当前为等效停车状态；
- ESP32 解除急停后仍保持停车，直到收到新的有效 `drive` 命令。

### state

车端向控制端发送状态消息：

```json
{
  "type": "state",
  "version": 1,
  "seq": 500,
  "server_time_ms": 1710000005000,
  "vehicle_state": "drive",
  "ws_connected": true,
  "ros2_ok": true,
  "esp32_connected": true,
  "last_drive_seq": 120,
  "failsafe": false,
  "estop": false,
  "battery_mv": null,
  "left_output": 0.45,
  "right_output": 0.35
}
```

`vehicle_state` 可选值：

- `boot`：启动中；
- `idle`：空闲；
- `drive`：可驾驶；
- `timeout`：控制超时停车；
- `estop`：急停锁定；
- `fault`：故障。

## ROS2 内部接口

### 命名空间

v0.1 默认使用命名空间：

```text
/openrd
```

### topic

```text
/openrd/drive_cmd          openrd_msgs/msg/DriveCommand
/openrd/safe_drive_cmd     openrd_msgs/msg/DriveCommand
/openrd/vehicle_state      openrd_msgs/msg/VehicleState
/openrd/esp32_state        openrd_msgs/msg/Esp32State
```

### service

```text
/openrd/reset_estop        std_srvs/srv/Trigger
```

v0.1 可以先使用 `std_srvs/srv/Trigger`，后续如果需要携带更多复位原因、操作者、确认码，再改为自定义 service。

### DriveCommand

建议定义：

```text
uint32 seq
builtin_interfaces/Time stamp
float32 throttle
float32 steering
float32 brake
bool enable
bool estop
string source
```

字段说明：

- `seq`：控制命令序号；
- `stamp`：进入 ROS2 graph 的时间；
- `throttle`、`steering`、`brake`：归一化控制值；
- `enable`：是否允许驱动输出；
- `estop`：是否请求急停；
- `source`：命令来源，例如 `websocket`、`test_cli`、`cmd_vel_bridge`。

### VehicleState

建议定义：

```text
uint32 seq
builtin_interfaces/Time stamp
string state
bool ws_connected
bool ros2_ok
bool esp32_connected
uint32 last_drive_seq
bool failsafe
bool estop
int32 battery_mv
float32 left_output
float32 right_output
string message
```

### Esp32State

建议定义：

```text
uint32 seq
builtin_interfaces/Time stamp
string state
uint32 last_drive_seq
uint32 faults
int32 battery_mv
float32 left_output
float32 right_output
```

### QoS 建议

- `/openrd/drive_cmd`：`keep_last(1)`，不堆积旧控制命令；
- `/openrd/safe_drive_cmd`：`keep_last(1)`，不堆积旧安全命令；
- `/openrd/vehicle_state`：`keep_last(1)`；
- `/openrd/esp32_state`：`keep_last(1)`；
- 是否 reliable 可按实际测试调整，但 safety 逻辑不能依赖队列补发旧命令；
- 超时判断由 `openrd_safety_node` 和 ESP32 独立实现。

## UART 协议

RK3588 与 ESP32 使用 UART 文本行协议。每条命令以换行符结束。

推荐串口参数：

- 波特率：`115200`；
- 数据位：8；
- 停止位：1；
- 校验：无；
- 行结束：`\n`，兼容忽略 `\r`。

### 数值映射

ROS2 `DriveCommand` 归一化浮点值转 UART 整数值：

- `throttle_i = round(throttle * 1000)`；
- `steering_i = round(steering * 1000)`；
- `brake_i = round(brake * 1000)`。

范围：

- `throttle_i`：`-1000` 到 `1000`；
- `steering_i`：`-1000` 到 `1000`；
- `brake_i`：`0` 到 `1000`。

### D：驾驶命令

格式：

```text
D,<seq>,<throttle_i>,<steering_i>,<brake_i>,<flags>\n
```

字段：

- `seq`：命令序号；
- `throttle_i`：油门整数值；
- `steering_i`：转向整数值；
- `brake_i`：刹车整数值；
- `flags`：位标志。

`flags` 定义：

- bit0：`enable`，1 表示允许驱动输出；
- bit1：`estop`，1 表示急停；
- bit2-bit31：保留，必须发送 0。

示例：

```text
D,120,500,-200,0,1
D,121,0,0,1000,1
D,122,0,0,1000,2
```

含义：

- 第一行：前进并略向左；
- 第二行：正常停车；
- 第三行：急停。

### R：解除急停

格式：

```text
R,<seq>\n
```

要求：

- ESP32 只有在当前电机输出为 0 时才允许解除急停；
- 解除急停后仍保持停车；
- 下一条有效 `D` 命令才能重新进入驾驶状态。

### P：串口 ping

格式：

```text
P,<seq>\n
```

ESP32 应回传状态行。

### S：状态回传

ESP32 向 RK3588 回传：

```text
S,<seq>,<state>,<last_drive_seq>,<faults>,<battery_mv>,<left_output_i>,<right_output_i>\n
```

字段：

- `seq`：ESP32 状态序号；
- `state`：ESP32 状态；
- `last_drive_seq`：最近一次有效驾驶命令序号；
- `faults`：故障位图，0 表示无故障；
- `battery_mv`：电池电压，未知时为 0；
- `left_output_i`：左电机输出，范围 `-1000` 到 `1000`；
- `right_output_i`：右电机输出，范围 `-1000` 到 `1000`。

`state` 可选值：

- `BOOT`：启动中；
- `READY`：就绪；
- `DRIVE`：驱动中；
- `STOP`：停车；
- `TIMEOUT`：控制超时停车；
- `ESTOP`：急停锁定；
- `FAULT`：故障。

示例：

```text
S,88,DRIVE,120,0,0,450,350
S,89,TIMEOUT,120,0,0,0,0
S,90,ESTOP,122,0,0,0,0
```

## ESP32 混控建议

如果使用差速小车，ESP32 可使用以下初始混控：

```text
left = throttle_i + steering_i
right = throttle_i - steering_i
```

然后将 `left` 和 `right` 限制到 `[-1000, 1000]`。

建议在 ESP32 内加入：

- 死区处理；
- 最大输出限制；
- 加速度限制；
- 电机方向反转配置；
- 低电压保护预留。

## 超时和安全规则

### 控制端

- UI 松手后必须发送停车命令；
- WebSocket 断开时 UI 应显示不可驾驶；
- 急停按钮应常驻可见。

### RK3588 ROS2

- `openrd_web_bridge_node` 检测 WebSocket 断开后，应通知 safety 层；
- `openrd_safety_node` 超过 300 ms 没收到有效 `drive`，发布停车命令；
- `openrd_safety_node` 收到急停后，立即进入急停锁定；
- `openrd_esp32_bridge_node` 将停车或急停命令转为 UART 命令；
- 从 ESP32 收到 `ESTOP` 或 `FAULT` 后，应向控制端上报。

### ESP32

- 超过 500 ms 没收到有效 `D` 命令，立即停车并进入 `TIMEOUT`；
- 收到急停标志后立即停车并进入 `ESTOP`；
- `ESTOP` 必须显式 `R` 复位；
- 串口解析失败的命令必须忽略，不能沿用错误值；
- 上电默认状态必须是停车。

## 协议版本策略

- 当前协议版本：`1`；
- WebSocket 消息必须带 `version`；
- ROS2 message 的破坏性修改应升级 package 版本并同步文档；
- UART 协议暂不带版本号，由文档和固件版本约束；
- 后续如加入 CRC、二进制协议或更多控制轴，应升级文档版本并保留兼容策略。