# 11 视频启动耗时排查方案

本文档记录 OpenRD 当前“点击启动视频推流到浏览器看到首帧”的排查方案。它关注的是视频链路冷启动耗时，不是已经显示在前端的实时播放缓冲或 SEI 云端延迟。

当前视频链路是按需启动，不是常驻热流。一次启动会串行经过云端命令、RK3588 agent、systemd、摄像头/GStreamer/MPP 编码、SEI filter、ffmpeg RTMP 推流、ZLMediaKit 出流和浏览器 HTTP-FLV 播放器。启动慢通常不是单点问题，而是多个阶段叠加。

## 目标

- 拆出视频启动耗时的各个阶段；
- 找到“慢在车端启动、推流注册、云端中继还是浏览器播放器”；
- 给后续优化提供可验证依据；
- 避免凭主观感觉调参数。

## 当前启动路径

前端点击启动后，路径如下：

```text
Flutter Web
  -> POST /api/vehicles/openrd-001/video/start
  -> openrd-control-service 入队 video.start
  -> RK3588 openrd-video-agent long-poll 取命令
  -> sudo systemctl start openrd-video-native.service
  -> openrd-video-native supervise
  -> GStreamer 打开 V4L2 摄像头
  -> MJPEG 解码
  -> MPP H.264 编码
  -> openrd_h264_sei_filter.py 插入 SEI
  -> ffmpeg 封装 FLV 推 RTMP
  -> 腾讯云 ZLMediaKit 注册 live/openrd
  -> 浏览器 mpegts.js 拉 HTTP-FLV
  -> video playing / 首帧可见
```

## 需要打点的时间戳

所有时间戳统一使用 Unix epoch 毫秒，字段名建议使用 `_ms` 后缀。浏览器、云端、RK3588 之间的绝对时间可能有偏差，所以端到端耗时只作为辅助；同一机器上的相邻阶段耗时更可靠。

| 字段 | 位置 | 含义 |
| --- | --- | --- |
| `frontend_start_click_ms` | Flutter Web | 用户点击启动按钮 |
| `cloud_start_request_ms` | control service | 云端收到 `/video/start` |
| `cloud_command_enqueued_ms` | control service | `video.start` 入队 |
| `agent_command_received_ms` | RK3588 video agent | agent 收到 `video.start` |
| `agent_systemctl_start_begin_ms` | RK3588 video agent | 开始执行 `systemctl start` |
| `agent_systemctl_start_done_ms` | RK3588 video agent | `systemctl start` 返回 |
| `native_supervise_enter_ms` | RK3588 native runtime | `openrd-video-native supervise` 进入 |
| `native_pipeline_spawn_ms` | RK3588 native runtime | GStreamer/ffmpeg pipeline 进程启动 |
| `native_first_sei_injected_ms` | RK3588 SEI filter | 第一帧 SEI 被插入 |
| `sidecar_first_sei_seen_ms` | 云端 sidecar | 云端第一次解析到 SEI |
| `frontend_player_created_ms` | Flutter Web iframe | HTTP-FLV player 创建 |
| `frontend_video_playing_ms` | Flutter Web iframe | HTMLVideoElement 触发 `playing` |
| `frontend_first_metrics_ms` | Flutter Web iframe | 第一次播放缓冲指标上报 |

## 阶段耗时计算

建议先看以下阶段：

| 阶段 | 计算 | 判断 |
| --- | --- | --- |
| 前端到云端 | `cloud_start_request_ms - frontend_start_click_ms` | 主要受公网 RTT 和浏览器请求影响 |
| 云端排队到 agent 收命令 | `agent_command_received_ms - cloud_command_enqueued_ms` | 正常 long-poll 下应接近 0；如果接近 `OPENRD_VIDEO_AGENT_POLL_WAIT_SEC`，说明 agent 没有保持长轮询或刚好异常重连 |
| agent 调 systemd | `agent_systemctl_start_done_ms - agent_systemctl_start_begin_ms` | 反映 systemd 启动返回耗时，不等于视频已经出流 |
| native 冷启动 | `native_first_sei_injected_ms - native_pipeline_spawn_ms` | 反映摄像头、GStreamer、解码、编码链路出第一帧耗时 |
| 车端到云端首帧 | `sidecar_first_sei_seen_ms - native_first_sei_injected_ms` | 反映 RTMP 推流、ZLM 接收和 sidecar 拉流解析耗时，但受两端时钟偏差影响 |
| 浏览器接入 | `frontend_video_playing_ms - frontend_player_created_ms` | 反映 HTTP-FLV 拉流、mpegts.js 解封装和浏览器解码缓冲耗时 |
| 点击到可见画面 | `frontend_video_playing_ms - frontend_start_click_ms` | 用户体感启动耗时 |

