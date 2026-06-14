# RK3588 工具脚本

这些脚本用于在 ATK-DLRK3588B 原生 Debian 系统上管理 OpenRD 的 Ubuntu 22.04 ROS2 chroot。

## 前提

- chroot 路径：`/opt/openrd/jammy-ros2`；
- 项目路径：`/home/linaro/OpenRD`；
- ROS2：chroot 内安装 ROS2 Humble；
- 视频链路仍在 Debian 原生系统运行，不进入 chroot。

## 脚本

- `mount_openrd_chroot.sh`：挂载 `/dev`、`/proc`、`/sys`、`/run` 和项目目录；
- `enter_openrd_chroot.sh`：进入 chroot，并自动 source ROS2/OpenRD 环境；
- `build_openrd_ros2_ws.sh`：在 chroot 内构建 `vehicle/ros2_ws`；
- `install_openrd_video_service.sh`：在宿主 Debian 安装原生视频 systemd 服务、默认 RTSP publisher 参数、断流 watchdog 和最小 sudoers 权限；
- `configure_openrd_mediamtx.sh`：把 MediaMTX 固化为 `live` / `live-front` / `live-rear` / `openrd` publisher 路径，关闭 WebRTC 接口地址自动枚举，并宣告稳定板端地址；
- `run_openrd_ros2_smoke_test.sh`：启动 launch，发布测试控制命令，观察 ESP32 dry-run 状态。
- `run_openrd_video_smoke_test.sh`：启动 launch，通过 ROS2 service 验证原生视频 runtime 启停。
- `run_openrd_rtp_smoke_test.sh`：legacy RTP 冒烟测试，使用 `live-rtp`，不覆盖默认 `live` publisher 链路。
- `run_openrd_rtsp_smoke_test.sh`：启动默认 `rtsp` publisher 模式，验证 RTSP/HLS/WebRTC 全链路。
- `monitor_openrd_video_chain.sh`：长期监测视频链路，分层记录 service、RTSP 读帧、WebRTC HTTP、MediaMTX journal 和 RK camera/ISP kernel 日志。

## 当前默认视频发布

当前长期运行链路：

```text
/dev/openrd-cam-front
  -> v4l2src
  -> mpph264enc
  -> h264parse
  -> rtspclientsink rtsp://127.0.0.1:8554/live
  -> MediaMTX
  -> RTSP/WebRTC
```

默认板端地址：

```text
RTSP:   rtsp://192.168.100.108:8554/live
WebRTC: http://192.168.100.108:8889/live/
```

生成 MediaMTX 配置时推荐显式传入板端稳定 IP，避免同一网卡上的动态地址被写入 WebRTC ICE candidate：

```bash
OPENRD_BOARD_IP=192.168.100.108 bash tools/rk3588/configure_openrd_mediamtx.sh
```

安装后确认开机自启动：

```bash
systemctl is-enabled openrd-video-native.service mediamtx.service rkaiq_3A.service
systemctl is-active openrd-video-native.service mediamtx.service rkaiq_3A.service
```

## 长时间监测实验

先用只读监测脚本观察，不手工干预服务：

```bash
cd /home/linaro/OpenRD

# 快速 10 分钟
DURATION_SEC=600 INTERVAL_SEC=10 bash tools/rk3588/monitor_openrd_video_chain.sh

# 长跑 1 小时
DURATION_SEC=3600 INTERVAL_SEC=10 bash tools/rk3588/monitor_openrd_video_chain.sh
```

默认输出目录：

```text
vehicle/native_video/run/monitor/
```

每次运行会生成：

- `video-chain-<time>.csv`：采样表，包含 service active、runtime pid、RTSP 是否读到帧、WebRTC HTTP 状态；
- `video-chain-<time>.events.log`：异常摘要；
- `video-chain-<time>.logs.txt`：运行期间 `mediamtx`、`openrd-video-native`、`rkaiq_3A`、kernel camera 相关日志切片；
- `video-chain-<time>.summary.txt`：运行参数和失败计数。

判读方式：

- `rtsp_frame=fail` 且 kernel 有 `rkcif` / `rkisp` / `imx415`，优先看 RK camera/ISP 链路；
- `rtsp_frame=ok` 但浏览器无画面，优先看 MediaMTX/WebRTC/ICE；
- `services_active` 不是 `active|active|active`，先看对应 systemd service；
- 浏览器 404 通常对应 MediaMTX 暂时没有 `live` publisher，可在日志中查 `no stream is available on path 'live'`。

## 注意

- 脚本需要在 RK3588 上运行；
- 需要 `sudo` 权限；
- 脚本设置 `FASTDDS_BUILTIN_TRANSPORTS=UDPv4`，用于规避 chroot 下 FastDDS shared memory 权限噪声；
- RTSP 健康检查必须读到真实视频帧才算通过；默认只做有限自恢复：视频 runtime 最多健康重启 1 次，`rkaiq_3A.service` 最多重启 1 次，仍失败则进入 `faulted` 并以退出码 42 停止 systemd 自动重启；
- 真实接 ESP32 前，保持 `serial.yaml` 中的 `dry_run: true`。
