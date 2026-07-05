# OpenRD

OpenRD 是一个开放式远程驾驶项目，全称暂定为 **Open Remote Driving**。

项目目标是基于正点原子 ATK-DLRK3588B 开发板、ATK-IMX415 摄像头、ESP32 下位机、电机底盘以及 Flutter 控制端，构建一套可以在局域网内稳定运行，并逐步扩展到公网远程驾驶、视频回传和视觉检测的移动小车系统。

## 项目定位

OpenRD 不是单纯的视频小车，也不是只做 AI 检测的演示项目。它的核心目标是构建一个可扩展的远程驾驶系统，包含：

- 车端 ROS2-first 运行时；
- 车端视频采集与低延迟回传；
- 浏览器、Android、iOS 多端控制；
- 手柄与触屏两类输入方式；
- ESP32 下位机电机控制与安全保护；
- 后续可扩展的公网访问、TURN/WebRTC 中继、YOLO/RKNN、里程计、SLAM/Nav2 等能力。

## 当前硬件

- 车端主控：正点原子 ATK-DLRK3588B；
- 摄像头：2 个 ATK-IMX415；
- 下位机：ESP32；
- 控制输入：盖世小鸡 G7 Pro 无线手柄；
- 移动端：Android 手机、iPhone；
- 控制端：本机电脑浏览器 + Flutter 应用；
- 执行机构：底盘 + 电机 + 电机驱动模块。

## 当前实测状态

截至当前阶段，局域网内已经跑通一条可实车驾驶的临时直连链路：

```text
浏览器 Flutter 前端
  -> HTTP
ESP32 / OpenRD-Driver
  -> UART2
四路编码器电机驱动板
  -> 四轮底盘
```

这条链路暂时绕过 RK3588/ROS2，用于优先验证手柄、前端驾驶体验、ESP32 WiFi/HTTP 和四电机驱动协议。

当前已验证：

- ESP32 可通过 WiFi STA 接入局域网，默认地址实测为 `http://192.168.100.114`；
- OpenRD 前端可通过浏览器 Gamepad API 读取手柄；
- 前端可直接请求 OpenRD-Driver 的 `GET /status` 和 `POST /control`；
- 四电机驱动协议使用 `$spd:m1,m2,m3,m4#` 小写命令；
- 实车四路物理映射当前按 `M1/M2 = 左侧`、`M3/M4 = 右侧` 处理；
- 前进、后退、左转、右转、停止已能通过手柄控制；
- 前端有速度上限滑块，建议首次实车测试使用 `200` 或 `300`；
- 前端会每 3 秒刷新 OpenRD-Driver `/status`，每 30 秒触发一次 `/read_vol`，并按 12V/3S 电池估算电量显示；
- 前端视频默认播放云端 ZLMediaKit HTTP-FLV：`http://43.139.25.165:8888/live/openrd.live.flv`；
- 前端视频启停默认走公网控制服务：`http://43.139.25.165:8790`；
- RK3588 宿主 `openrd-video-agent.service` 已接入云端 control service，可按前端 lease 启停 `openrd-video-native.service`；
- OpenRD-Driver 已修复浏览器 CORS，`/control` 不再返回重复的 `Access-Control-Allow-Origin`。

当前前端静态调试方式：

```powershell
cd D:\Projects\OpenRD\frontend\openrd_frontend
flutter build web --debug
python -m http.server 8791 --bind 127.0.0.1 -d build\web
```

浏览器打开：

```text
http://127.0.0.1:8791/
```

视频推流不再要求长期常开。前端点击“启动视频推流”后，会通过公网 control service 通知 RK3588 上的 `openrd-video-agent.service` 启动 `openrd-video-native.service`；播放期间前端会续约 lease，点击停止或 lease 超时后车端自动停止推流，避免持续消耗公网流量。

## MVP 目标

第一阶段只做局域网 MVP，不直接引入公网、双摄、YOLO 或复杂云端架构。

MVP 成功标准：

