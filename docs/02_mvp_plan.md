# 02 MVP 实施计划

本文档定义 OpenRD v0.1 局域网基础驾驶闭环的实施顺序、交付物和验收标准。

## MVP 范围

v0.1 只解决一个问题：小车可以在局域网内被远程控制，完成前、后、左、右、停。

v0.1 包含：

- Flutter 控制端基础界面；
- WebSocket 控制链路；
- RK3588 ROS2 workspace；
- `openrd_msgs` 基础消息；
- `openrd_web_bridge_node`；
- `openrd_safety_node`；
- `openrd_esp32_bridge_node`；
- RK3588 到 ESP32 的 UART 转发；
- ESP32 电机控制；
- 超时停车与急停；
- 单路视频链路验证。

v0.1 不包含：

- 公网控制；
- 完整 WebRTC 架构；
- YOLO 检测；
- 双摄切换；
- 复杂 UI；
- 自动驾驶；
- SLAM/Nav2；
- Flutter 直连 ROS2 DDS；
- 驾驶视频的 ROS2 image topic 主链路。

## 推荐实施顺序

### 阶段 1：ROS2 workspace 与消息

目标：先建立车端 ROS2-first 骨架，避免后续重构。

任务：

- 确认 RK3588 系统镜像和可用 ROS2 发行版；
- 创建 `vehicle/ros2_ws`；
- 创建 `openrd_msgs`；
- 定义 `DriveCommand`、`VehicleState`、`Esp32State`；
- 创建 `openrd_bringup`；
- 准备基础 launch 和参数文件。

完成标准：

- ROS2 workspace 可以构建；
- 自定义消息可以生成；
- 能用命令行发布和查看 `/openrd/drive_cmd` 测试消息。

### 阶段 2：WebSocket 到 ROS2 bridge

目标：让控制端命令进入 ROS2 graph。

任务：

- 固定 WebSocket 控制协议；
- 编写最小 WebSocket 调试客户端或 Flutter 简易页面；
- 实现 `openrd_web_bridge_node`；
- 将 WebSocket `drive` 消息发布为 `/openrd/drive_cmd`；
- 将 ROS2 状态消息转发为 WebSocket `state`；
- 先用日志打印代替真实串口输出。

完成标准：

- 控制端能发出 `drive`、`ping`、`estop` 等消息；
- `openrd_web_bridge_node` 能收到消息并发布 ROS2 topic；
- 命令序号和时间戳能正常流转。

### 阶段 3：Safety node

目标：把安全策略放入独立 ROS2 节点。

任务：

- 实现 `openrd_safety_node`；
- 订阅 `/openrd/drive_cmd`；
- 发布 `/openrd/safe_drive_cmd`；
- 实现限幅、死区、速度上限；
- 实现 RK3588 层控制超时停车；
- 实现急停锁定和复位策略；
- 发布安全状态。

完成标准：

- 正常控制命令能被转发为安全控制命令；
- 超限输入会被限制；
- 控制端停止发送后，`safe_drive_cmd` 自动进入停车；
- 急停后不会自动恢复驾驶。

### 阶段 4：ESP32 bridge 与串口转发

目标：打通 ROS2 到 ESP32 的命令链路。

任务：

- 实现 `openrd_esp32_bridge_node`；
- 在 RK3588 上打开 UART；
- 将 `/openrd/safe_drive_cmd` 转换为 UART `D` 命令；
- 接收 ESP32 `S` 状态行；
- 发布 `/openrd/esp32_state`；
- 检测串口异常并上报状态。

完成标准：

- 控制端发送命令后，ESP32 串口能收到对应命令；
- ROS2 topic 能看到 ESP32 状态；
- 控制端停止发送后，RK3588 会向 ESP32 输出停车命令。

### 阶段 5：ESP32 电机控制

目标：让下位机可以安全控制电机。

任务：

- 实现 UART 命令解析；
- 实现 throttle/steering 到左右电机输出的混控；
- 实现停车命令；
- 实现串口命令超时停车；
- 实现急停锁定和复位；
- 加入最大输出限制和死区处理。

完成标准：

