# 05 RK3588 部署策略

本文档记录 OpenRD 在 ATK-DLRK3588B 上的部署边界。当前板卡系统为正点原子 Debian 11 bullseye / aarch64，内核为 Rockchip 5.10 系列。

## 当前系统探测结果

RK3588 原生 Debian 环境中已经具备 Rockchip 视频硬件链路：

- GStreamer 插件：`rockchipmpp`；
- H.264 硬件编码器：`mpph264enc`；
- H.265 硬件编码器：`mpph265enc`；
- 视频设备：`/dev/video*`；
- 当前稳定采集节点：两路 `rkisp_mainpath`，设备号可能在 `/dev/video22`、`/dev/video31` 等之间漂移；
- 推荐固定路径：`/dev/v4l/by-path/platform-rkisp0-vir0-video-index0` 与 `/dev/v4l/by-path/platform-rkisp1-vir0-video-index0`；
- 推荐别名：`/dev/openrd-cam-front` 与 `/dev/openrd-cam-rear`；
- 当前默认业务视频设备：`/dev/openrd-cam-uvc`，CSI/IMX415 的 `/dev/openrd-cam-front` 与 `/dev/openrd-cam-rear` 保留为调试路径；
- 硬件相关设备：`/dev/mpp_service`、`/dev/rga`、`/dev/dri`、`/dev/dma_heap`、`/dev/video-enc0`、`/dev/video-dec0`。

这说明视频采集、ISP、RGA、MPP、GStreamer 插件栈已经由原生系统适配好，不应轻易迁移到 Docker 或 Ubuntu chroot 内部。

## 部署边界

OpenRD 在 RK3588 上采用“双环境”部署：

```text
RK3588 Debian 11 原生系统
  ├─ 摄像头驱动 / ISP / V4L2
  ├─ Rockchip MPP / RGA / GStreamer
  ├─ mpph264enc / mpph265enc
  ├─ openrd-video-native
  └─ MediaMTX / 后续 WebRTC 视频进程

Ubuntu 22.04 chroot
  └─ ROS2 Humble 控制环境
       ├─ openrd_web_bridge_node
       ├─ openrd_safety_node
       └─ openrd_esp32_bridge_node
```

## 为什么视频留在原生系统

- `mpph264enc` 依赖 Rockchip MPP 用户态库和内核驱动；
- 摄像头、ISP、RGA、MPP、GStreamer 插件往往与板厂镜像强绑定；
- Docker 当前在该板上 daemon 启动失败，且缺少 overlay/bridge/iptables 等内核能力；
- 即使 Docker 修好，也需要处理 `/dev/video*`、`/dev/mpp_service`、`/dev/rga`、`/dev/dri`、用户态库、GStreamer 插件等映射；
- chroot 内的 Ubuntu 用户态库可能与正点原子 Debian 的 Rockchip 视频栈不匹配；
- 远程驾驶视频链路对延迟敏感，不应为了架构统一牺牲硬件加速稳定性。

## 为什么 ROS2 放在 Ubuntu chroot

- ROS2 Humble 官方 deb 包面向 Ubuntu 22.04 Jammy；
- 当前 Debian 11 原生 apt 源中没有合适的 ROS2 Humble/Jazzy 包；
- chroot 不依赖 Docker daemon；
- chroot 可以较低侵入地提供 Ubuntu 22.04 用户态；
- 控制链路主要使用 ROS2 topic、WebSocket、UART，对图形/视频硬件依赖较低；
- 串口设备可通过 bind mount `/dev` 暴露给 chroot。

## v0.1 运行原则

- 视频链路在 Debian 原生系统运行；
- ROS2 控制链路在 Ubuntu 22.04 chroot 运行；
- `openrd_video_node` 负责管理原生视频 runtime，不承载每帧视频；
- `openrd_esp32_bridge_node` 初期保持 `dry_run: true`；
- 真实串口、电机和视频联调必须分阶段进行。

## 推荐验证顺序

1. 原生 Debian 上验证 `mpph264enc` 和摄像头设备；
2. 原生 Debian 上跑最小 GStreamer 编码测试；
3. 创建 Ubuntu 22.04 chroot；
4. chroot 内安装 ROS2 Humble；
5. chroot 内构建 `vehicle/ros2_ws`；
6. chroot 内测试 `/openrd/drive_cmd -> /openrd/safe_drive_cmd -> /openrd/esp32_state`；
7. 确认控制链路稳定后，再接 ESP32 串口；
8. 最后将原生视频链路和 ROS2 控制链路组合运行。

## 参考

- ROS2 Humble deb 包官方目标平台是 Ubuntu 22.04 Jammy；
- Ubuntu debootstrap chroot 可用于构建隔离的 Ubuntu 用户态环境。
## 实测记录

当前已经在 RK3588 上完成以下验证：