- 控制端可以连接车端；
- 控制端可以发送前、后、左、右、停等基础驾驶指令；
- RK3588 上的 ROS2 节点可以接收控制命令；
- ROS2 内部控制 topic 可以完成从 WebSocket bridge 到 safety 再到 ESP32 bridge 的流转；
- RK3588 可以通过 UART 将安全后的控制命令转发给 ESP32；
- ESP32 可以控制电机完成基础动作；
- 控制链路断开或超时时，小车可以自动停车；
- 单路摄像头视频可以在控制端显示，用于辅助驾驶。

## 初始技术路线

### 车端

- 运行平台：ATK-DLRK3588B Linux；
- 车端框架：ROS2-first；
- 节点语言：优先 C++ / `rclcpp`；
- 职责：WebSocket 控制桥接、安全状态机、ESP32 串口桥接、状态聚合、后续视频管理与视觉检测；
- 与 ESP32 通信：优先使用 UART 串口；
- 说明：视频回传不强制走 ROS2 image topic，低延迟驾驶视频优先保留 GStreamer/RTSP/WebRTC 路线。

### 下位机

- 运行平台：ESP32；
- 职责：电机 PWM、方向控制、急停、控制超时保护；
- 安全策略：ESP32 必须独立实现控制超时自动停车。

### 控制端

- 前端框架：Flutter；
- 支持平台：Web、Android、iOS；
- 初期控制输入：浏览器 + 手柄、手机触屏；
- 当前实车调试链路：Flutter Web 通过 HTTP 直连 OpenRD-Driver；
- 保留 mock 验证：`dart run tools/mock_control_ws_server.dart`，可连接 `ws://127.0.0.1:8080/control`；
- ROS2 链路目标：后续将同一套驾驶输入接到 WebSocket bridge -> safety -> ESP32 bridge；
- 后续升级方向：WebRTC DataChannel；
- 说明：Flutter 不直接接入 ROS2 DDS，而是通过 WebSocket/DataChannel bridge 与车端 ROS2 graph 通信。

### 视频链路

- 当前默认：单路 UVC 摄像头 `/dev/openrd-cam-uvc`，MJPG 输入经 `jpegparse`/`mppjpegdec` 硬解为 NV12，再由 `mpph264enc` 硬编 H.264，并以 RTMP publisher 主动推送到腾讯云 ZLMediaKit 的 `live/openrd` 路径；
- 保留软件解码回退路径，可通过 `OPENRD_VIDEO_MJPEG_DECODER=software` 或 `--mjpeg-decoder software` 切换到 `jpegdec`/`videoconvert`；
- 公网视频控制服务：`http://43.139.25.165:8790`；
- 公网 RTSP 播放地址：`rtsp://43.139.25.165/live/openrd`；
- 公网 HTTP-FLV 播放地址：`http://43.139.25.165:8888/live/openrd.live.flv`；
- Flutter 前端当前默认使用公网 HTTP-FLV 播放地址；
- 本机 MediaMTX 保留为局域网回退调试路径：`rtsp://192.168.100.108:8554/live` / `http://192.168.100.108:8889/live/`；
- `openrd-video-agent.service` 启用 systemd 开机自启动；`openrd-video-native.service` 由 agent 根据前端 lease 按需启停；`mediamtx.service` 可作为局域网回退服务保留；
- CSI/IMX415 链路保留为可选调试路径，不再作为默认视频输入；
- 视频 watchdog 使用真实 RTSP 读帧健康检查；当前 UVC 调试阶段默认关闭自动健康重启，避免排查时反复拉起视频链路；
- 公网阶段：WebRTC + TURN/中继。

### 公网视频中继候选

- 腾讯云服务器公网 IP：`43.139.25.165`；
- 计划用途：作为远程视频中继节点，优先验证 RK3588 主动推流到云端，再由浏览器通过 WebRTC/WHEP 播放；
- 候选服务：优先评估 ZLMediaKit，MediaMTX 保留为轻量回退方案；
- 运行记录：`infra/openrd-video-relay/README.md`；
- 当前原则：车端主动向云端推流，不直接把家庭/实验室局域网端口暴露到公网；
- 账号、密钥、防火墙和证书信息不写入仓库。