## 现有可能慢点

当前实现里已知有这些等待或冷启动成本：

- `openrd-video-agent` 调 `systemctl start` 后固定等待约 `1.5s` 再读状态；
- `openrd-video-agent` 默认 `OPENRD_VIDEO_AGENT_STATUS_INTERVAL_SEC=3`，状态上报不是实时；
- `openrd-video-native.service` 是按需启动，GStreamer/摄像头/MPP 编码器每次都冷启动；
- RTMP 推流到 ZLMediaKit 后，需要等流注册并有可解码数据；
- H.264 播放通常依赖 SPS/PPS 和关键帧，GOP 越长，最坏首帧等待可能越明显；
- 浏览器 `mpegts.js` 需要建立 HTTP-FLV 连接、解封装、喂 MSE，并保留一定播放缓冲；
- 当前播放器配置里 `liveBufferLatencyMaxLatency` 为 `1.5`，这解释了播放稳定后约 `1500ms` 的缓冲延迟，但它不是全部启动耗时。

## 排查步骤

### 1. 记录前端体感时间

打开浏览器 DevTools Console，点击“启动视频推流”，记录：

- 点击按钮时间；
- 状态栏从 `加载中` 到 `已打开` 的时间；
- `播放缓冲` 第一次出现数值的时间；
- 首帧可见时间。

如果没有新增代码打点，先用手机秒表或浏览器 Performance 面板粗测即可。

### 2. 看云端命令是否及时被 agent 取走

在云端查看 control service 日志：

```bash
sudo journalctl -u openrd-control.service -f
```

重点观察：

- `/video/start` 请求是否立即返回 `202`；
- `openrd-video-agent` 是否在线；
- start 后 `/video/status` 是否从 `stopped` 变为 `starting/running`。

如果 `start` 返回慢或 `vehicle_offline`，问题在云端服务或 video agent 在线状态。

### 3. 看 RK3588 video agent

在 RK3588 上查看：

```bash
sudo journalctl -u openrd-video-agent.service -f
```

重点观察：

- 是否快速打印 `command video.start`；
- `systemctl start openrd-video-native.service` 是否失败或超时；
- 是否有 `agent error`。

如果点击后很久才看到 `command video.start`，优先查 agent 长轮询、网络或云端队列。

### 4. 看 native video runtime

在 RK3588 上查看：

```bash
sudo journalctl -u openrd-video-native.service -f
tail -f /home/linaro/OpenRD/vehicle/native_video/run/openrd-video-native.log
```

重点观察：

- `starting OpenRD native video runtime`；
- 摄像头设备选择；
- GStreamer/MPP/ffmpeg 是否有 warning 或重试；
- 是否出现健康检查失败和自动重启。

同时查看状态：

```bash
/home/linaro/OpenRD/vehicle/native_video/openrd-video-native status --json
```

如果 service 很快 active，但前端迟迟没画面，说明慢点更可能在推流注册、云端中继或浏览器接入。

### 5. 看云端 ZLMediaKit 和 SEI sidecar

在云端查看：

```bash
sudo journalctl -u openrd-video-latency-sidecar.service -f
curl -s http://127.0.0.1:8790/api/vehicles/openrd-001/video/status
```

重点观察：

- `video_latency_state` 何时从 `no_stream/no_sei/stale` 变为 `ok`；
- `video_frame_seq` 是否增长；
- `video_latency_updated_ms` 是否刷新。

如果 sidecar 很快看到 SEI，但浏览器迟迟不出画，慢点基本在浏览器 HTTP-FLV/MSE 播放阶段。

### 6. 看浏览器播放器

打开 DevTools Network：

- 找 `http://43.139.25.165:8888/live/openrd.live.flv`；
- 看请求开始时间、首字节时间、是否持续下载；
- 看 Console 是否有 mpegts.js 错误；
- 看前端 `播放缓冲` 是否出现并持续更新。

如果 FLV 请求很快开始且持续下载，但 `playing` 很慢，优先查播放器配置、浏览器 MSE 缓冲和关键帧等待。

## 建议新增的代码打点