- 原生 Debian 系统中 `gst-inspect-1.0 mpph264enc` 正常；
- `videotestsrc -> mpph264enc -> fakesink` 编码冒烟测试通过；
- `/dev/openrd-cam-front -> mpph264enc -> fakesink` 摄像头编码冒烟测试通过；
- Docker daemon 当前不可用，原因包括 overlay、bridge、iptables/nft 相关内核能力不足；
- Debian 11 原生 `debootstrap` 太旧，无法直接解包 Ubuntu 22.04 的 zstd deb 包；
- 已改用 Ubuntu Base 22.04 arm64 rootfs tarball 创建 `/opt/openrd/jammy-ros2`；
- chroot 内已安装 ROS2 Humble `ros-base` 和 `colcon`；
- `vehicle/ros2_ws` 已在 chroot 内构建通过；
- `openrd_bringup` launch 可启动；
- Python 测试发布 `/openrd/drive_cmd` 后，`openrd_esp32_bridge_node` dry-run 可看到 `DRIVE` 状态和 `D,<seq>,300,100,0,1` 类 UART 命令；
- 停止发布后，safety 会回到 `timeout` 并输出停车命令。

## 已知注意点

- ROS2 `.msg` 文件不能带 UTF-8 BOM，否则 `rosidl_adapter` 会把第一行类型解析失败；
- chroot 中运行 ROS2 时建议设置 `FASTDDS_BUILTIN_TRANSPORTS=UDPv4`，避免 FastDDS shared memory 权限噪声；
- 通过 chroot bind mount 项目目录后，建议用 UID 1000 构建，避免在 `/home/linaro/OpenRD` 下产生 root-owned build 文件；
- chroot 的 `/tmp` 和宿主 `/dev/shm` 建议保持 `1777` 权限。

## 常用命令

在 RK3588 上：

```bash
cd /home/linaro/OpenRD
bash tools/rk3588/build_openrd_ros2_ws.sh
bash tools/rk3588/run_openrd_ros2_smoke_test.sh
bash tools/rk3588/enter_openrd_chroot.sh
```

## 公网视频中继候选

当前准备先按“云端视频中继”方式验证远程访问，不直接暴露车端局域网端口。

```text
RK3588 原生视频链路
  -> 主动推流
腾讯云服务器 43.139.25.165
  -> ZLMediaKit / MediaMTX
浏览器前端
  -> WebRTC / WHEP 播放
```

计划优先评估 ZLMediaKit 作为腾讯云中继服务，MediaMTX 保留为轻量回退方案。仓库只记录服务器公网 IP 和用途，不记录账号、密钥、防火墙规则或证书私钥。

当前服务器运行和烟测记录见 `infra/openrd-video-relay/README.md`。

## Native Video Runtime v0.1

OpenRD 已引入正式的原生视频运行时 CLI：

```text
vehicle/native_video/openrd-video-native
```

并新增宿主 systemd 服务与 chroot 包装器：

```text
infra/systemd/openrd-video-native.service
vehicle/native_video/openrd-video-systemd
```

它运行在 RK3588 原生 Debian 系统上，不进入 Ubuntu chroot。当前默认使用 `gst-launch-1.0` 管理以下链路：

```text
/dev/openrd-cam-uvc
  -> v4l2src
  -> image/jpeg,width=1280,height=720,framerate=30/1
  -> jpegparse
  -> mppjpegdec format=NV12
  -> mpph264enc
  -> h264parse
  -> rtph264pay
  -> openrd-video-whip-client.py (webrtcbin) http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=push
  -> 腾讯云 ZLMediaKit live/openrd
  -> WHEP / WebRTC
```

当前支持命令：

```bash
./openrd-video-native test
./openrd-video-native run
./openrd-video-native start
./openrd-video-native stop
./openrd-video-native restart
./openrd-video-native status --json
./openrd-video-native pipeline
```

v0.1 支持 `fakesink`、`file`、legacy `rtp`、本机 `rtsp` publisher、云端 `rtmp` publisher 和云端 `whip` publisher 模式。当前默认推荐 `whip`：GStreamer 主动向腾讯云 ZLMediaKit 的 `live/openrd` 路径发布，控制端通过公网 WHEP/WebRTC 播放。RTMP/HTTP-FLV 和 MediaMTX 仍作为回退调试服务保留。

当前默认公网播放地址：

```text
WHEP:     http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=play
HTTP-FLV: http://43.139.25.165:8888/live/openrd.live.flv  # fallback
```

本机 MediaMTX 回退配置固定为 publisher 模式，并关闭自动枚举 WebRTC ICE 地址，只额外宣告板子的稳定地址 `192.168.100.108`：

```yaml
webrtcAllowOrigins: ['*']
webrtcIPsFromInterfaces: false
webrtcAdditionalHosts: [192.168.100.108]

paths:
  live:
    source: publisher
  live-front:
    source: publisher
  live-rear:
    source: publisher
  openrd:
    source: publisher
```