### 摄像头 V4L2 诊断

`tools/rk_camera_v4l2_probe.sh` 用于在 RK3588 板端反复测试 IMX415 对应的 V4L2 设备节点，判断 `/dev/video22`、`/dev/video31` 是稳定可出帧、偶发失败，还是必现不可用。

脚本默认会停止 `openrd-video-native.service`，避免推流服务占用摄像头；每轮用 `v4l2-ctl` 抓取指定帧数，输出 CSV 汇总，并把每轮的 `v4l2-ctl` 输出和相关 `dmesg` 保存到 `/tmp/openrd-camera-probe-*`。

同步到板端并运行：

```bash
scp tools/rk_camera_v4l2_probe.sh linaro@192.168.100.108:/tmp/
ssh linaro@192.168.100.108 'chmod +x /tmp/rk_camera_v4l2_probe.sh && /tmp/rk_camera_v4l2_probe.sh'
```

常用短测：

```bash
OPENRD_CAMERA_PROBE_ITERATIONS=6 \
OPENRD_CAMERA_PROBE_TIMEOUT_SEC=10 \
OPENRD_CAMERA_PROBE_STREAM_COUNT=30 \
/tmp/rk_camera_v4l2_probe.sh
```

每轮重启 `rkaiq_3A.service` 的对照测试：

```bash
OPENRD_CAMERA_PROBE_ITERATIONS=4 \
OPENRD_CAMERA_PROBE_RESTART_RKAIQ_EACH_ITER=1 \
OPENRD_CAMERA_PROBE_TIMEOUT_SEC=10 \
OPENRD_CAMERA_PROBE_STREAM_COUNT=30 \
/tmp/rk_camera_v4l2_probe.sh
```

结果判读：

- `ok`：按 `stream-count` 成功抓到目标帧数；
- `partial`：抓到过帧或写出过数据，但没有完整完成；
- `timeout_no_frame`：超时且没有抓到帧，常见于摄像头/ISP 开流失败；
- `failed`：`v4l2-ctl` 返回其他错误；
- `summary_csv=...` 指向本次测试的完整 CSV 汇总。

## 推荐目录结构

```text
OpenRD/
  README.md
  docs/        # 架构、协议、硬件接线、阶段计划
  frontend/    # Flutter Web / Android / iOS 控制端
  vehicle/     # RK3588 ROS2 workspace、原生视频 runtime 与车端节点
  firmware/    # ESP32 下位机固件
  server/      # WebSocket、信令、中转服务
  infra/       # VPS、TURN、Docker、部署配置
  models/      # YOLO / RKNN 模型与转换说明
  tools/       # 调试脚本、延迟测试、手柄测试工具
```

建议的车端 ROS2 workspace：

```text
vehicle/
  ros2_ws/
    src/
      openrd_msgs/           # 自定义 msg / srv
      openrd_bringup/        # launch、参数、启动配置
      openrd_web_bridge/     # WebSocket <-> ROS2
      openrd_safety/         # 限幅、超时、急停状态机
      openrd_esp32_bridge/   # ROS2 <-> UART <-> ESP32
      openrd_video/          # 原生视频 runtime 管理、状态上报与后续 RTSP/WebRTC 接口
```

## 阶段计划

### v0.1：局域网基础驾驶闭环

- 建立项目 workspace 和文档；
- 建立 `vehicle/ros2_ws` 与基础 ROS2 packages；
- 定义 WebSocket、ROS2 topic、UART 三段控制协议；
- 实现 Flutter 控制端基础 UI；
- 实现 `openrd_web_bridge_node` 接收 WebSocket 控制命令；
- 实现 `openrd_safety_node` 处理限幅、超时、急停；
- 实现 `openrd_esp32_bridge_node` 转发 UART 命令；
- 实现 ESP32 电机控制与超时停车；
- 完成前、后、左、右、停的基础驾驶。

### v0.2：单路视频回传

