# OpenRD Native Video Runtime

`openrd-video-native` 是 OpenRD 在 RK3588 原生 Debian 系统上运行的视频链路适配层。

它的 v0.1 形态是一个正式 CLI，而不是随手写的临时脚本。后续可以在保持 CLI 接口不变的前提下，把内部实现从 `gst-launch-1.0` 替换为 Python supervisor、C++ daemon 或 WebRTC/RTSP 服务。

## 定位

运行位置：RK3588 原生 Debian 系统。

不运行在：Ubuntu 22.04 chroot、Docker、ROS2 进程内部。

原因：ATK-DLRK3588B 当前原生 Debian 已经适配好 Rockchip MPP、RGA、ISP、V4L2、GStreamer 插件和 `mpph264enc`。视频硬件链路优先保留在原生系统，ROS2 chroot 只负责控制和状态管理。

## 当前能力

v0.1 支持：

- 默认从 UVC USB 摄像头读取 MJPG 视频，经软件 JPEG 解码转为 NV12 后走 H.264 硬编链路；
- 可选使用 Rockchip `mppjpegdec` 对 MJPG 输入做硬件解码；
- 仍保留从 `rkisp_mainpath` CSI 节点读取 NV12 视频的可选路径；
- 使用 `mpph264enc` 做 H.264 硬件编码；
- `fakesink` 模式做链路验证；
- `file` 模式保存 H.264 裸流；
- legacy `rtp` 模式把 H.264 封装为 RTP/UDP 发给本机 MediaMTX 的独立路径；
- 默认 `rtsp` publisher 模式，直接发布到本机 MediaMTX 的 `live` 路径；
- 通过 MediaMTX 对外提供 `rtsp://<板子IP>:8554/live` 和 `http://<板子IP>:8889/live/` 播放地址；
- 后台启动、停止、重启、状态查询；
- 后台监督运行，RTSP 模式下必须实际读到视频帧才判定健康；
- 检测到断流后做有限自恢复，仍失败时进入 `faulted`，等待人工处理；
- 写入 PID、状态文件和日志文件。

v0.1 暂不支持：

- 直接 WebRTC 推流；
- 双摄管理；
- 直接发布 ROS2 `sensor_msgs/Image`。

## 常用命令

在 RK3588 原生 Debian 上执行：

```bash
cd /home/linaro/OpenRD/vehicle/native_video
chmod +x ./openrd-video-native

# 摄像头 + MPP H.264 编码短测，默认 60 帧后退出
./openrd-video-native test

# 后台启动 fakesink 模式
./openrd-video-native start --mode fakesink
./openrd-video-native status
./openrd-video-native stop

# 保存 H.264 裸流文件
./openrd-video-native start --mode file --output /tmp/openrd_camera_test.h264
sleep 10
./openrd-video-native stop
ls -lh /tmp/openrd_camera_test.h264

# 推 RTSP 给 MediaMTX，再从 RTSP/WebRTC 播放
./openrd-video-native start --mode rtsp --rtsp-url rtsp://127.0.0.1:8554/live
ffprobe -rtsp_transport tcp rtsp://127.0.0.1:8554/live
./openrd-video-native stop

# USB UVC 摄像头示例：默认 MJPG 输入，仍然推 RTSP 给 MediaMTX
v4l2-ctl -d /dev/openrd-cam-uvc --list-formats-ext
./openrd-video-native test --device /dev/openrd-cam-uvc --input-format mjpg
./openrd-video-native start --mode rtsp --device /dev/openrd-cam-uvc --input-format mjpg --rtsp-url rtsp://127.0.0.1:8554/live
./openrd-video-native stop

# 使用 RK3588 MPP JPEG 硬解 MJPG 输入
./openrd-video-native test --device /dev/openrd-cam-uvc --input-format mjpg --mjpeg-decoder mpp
./openrd-video-native pipeline --mode rtsp --device /dev/openrd-cam-uvc --input-format mjpg --mjpeg-decoder mpp

# 打印实际 GStreamer pipeline
./openrd-video-native pipeline --mode file --output /tmp/openrd_camera_test.h264
```

## 默认参数

- 默认服务设备：`/dev/openrd-cam-uvc`；
- 默认输入格式：`mjpg`，用于 UVC USB 摄像头；
- 默认 MJPG 解码器：`software`，即 `jpegdec` + `videoconvert`；可选 `mpp`，即 `jpegparse` + `mppjpegdec format=NV12`；
- 默认 UVC 别名：通过 udev 绑定 Sunplus SPCA2650 AV Cam（`1bcf:b112`）为 `/dev/openrd-cam-uvc`，避免依赖 `/dev/video41` 这种可能漂移的节点号；
- CSI 可选别名：`/dev/openrd-cam-front` 与 `/dev/openrd-cam-rear` 仍保留给 RK ISP/IMX415 调试使用；使用 CSI 时应显式传 `--input-format nv12`；
- 分辨率：`1280x720`；
- 帧率：`30`；
- 编码器：`mpph264enc`；
- 码率：`2000000` bps；
- GOP：`30`；
- 默认发布 URL：`rtsp://127.0.0.1:8554/live`；
- 板外 RTSP 播放 URL：`rtsp://192.168.100.108:8554/live`；
- 板外 WebRTC 播放 URL：`http://192.168.100.108:8889/live/`；
- RTSP 健康检查：每轮必须用 `ffmpeg`/`ffprobe` 实际读到视频帧，默认不再用 HLS playlist 作为健康信号；
- 默认恢复上限：当前 UVC 调试阶段关闭自动健康重启；CSI 调试时可按需要打开视频 runtime 与 `rkaiq_3A.service` 的有限恢复；
- 默认故障退出码：`42`，systemd 通过 `RestartPreventExitStatus=42` 停止自动重启；
- 状态目录：`vehicle/native_video/run`；
- 日志文件：`vehicle/native_video/run/openrd-video-native.log`。

