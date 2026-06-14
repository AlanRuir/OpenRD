# openrd_video

`openrd_video` 用于管理车端原生视频 runtime，并把视频链路状态发布到 ROS2。

它不直接构建 GStreamer pipeline，也不承载每帧驾驶视频。真正访问 V4L2、MPP、ISP、MediaMTX 的进程运行在 RK3588 原生 Debian 上，ROS2 chroot 只负责启停、状态上报和参数传递。

## 职责

v0.1 阶段该 package 承担 runtime 管理职责：

- 发布 `/openrd/video_state`；
- 提供 `/openrd/start_runtime`、`/openrd/stop_runtime`、`/openrd/restart_runtime` service；
- 调用 `vehicle/native_video/openrd-video-systemd`；
- 读取 `openrd-video-native` 的 JSON 状态并转成 ROS2 message；
- 记录分辨率、帧率、码率、RTSP URL、进程状态等信息。

## 当前部署边界

```text
Ubuntu 22.04 chroot
  -> openrd_video_node
  -> openrd-video-systemd
  -> host systemctl

RK3588 native Debian
  -> openrd-video-native.service
  -> openrd-video-native supervise
  -> GStreamer / MPP / V4L2
  -> MediaMTX
```

默认参数：

- `runtime_cli`: `/workspace/OpenRD/vehicle/native_video/openrd-video-systemd`；
- `mode`: `rtsp`；
- `device`: `/dev/openrd-cam-front`；
- `rtsp_url`: `rtsp://127.0.0.1:8554/live`；
- `rtsp_protocols`: `tcp`；
- `rtsp_latency_ms`: `100`。

## 视频链路

当前长期运行链路：

```text
/dev/openrd-cam-front
  -> v4l2src
  -> mpph264enc
  -> h264parse
  -> rtspclientsink rtsp://127.0.0.1:8554/live
  -> MediaMTX live
  -> RTSP / WebRTC
```

板端默认播放地址：

```text
RTSP:   rtsp://192.168.100.108:8554/live
WebRTC: http://192.168.100.108:8889/live/
```

MediaMTX 预留 `live-front`、`live-rear`、`openrd` publisher 路径，但默认服务只运行一路 `live`。

## ROS2 接口

Topic：

```text
/openrd/video_state        openrd_msgs/msg/VideoState
```

Service：

```text
/openrd/start_runtime      std_srvs/srv/Trigger
/openrd/stop_runtime       std_srvs/srv/Trigger
/openrd/restart_runtime    std_srvs/srv/Trigger
```

## 健康检查与恢复

`openrd-video-native.service` 当前默认启用 supervisor：

- RTSP 模式下，健康检查必须实际读取到视频帧；
- 连续失败后最多健康重启 1 次视频 runtime；
- 默认最多重启 1 次 `rkaiq_3A.service`；
- 仍失败则写入 `faulted` 状态并以退出码 42 停止，systemd 不会无限重启；
- `mediamtx.service`、`rkaiq_3A.service`、`openrd-video-native.service` 均应保持 systemd `enabled`，但 fault 后需要人工检查 camera/ISP/V4L2 再手动恢复。

如果浏览器控制台在断流后出现 404，通常表示 MediaMTX 短时间内没有可用 `live` publisher。常见原因是上游 RK 摄像头/ISP/V4L2 链路停止吐帧，而不是 WebRTC 页面文件缺失。

常见底层日志：

```text
rkcif-mipi-lvds: stream[0] not active buffer
rkisp_stream_stop id:0 timeout
imx415 ... start stream failed while write regs
```

## 重要决策

OpenRD 不把低延迟驾驶视频强制放入 ROS2 `sensor_msgs/Image` 主链路。

原因：

- 浏览器和 Flutter 更适合接收 WebRTC、RTSP 或其他流媒体协议；
- ROS2 image topic 对远程驾驶视频延迟和带宽不一定最优；
- 控制链路不能被视频链路阻塞；
- 后续 YOLO/RKNN 检测可以单独设计采集或共享 pipeline。

## 后续方向

- 双摄扩展时复用 `live-front` / `live-rear` 命名；
- 把当前 `gst-launch-1.0` runtime 收敛为更可控的 GStreamer API/C++ runtime；
- 为 WebRTC、公网 TURN、检测叠加等能力补充独立状态和配置。