常用测试：

```bash
cd /home/linaro/OpenRD/vehicle/native_video
chmod +x ./openrd-video-native
./openrd-video-native test
./openrd-video-native start --mode file --output /tmp/openrd_camera_test.h264
sleep 10
./openrd-video-native stop
ls -lh /tmp/openrd_camera_test.h264

# 配置 MediaMTX，并验证 RTSP publisher / WebRTC 播放链路
cd /home/linaro/OpenRD
OPENRD_BOARD_IP=192.168.100.108 bash tools/rk3588/configure_openrd_mediamtx.sh
bash tools/rk3588/run_openrd_rtsp_smoke_test.sh

# 验证默认云端 WHIP 链路
./vehicle/native_video/openrd-video-native pipeline --mode whip --whip-url 'http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=push'
```

后续 `openrd_video_node` 通过这个稳定 CLI 管理原生视频 runtime，而不是直接在 chroot 内访问 `mpph264enc`。

实际部署时，ROS2 节点在 chroot 内调用 `openrd-video-systemd`，由它通过宿主 systemd 启停 `openrd-video-native.service`，确保真正的视频进程仍运行在 RK3588 原生 Debian 环境中。

首次安装 systemd 服务：

```bash
cd /home/linaro/OpenRD
bash tools/rk3588/install_openrd_video_service.sh
```

安装脚本会生成 `vehicle/native_video/run/openrd-video-native-service.env`，当前长期运行配置为：

```text
OPENRD_VIDEO_MODE=whip
OPENRD_VIDEO_DEVICE=/dev/openrd-cam-uvc
OPENRD_VIDEO_INPUT_FORMAT=mjpg
OPENRD_VIDEO_MJPEG_DECODER=mpp
OPENRD_VIDEO_RTSP_URL=rtsp://127.0.0.1:8554/live
OPENRD_VIDEO_RTMP_URL=rtmp://43.139.25.165:1935/live/openrd
OPENRD_VIDEO_RTMP_HEALTHCHECK_URL=
OPENRD_VIDEO_WHIP_URL=http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=push
OPENRD_VIDEO_WHEP_URL=http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=play
OPENRD_VIDEO_RTSP_PROTOCOLS=tcp
OPENRD_VIDEO_HEALTHCHECK_FAILURES=0
OPENRD_VIDEO_RTSP_HEALTHCHECK_TIMEOUT_SEC=8
OPENRD_VIDEO_HLS_HEALTHCHECK_URL=
OPENRD_VIDEO_MAX_HEALTH_RESTARTS=1
OPENRD_VIDEO_RKAIQ_SERVICE=rkaiq_3A.service
OPENRD_VIDEO_RKAIQ_RESTART_AFTER_HEALTH_RESTARTS=1
OPENRD_VIDEO_MAX_RKAIQ_RESTARTS=1
OPENRD_VIDEO_FAULT_EXIT_CODE=42
```

`openrd-video-native.service` 应保持 `enabled`。`mediamtx.service` 和 `rkaiq_3A.service` 可按局域网回退或 CSI/IMX415 调试需要保留。板子重启后会自动尝试恢复云端 WHIP/WebRTC 发布；如果 camera/ISP 故障触发 `faulted`，`openrd-video-native.service` 会以退出码 42 停在 failed 状态，避免无限重启：

```bash
systemctl is-enabled openrd-video-native.service
systemctl is-active openrd-video-native.service
```

断流排查时注意区分 404 的含义：当浏览器控制台在视频卡住后报 404，通常是 MediaMTX 此时认为 `live` path 暂无可用 publisher，常见日志为 `no stream is available on path 'live'`。这通常是上游 camera/ISP/V4L2 停止吐帧后的结果，不是 WebRTC 页面本身缺文件。

已观察到的 RK3588 采集侧异常包括：

```text
rkcif-mipi-lvds: stream[0] not active buffer
rkisp_stream_stop id:0 timeout
imx415 ... start stream failed while write regs
```

当前 supervisor 的恢复策略是：RTSP 模式下每轮健康检查必须实际读取到视频帧；连续 2 次失败后重启一次视频 runtime；默认在第 1 次健康重启后联动重启一次 `rkaiq_3A.service`；如果超过 `OPENRD_VIDEO_MAX_HEALTH_RESTARTS` 仍无法恢复，则写入 `STATE=faulted` 并以 `OPENRD_VIDEO_FAULT_EXIT_CODE=42` 退出。systemd 配置 `RestartPreventExitStatus=42`，因此不会无限重启，需要人工检查 camera/ISP/V4L2 后再手动恢复。

`openrd_video_node` 对外会发布 `/openrd/video_state`，并提供：

- `/openrd/start_runtime`；
- `/openrd/stop_runtime`；
- `/openrd/restart_runtime`。