- 验证 ATK-IMX415 在 RK3588 上的采集；
- 验证硬件编码链路；
- 实现控制端视频显示；
- 初步评估端到端延迟。

### v0.3：控制体验优化

- 接入 G7 Pro 手柄输入；
- 优化触屏虚拟摇杆；
- 增加心跳、重连、急停、限速；
- 记录控制日志和状态信息。

### v0.4：公网与 WebRTC

- 引入 WebRTC 视频链路；
- 引入信令服务；
- 规划 TURN 中继；
- 评估 WebSocket 控制升级到 WebRTC DataChannel。

### v0.5：视觉检测与机器人能力

- 选择轻量 YOLO 模型；
- 转换 RKNN；
- 在 RK3588 NPU 上运行检测；
- 将检测结果叠加或作为元数据发送到控制端；
- 根据需要扩展 ROS2 topic，接入里程计、TF、SLAM/Nav2 等能力。

## 当前原则

- 车端采用 ROS2-first 架构，避免后续重复重构；
- 先跑通局域网闭环，再做公网能力；
- 先实现单摄，再扩展双摄；
- 先实现基础驾驶，再优化控制体验；
- 先保证安全停车，再追求性能；
- 视频、控制、电机、安全保护分层设计；
- 控制协议尽量与具体传输方式解耦，便于后续从 WebSocket 升级到 WebRTC DataChannel；
- 不把低延迟视频强行塞进 ROS2 topic，视频链路按驾驶体验单独优化。

## 核心文档

当前已落盘以下核心文档：

- `docs/00_project_brief.md`：项目目标、边界和阶段定义；
- `docs/01_architecture.md`：整体架构和模块职责；
- `docs/02_mvp_plan.md`：局域网 MVP 实施计划；
- `docs/03_control_protocol.md`：WebSocket、ROS2 topic、UART 控制协议；
- `docs/04_vehicle_ros2_architecture.md`：RK3588 车端 ROS2-first 架构；
- `docs/05_rk3588_deployment.md`：RK3588 原生视频与 ROS2 chroot 部署边界。`vehicle/native_video/README.md` 记录原生视频 runtime，`openrd_video_node` 负责管理它。
- `docs/06_public_video_control.md`：公网视频按需启停方案，定义云端 control service、车端 video agent、前端启停和 lease 机制。
- `docs/07_public_drive_control.md`：公网底盘控制方案，定义云端控制通道、RK3588 control agent、安全规则和阶段路线。
- `docs/08_power_distribution_board.md`：车载电源分配板方案，定义 3S 电池、T 插、DC-DC、RK3588 供电和 PCB 规划。
- `docs/09_power_distribution_eda_build.md`：电源分配板嘉立创 EDA 绘制手册，定义原理图录入、封装、PCB 坐标、走线和检查流程。
- `docs/12_mobile_drive_control.md`：手机端控制计划，定义移动端 Web/PWA 驾驶界面、触控输入、安全停和分阶段落地路径。
- `docs/13_cloud_frontend_deployment.md`：云端前端部署方案，定义 Flutter Web 静态构建、云端托管、同源反代、访问控制和回滚策略。
- `hardware/openrd_pdb_v0_1/README.md`：车载电源分配板 v0.1 的嘉立创 EDA 标准版源文件、BOM 和导入说明。
- `server/openrd_control_service/README.md`：公网视频控制服务运行方式和 API。
- `vehicle/video_agent/README.md`：RK3588 宿主 video agent 的安装和运行方式。

## 下一步

建议下一步按以下顺序推进：

- 继续稳定当前 Flutter Web -> OpenRD-Driver HTTP 直连驾驶链路；
- 固化四电机物理映射、速度上限、急停和电池显示；
- 在 ESP32 固件中逐步加入控制超时停车和低电保护；
- 将当前已验证的驾驶输入模型接回 `openrd_web_bridge` -> `openrd_safety` -> `openrd_esp32_bridge`；
- 决定是否把独立的 `OpenRD-Driver` PlatformIO 工程迁入 `OpenRD/firmware/`，或保留为独立仓库并在 OpenRD 中只保留文档和启动脚本。