为了下一步精确定位，可以分阶段加最小打点：

1. control service 在 `/video/start` 响应里返回 `cloud_start_request_ms` 和 `cloud_command_enqueued_ms`；
2. video agent 收到命令、执行 systemd 前后打印 epoch ms；
3. `openrd-video-native` 在启动 pipeline 前写日志 epoch ms；
4. `openrd_h264_sei_filter.py` 第一帧注入时向 stderr 打一行 `first_sei_injected_ms=...`；
5. sidecar 第一次解析到当前流 SEI 时写 `first_sei_seen_ms=...`；
6. iframe player 在 `createPlayer`、`load`、`playing`、第一次 metrics 时 postMessage 给 Flutter；
7. 前端调试面板显示启动分段耗时。

建议先只打日志，不直接改变启动逻辑。确认瓶颈后再决定是否优化。

## 优化方向

根据排查结果选择优化：

| 瓶颈 | 可能优化 |
| --- | --- |
| agent 拿命令慢 | 降低 `OPENRD_VIDEO_AGENT_POLL_WAIT_SEC`，或确认 long-poll 连接未被代理/网络中断 |
| systemd 返回慢 | 检查 service 依赖、sudo 权限、启动脚本阻塞点 |
| 摄像头/GStreamer 冷启动慢 | 保持 native runtime 热启动但不公开播放，或拆分采集/推流生命周期 |
| 首个关键帧慢 | 降低 GOP、确保 SPS/PPS 每个 IDR 输出、启动时强制尽快出 IDR |
| RTMP/ZLM 注册慢 | 检查 ZLM 日志、RTMP 握手、云端 CPU/网络 |
| 浏览器接入慢 | 调 mpegts.js 缓冲参数、减少启动 stash、在启动后追 live edge |
| 播放缓冲稳定在约 1500ms | 调 `liveBufferLatencyMaxLatency` 和追帧策略，但要避免卡顿 |

## 验收标准

建议先定义两个指标：

- 冷启动耗时：从点击启动到浏览器 `playing`，目标先压到 `3s` 以内；
- 热重连耗时：视频已在云端运行时，从点击重连到 `playing`，目标先压到 `1s` 以内。

最终优化前后都要记录同一套阶段耗时，避免只看主观体感。

## 2026-06-24 实测记录

测试环境：

- 车辆：`openrd-001`
- RK3588：`192.168.100.108`
- 云端：`43.139.25.165`
- 视频模式：`rtmp-sei`
- 播放地址：`http://43.139.25.165:8888/live/openrd.live.flv`

本次测试通过诊断 viewer 触发一次 `/video/start`，同时轮询 `/video/status`，并用 `curl` 反复探测 HTTP-FLV 首字节。测试结束后释放本次 viewer lease，视频服务回到 stopped。

关键结果：

| 阶段 | 耗时 |
| --- | --- |
| `/video/start` HTTP 返回 | 1160ms |
| `/video/status` 首次看到 `video_state=running` | 3337ms |
| HTTP-FLV 首字节可读 | 8717ms |
| `/video/status` 首次看到 `video_latency_state=ok` | 10699ms |
| 首个 SEI frame seq | 240 |
| 首个云端 SEI 延迟 | 40ms |

对应日志时间点：

| 时间 | 位置 | 事件 |
| --- | --- | --- |
| 2026-06-24 01:03:47 CST | RK3588 video agent | 收到 `video.start`，执行 `systemctl start openrd-video-native.service` |
| 2026-06-24 01:03:48 CST | RK3588 native runtime | `openrd-video-native supervise` 进入，启动 GStreamer/SEI/ffmpeg pipeline |
| 2026-06-24 01:03:54.028 CST | ZLMediaKit | RTMP publish 回复 |
| 2026-06-24 01:03:54.090 CST | ZLMediaKit | `fmp4://__defaultVhost__/live/openrd` 媒体注册 |
| 2026-06-24 01:03:54.963 CST | ZLMediaKit | `rtsp/rtmp/ts://__defaultVhost__/live/openrd` 媒体注册 |
| 2026-06-24 01:03:56 CST | control status | SEI sidecar 状态进入 `ok` |

初步判断：