- ESP32 单独接收串口命令即可控制电机；
- 前进、后退、左转、右转、停动作正确；
- 拔掉串口或停止发送命令后，电机自动停止；
- 急停触发后，电机保持停止，直到显式复位。

### 阶段 6：Flutter 基础控制端

目标：形成可操作的驾驶界面。

任务：

- 创建 Flutter 工程；
- 实现连接配置页面；
- 实现基础方向控制按钮或虚拟摇杆；
- 实现急停按钮；
- 实现 WebSocket 连接状态显示；
- 实现固定频率发送控制命令。

完成标准：

- 浏览器端可以连接 RK3588；
- 用户可以控制前、后、左、右、停；
- 松开控制后自动发送归零命令；
- 页面能显示连接、急停、超时等基础状态。

### 阶段 7：单路视频验证

目标：确认摄像头链路可用于驾驶辅助。

任务：

- 在 RK3588 上验证 ATK-IMX415 采集；
- 验证硬件编码；
- 使用 VLC 或测试工具验证 RTSP/本地视频流；
- 记录分辨率、帧率、延迟和 CPU/NPU/GPU 占用；
- 规划接入 Flutter 的视频显示方案。

完成标准：

- 单路摄像头画面可以稳定输出；
- 视频延迟可以被粗略测量；
- 控制链路和视频链路可以同时运行。

## 默认参数

v0.1 建议默认参数：

- WebSocket 地址：`ws://<vehicle-ip>:8080/control`；
- ROS2 namespace：`/openrd`；
- 控制发送频率：20 Hz；
- 最大控制频率：50 Hz；
- Flutter 控制归一化范围：`-1.0` 到 `1.0`；
- UART 控制整数范围：`-1000` 到 `1000`；
- RK3588 safety 超时：300 ms；
- ESP32 控制超时：500 ms；
- 初期速度限制：最大输出不超过 40%；
- 急停：锁定停车，需要显式复位。

## 验收清单

基础连接：

- 控制端能连接 RK3588；
- `openrd_web_bridge_node` 能发布控制 topic；
- `openrd_safety_node` 能发布安全控制 topic；
- `openrd_esp32_bridge_node` 能连接 ESP32；
- 控制端能看到车端或 ESP32 状态。

基础驾驶：

- 前进方向正确；
- 后退方向正确；
- 左转方向正确；
- 右转方向正确；
- 停车响应正确；
- 控制松手后归零。

安全保护：

- WebSocket 断开后停车；
- 控制端停止发送后停车；
- RK3588 ROS2 节点异常退出后 ESP32 停车；
- 急停按钮有效；
- 急停后不能自动恢复驾驶。

视频验证：

- 单路摄像头可采集；
- 视频可播放；
- 驾驶控制和视频回传可同时运行；
- 延迟可以接受或有明确优化方向。

## 调试建议

建议按以下顺序调试，避免一开始就上真实车：

1. ROS2 topic 内部流转：只用命令行发布和订阅；
2. 控制端到 `openrd_web_bridge_node`：只看 ROS2 topic，不接 ESP32；
3. `openrd_safety_node`：测试限幅、超时和急停；
4. `openrd_esp32_bridge_node` 到 ESP32：只看串口日志，不接电机；
5. ESP32 到电机驱动：架空轮子测试；
6. 小车低速地面测试；
7. 加入视频回传；
8. 提高速度或复杂控制。

## 主要风险和缓解

### ROS2 环境不稳定

缓解：先确认 RK3588 系统版本和 ROS2 发行版；必要时先在 WSL/Ubuntu 中构建，再在 RK3588 上本机构建或容器化。

### 电机方向不一致

缓解：在 ESP32 固件中为左右电机提供方向反转配置，不在 Flutter 层修正。

### 控制链路延迟或抖动

缓解：固定频率发送控制命令，ROS2 控制 topic 只保留最新值，ESP32 做最后安全保护。

### 电源不稳定

缓解：电机电源和控制电源尽量隔离，至少保证共地和足够电流余量。

### 车辆失控

缓解：三层保护：Flutter 松手归零、ROS2 safety 超时停车、ESP32 超时停车。

### 视频链路拖慢控制

缓解：控制和视频分线程/分进程处理，控制链路优先级高于视频链路；视频不强制走 ROS2 image topic。