## RTSP 播放路径

当前推荐路径是让 GStreamer 作为 RTSP publisher 发布到 MediaMTX。当前默认仍然只推一路 `live`，但 MediaMTX 已经预留 `live-front` 与 `live-rear` 两个路径，后续可在不改命名约定的前提下扩成双路：

```text
/dev/openrd-cam-uvc -> v4l2src MJPG -> jpegdec -> videoconvert NV12 -> mpph264enc -> h264parse -> rtspclientsink -> MediaMTX live
# optional:
/dev/openrd-cam-uvc -> v4l2src MJPG -> jpegparse -> mppjpegdec NV12 -> mpph264enc -> h264parse -> rtspclientsink -> MediaMTX live
reserved paths:
  live-front -> rtsp://<板子IP>:8554/live-front
  live-rear  -> rtsp://<板子IP>:8554/live-rear
default path:
  live       -> rtsp://<板子IP>:8554/live
  live       -> http://<板子IP>:8889/live/
```

当前板端验证 UVC 摄像头经 `rtspclientsink` 发布到 `live` 稳定可用；MediaMTX 再把同一路 `live` 转为 WebRTC。MediaMTX 默认配置关闭接口地址自动枚举，只向浏览器宣告稳定地址 `192.168.100.108`，避免同一网卡上的动态地址或 `127.0.0.1` 干扰 ICE 选择。

supervisor 的健康检查不再只看 RTSP path 或 HLS manifest 是否存在，而是要求实际读取到视频帧。若出现 camera/ISP 停止吐帧，常见内核日志如下：

```text
rkcif-mipi-lvds: stream[0] not active buffer
rkisp_stream_stop id:0 timeout
imx415 ... start stream failed while write regs
```

CSI 恢复策略需要显式打开健康检查相关 env 后才会启用：

- 连续指定次数 RTSP 读帧失败后，重启一次 `openrd-video-native` 子进程；
- 若设置 `OPENRD_VIDEO_RKAIQ_RESTART_AFTER_HEALTH_RESTARTS`，可在健康重启后尝试重启 `rkaiq_3A.service`；
- 超过 `OPENRD_VIDEO_MAX_HEALTH_RESTARTS` 后写入 `STATE=faulted`，删除 runtime PID，并以 `OPENRD_VIDEO_FAULT_EXIT_CODE` 退出；
- systemd 配置了 `RestartPreventExitStatus=42`，所以进入 fault 后不会无限重启，需要人工检查 camera/ISP/V4L2 状态后再手动拉起；
- 浏览器在断流窗口报 404 时，通常表示 MediaMTX 暂时没有可用 `live` publisher。

注意：legacy `rtp` 分支仍保留，但应使用 `live-rtp` 等独立路径，避免覆盖默认 `live` publisher 链路。

## 稳定接口

后续 `openrd_video_node` 应该通过稳定 CLI 管理原生视频 runtime，而不是依赖脚本内部实现。

建议保持以下接口长期兼容：

```bash
openrd-video-native start [options]
openrd-video-native stop
openrd-video-native restart [options]
openrd-video-native status --json
openrd-video-native pipeline [options]
```

## chroot 内的控制方式

ROS2 运行在 Ubuntu 22.04 chroot 内，不能直接执行宿主 Debian 路径 `/home/linaro/OpenRD/...` 下的视频脚本来管理硬件链路。

因此 v0.1 增加了两层边界：

- 宿主 Debian：`openrd-video-native.service` 负责真正运行 `openrd-video-native run`；
- 宿主 Debian：`openrd-video-native.service` 通过 `openrd-video-native supervise` 负责真正运行并自动恢复视频链路；
- chroot ROS2：`openrd-video-systemd` 通过 `sudo -n systemctl start/stop/restart openrd-video-native.service` 管理宿主服务，并读取同一个状态目录；
- systemd：默认 UVC 链路只要求 `openrd-video-native.service` 与 `mediamtx.service` 保持 `enabled`，板子重启后会自动尝试恢复推流和发布；`rkaiq_3A.service` 仅在 CSI/IMX415 调试时需要关注。

首次部署服务：

```bash
cd /home/linaro/OpenRD
bash tools/rk3588/install_openrd_video_service.sh
```

## 后续演进

- v0.2：把当前 `gst-launch-1.0` 链路替换为更稳定的 GStreamer API/C++ runtime；
- v0.3：增加更细的采集侧健康状态和恢复统计；
- v0.4：改为 Python/C++ supervisor 管理 GStreamer 子进程；
- v0.5：直接使用 GStreamer API 构建 pipeline；
- v0.6：完善 WebRTC 信令/TURN，并由 ROS2 节点统一发布视频状态。