- 云端控制命令和 RK3588 agent 取命令不是主要瓶颈；
- `systemctl start` 不是主要瓶颈，service 在约 3.3s 内被状态 API 识别为 running；
- 主要耗时在 `openrd-video-native` 启动 pipeline 后，到云端 ZLMediaKit 完成 RTMP publish/媒体注册之间，约 6-7 秒；
- SEI 状态比 HTTP-FLV 首字节晚约 2 秒，主要受 sidecar 重连窗口影响；
- sidecar 在无流时会反复因 `no such stream`/ffmpeg 退出而由 systemd 重启，当前日志里可见 `status=2/INVALIDARGUMENT` 重启循环。这不影响视频本身出画，但会让“云端 SEI 延迟接入”滞后。

下一步建议：

1. 给 `openrd-video-native` 和 `openrd_h264_sei_filter.py` 增加毫秒级首帧打点，确认第一帧 H.264/SEI 到底在 native 启动后多少毫秒产生；
2. 给 ffmpeg 推流命令补充时间戳策略实验，例如 `-use_wallclock_as_timestamps 1` 或 `-fflags +genpts`，消除当前日志中的 `Timestamps are unset in a packet` 警告；
3. 调整 sidecar 策略，让它不要依赖 systemd 反复重启来等流，而是在进程内短间隔重连，这样 SEI 指标能更快接入；
4. 在前端 iframe 上报 `player_created`、`load_called`、`playing`，补齐浏览器首帧阶段的实际耗时。

### 2026-06-24 优化后复测

已落地变更：

- `openrd-video-native` 默认按 `rtmp-sei` 模式启动，并给 ffmpeg 推流链路使用 `wallclock` 时间戳策略；
- `openrd_h264_sei_filter.py` 在第一帧注入时打印 `first_sei_injected_ms=...`；
- 云端 sidecar 改为进程内重连，并在第一次解析到 SEI 时写入 `sidecar_first_sei_seen_ms`、`sidecar_first_sei_frame_seq` 和 `sidecar_first_sei_latency_ms`；
- sidecar 的 ffmpeg RTSP 输入超时改为 `-stimeout 5000ms`。实测云端 ffmpeg 不支持 `-rw_timeout`，使用该参数会直接退出并导致状态长期停在 `no_stream`；`-stimeout 2000ms` 对当前 ZLMediaKit RTSP 活流过短，容易读不到数据。

本轮通过诊断 viewer 触发一次冷启动，结束后主动释放 viewer lease。

| 阶段 | 耗时 |
| --- | --- |
| `/video/start` HTTP 返回 | 80ms |
| `/video/status` 首次看到 `video_state=running` | 2446ms |
| HTTP-FLV 首字节可读 | 2811ms |
| `sidecar_first_sei_seen_ms` | 5279ms |
| `/video/status` 首次看到 `video_latency_state=ok` | 5448ms |
| 首个 sidecar SEI frame seq | 31 |
| 首个 sidecar SEI 延迟 | 2506ms |

对应日志时间点：

| 时间 | 位置 | 事件 |
| --- | --- | --- |
| 2026-06-24 10:44:40 CST | RK3588 video agent | 收到 `video.start`，执行 `systemctl start openrd-video-native.service` |
| 2026-06-24 10:44:41 CST | RK3588 native runtime | `openrd-video-native supervise` 进入，启动 GStreamer/SEI/ffmpeg pipeline |
| 2026-06-24 10:44:41.666 CST | RK3588 SEI filter | 打印 `first_sei_injected_ms=1782269081666 frame_seq=0 nal=4` |
| 2026-06-24 10:44:42.629 CST | ZLMediaKit | RTMP publish 回复 |
| 2026-06-24 10:44:42.691 CST | ZLMediaKit | `fmp4://__defaultVhost__/live/openrd` 媒体注册 |
| 2026-06-24 10:44:43.025 CST | ZLMediaKit | `rtsp/rtmp/ts://__defaultVhost__/live/openrd` 媒体注册 |

当前判断：

- 启动体感慢的主要瓶颈已经从“约 8-10 秒才有 FLV/SEI”降到“约 2.8 秒有 HTTP-FLV 首字节”；
- sidecar 可以正确进入 `ok`，但首个 SEI 接入仍比 HTTP-FLV 首字节晚约 2.5 秒，主要受 RTSP `-stimeout 5000ms` 和重连相位影响；
- 第一帧 SEI 在点击后约 1.4 秒已经由 RK3588 注入，ZLMediaKit 在约 2.5-2.8 秒完成注册和出流，后续继续压缩应优先看浏览器播放器首帧/缓冲策略以及 sidecar 拉流触发时机。
