# openrd_web_bridge

`openrd_web_bridge` 是 Flutter/浏览器控制端进入车端 ROS2 graph 的入口。

## 职责

- 提供 WebSocket Server；
- 接收 Flutter 控制端的 JSON 消息；
- 将 `drive` 消息发布为 ROS2 `drive_cmd`；
- 将 `estop`、`reset_estop` 映射到 ROS2 安全接口；
- 将 `vehicle_state` 转发给前端显示；
- 后续可作为 WebRTC DataChannel 控制入口的替代或并行实现参考。

## 当前状态

当前节点是骨架实现：

- 已读取 `listen_host`、`listen_port`、`control_path` 等参数；
- 已订阅 `vehicle_state`；
- 暂未实现真实 WebSocket Server；
- 暂未发布 `drive_cmd`。

## 预期 WebSocket 地址

```text
ws://<vehicle-ip>:8080/control
```

## 输入

来自控制端的 JSON：

- `hello`；
- `drive`；
- `ping`；
- `estop`；
- `reset_estop`。

## 输出

ROS2：

```text
drive_cmd    openrd_msgs/msg/DriveCommand
reset_estop  std_srvs/srv/Trigger
```

WebSocket：

- `hello_ack`；
- `pong`；
- `state`。

## 实现建议

- C++ WebSocket 库需要后续选型；
- WebSocket IO 不应阻塞 ROS2 executor；
- 控制消息只保留最新状态，不堆积旧命令；
- WebSocket 断开时必须通知 safety 层进入停车；
- 初期只允许局域网访问，不暴露到公网。