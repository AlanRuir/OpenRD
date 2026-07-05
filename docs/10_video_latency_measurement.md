# 10 视频延迟测量方案

本文档定义 OpenRD 视频链路实时延迟的测量方案。当前推荐路线是：在 RK3588 采集/编码侧把每帧采集时间戳写入 H.264/H.265 SEI，接收侧 sidecar 解析 SEI 并计算延迟，再通过云端状态 API 给前端显示。

核心原则：

- 延迟指标用于观测、调试和 UI 提示，不参与安全停车判断；
- 优先测清当前 RTMP -> ZLMediaKit -> HTTP-FLV/RTSP 链路，不先改 Flutter 播放器；
- 先验证 SEI 是否能穿过当前转封装链路，再接入云端状态和前端 UI；
- 控制链路和视频链路仍保持分离，视频延迟数据只作为状态上报。

## 目标

- 实时显示视频链路延迟；
- 区分视频链路延迟和控制链路延迟；
- 支持当前单路 H.264 RTMP 推流链路；
- 后续可扩展到 H.265、WebRTC、双摄或多车；
- 为优化编码参数、播放器缓冲和网络路径提供可量化指标。

## 非目标

- 不把视频延迟作为控制安全判断依据；
- 不要求浏览器 `<video>` 或当前 Flutter Web 播放器直接解析 SEI；
- 不要求第一版测到严格的 glass-to-glass 渲染延迟；
- 不在第一版引入复杂账号、回放、统计数据库或长期存储；
- 不为了测量延迟而强制把驾驶视频改成 ROS2 image topic。

## 延迟定义

需要明确不同测量点的含义：

```text
camera exposure / sensor capture
  -> V4L2 buffer ready
  -> application receives frame
  -> encoder outputs H.264/H.265
  -> RTMP publish
  -> ZLMediaKit relay
  -> receiver sidecar parses frame
  -> browser decodes frame
  -> frame rendered on screen
```

本文档第一阶段重点测：

```text
capture_ts -> receiver sidecar parses the same frame
```

这可以反映编码、推流、云端中继和接收侧拉流路径的总延迟。它不完全等于用户眼睛看到画面的 glass-to-glass 延迟，因为浏览器播放器缓冲、解码和渲染还会额外增加延迟。

后续如果需要严格 glass-to-glass，可以再叠加浏览器端解码/渲染时间统计，或用画面内时间戳做人工校验。

## 基本思路

发送侧为每帧生成元数据：

```text
frame_seq
capture_realtime_ns
capture_monotonic_ns
source_id / camera_id
```

然后把这份元数据写入 H.264/H.265 的 `SEI user_data_unregistered`。

接收侧从码流中解析 SEI：

```text
video frame with SEI
  -> parse OPENRD SEI payload
  -> now_realtime_ns - capture_realtime_ns
  -> video_latency_ms
```

如果接收侧和发送侧在同一台机器上，也可以使用 monotonic 时间戳计算；如果跨机器计算，必须使用同步后的 wall clock。

## 当前推荐架构

当前视频主链路是：

```text
RK3588 openrd-video-native
  -> RTMP
腾讯云 ZLMediaKit
  -> HTTP-FLV / RTSP
Flutter 前端
```

推荐新增一个云端 sidecar：

```text
RK3588 openrd-video-native
  -> H.264 SEI: capture_ts + frame_seq
  -> RTMP
腾讯云 ZLMediaKit
  -> local RTSP/HTTP-FLV pull
openrd-video-latency-sidecar
  -> parse SEI
  -> compute latency stats
openrd-control-service
  -> expose video/status fields
Flutter 前端
  -> display video latency
```

不建议第一版让 Flutter Web 直接解析 SEI。普通浏览器视频元素通常拿不到原始 H.264/H.265 NAL 单元；强行在前端拆 HTTP-FLV 和码流会明显增加复杂度，也会和播放器实现绑定。

## 时间戳来源

优先级：

1. `v4l2_buffer.timestamp`
   - 如果驱动提供的是有效采集时间，它最接近真实帧采集点；
   - 需要确认该时间戳的 clock domain，是 monotonic 还是 realtime。
2. 应用层收到帧时的 `CLOCK_MONOTONIC_RAW`
   - 稳定、抗系统时间跳变；
   - 适合同机调试，跨机器不能直接相减。
3. 应用层收到帧时的 `CLOCK_REALTIME`
   - 适合跨机器直接相减；
   - 必须依赖 NTP/chrony 同步。

第一版建议 SEI 同时携带：

```text
capture_realtime_ns
capture_monotonic_ns
```

云端 sidecar 用 `capture_realtime_ns` 计算跨机器延迟；本机调试工具可用 `capture_monotonic_ns` 排除 wall clock 抖动。

## 时钟同步要求

如果延迟在云端 sidecar 计算：

```text
latency_ms = (cloud_now_realtime_ns - vehicle_capture_realtime_ns) / 1_000_000
```

则 RK3588 和云端服务器都必须保持时钟同步。建议：

- RK3588 启用 `chrony` 或等效 NTP 客户端；
- 云端服务器启用 `chrony`；
- sidecar 同时上报本机时钟同步状态；
- 如果发现时钟偏移过大，应把视频延迟状态标记为 `clock_unsynced`，而不是显示看似精确的数值。

## SEI payload 设计

使用 `user_data_unregistered`，包含固定 UUID 和 OpenRD 自定义二进制 payload。

建议 UUID 固定为项目级常量，避免和其他 SEI payload 混淆。payload 第一版使用固定小端二进制结构，避免引入 JSON/CBOR 解析开销。

当前代码实现使用的 UUID：

```text
4f70656e-5244-5345-492d-6c6174656e63
```

建议结构：

```text
magic                  8 bytes   "OPENRDSE"
version                uint8     1
flags                  uint8     reserved
header_size            uint16    fixed header bytes
payload_size           uint16
codec                  uint8     1=h264, 2=h265
timebase               uint8     1=ns
frame_seq              uint64
capture_realtime_ns    uint64
capture_monotonic_ns   uint64
source_id_hash         uint32
reserved               uint32
```

说明：

- `frame_seq` 用于判断丢帧、乱序和 parser 是否漏帧；
- `capture_realtime_ns` 用于跨机器延迟计算；
- `capture_monotonic_ns` 用于同机调试；
- `source_id_hash` 可先固定为 0，后续双摄时区分左右摄像头；
- 第一版不需要每帧写复杂字符串，避免增加码流体积和解析成本。

## H.264 / H.265 处理边界

第一版优先 H.264，因为当前公网链路已经使用 H.264 RTMP 推流。

插入位置：

- 每个 access unit 附近插入一条 SEI；
- 最好在对应帧的 VCL NAL 之前，便于 parser 先拿到时间戳；
- 如果实现难度较高，也可以先确保同一帧附近可解析到 SEI，再通过 frame sequence 对齐。

注意事项：

- 如果链路中发生转码，SEI 可能被丢弃；
- RTMP/FLV 转封装通常应保留 H.264 NAL，但必须实测验证；
- H.265 over RTMP 的兼容性比 H.264 更复杂，后续再扩展；
- 编码参数应保持低延迟，避免 B 帧重排序让测量解释变复杂。

## 接收侧 sidecar

推荐云端 sidecar 运行在 ZLMediaKit 同一台服务器上。

输入候选：

```text
rtsp://127.0.0.1/live/openrd
http://127.0.0.1:8888/live/openrd.live.flv
```

职责：

- 拉取当前直播流；
- 从 H.264/H.265 NAL 中解析 OpenRD SEI；
- 计算最新延迟、滑动平均、p50、p95；
- 记录最近帧号和最近更新时间；
- 把指标推送给 `openrd-control-service`，或写入本地状态文件供 control service 读取。

推荐输出字段：

```json
{
  "video_latency_ms": 180,
  "video_latency_avg_ms": 190,
  "video_latency_p50_ms": 170,
  "video_latency_p95_ms": 260,
  "video_frame_seq": 123456,
  "sidecar_first_sei_seen_ms": 1780000000000,
  "sidecar_first_sei_frame_seq": 0,
  "sidecar_first_sei_latency_ms": 180,
  "video_latency_updated_ms": 1780000000000,
  "video_latency_state": "ok"
}
```

`video_latency_state` 建议值：

- `ok`：正常解析并计算；
- `no_stream`：没有拉到视频流；
- `no_sei`：流存在但没有 OpenRD SEI；
- `clock_unsynced`：检测到时钟同步不可靠；
- `stale`：超过阈值没有新帧；
- `error`：parser 或输入链路异常。

当前已落盘第一版 sidecar：

```text
tools/video_latency/openrd_video_latency_sidecar.py
infra/systemd/openrd-video-latency-sidecar.service
```

默认读取：

```text
rtsp://127.0.0.1/live/openrd
```

默认写入：

```text
/tmp/openrd-video-latency.json
```

sidecar 通过 `ffmpeg` 把 RTSP/HTTP-FLV/RTMP 输入转成 H.264 Annex-B stdout，再解析 OpenRD SEI。也支持 `--stdin` 直接读取本地 Annex-B H.264 数据，方便本地文件验证。

## 云端 control service 集成

当前前端已经通过：

```text
GET /api/vehicles/openrd-001/video/status
```

获取视频状态。后续可把 sidecar 指标合并进这个响应。

建议新增字段：

```json
{
  "video_latency_ms": 180,
  "video_latency_p50_ms": 170,
  "video_latency_p95_ms": 260,
  "video_frame_seq": 123456,
  "sidecar_first_sei_seen_ms": 1780000000000,
  "sidecar_first_sei_frame_seq": 0,
  "sidecar_first_sei_latency_ms": 180,
  "video_latency_state": "ok",
  "video_latency_updated_ms": 1780000000000
}
```

当前 `server/openrd_control_service/openrd_control_service.py` 已支持从 `OPENRD_VIDEO_LATENCY_STATUS_FILE` 读取 sidecar 状态并合并到 `/video/status`。默认路径为：

```text
/tmp/openrd-video-latency.json
```

如果文件不存在，接口返回 `video_latency_state=unknown`；如果 `video_latency_updated_ms` 超过 `OPENRD_VIDEO_LATENCY_STALE_MS`，接口返回 `video_latency_state=stale`。

前端只负责显示，不解析码流。

## 前端显示建议

状态栏：

```text
视频延迟 180ms
```

调试区：

```text
video latency: current=180ms p50=170ms p95=260ms seq=123456 state=ok
```

颜色建议：

```text
<150ms      绿色
150-300ms   黄色
300-600ms   橙色
>600ms      红色
无数据       灰色/橙色
```

如果 `video_latency_state != ok`，UI 应显示状态原因，不应显示过期数值冒充实时延迟。

当前 Flutter 前端已在顶部状态栏、实时视频面板和调试区读取 `/video/status` 中的视频延迟字段。前端仍不解析码流，只消费云端 API 返回值。

## 分阶段实现建议

### Phase 0：肉眼校验

先给画面叠加时间戳或递增帧号，用于人工估算延迟和验证方向。

验收：

- 画面内能看到车端时间戳或帧号；
- 前端播放时能人工估算延迟范围；
- 不要求自动统计。

### Phase 1：本地 SEI 注入验证

目标是证明 OpenRD SEI 能写入 H.264 文件或本地流。

任务：

- 在 RK3588 视频生成链路中为每帧构造 SEI；
- 输出到本地 H.264 文件或本地 RTSP；
- 用测试 parser 解析出 `frame_seq` 和时间戳。

验收：

- 本地文件/流能解析出连续或近似连续的 `frame_seq`；
- 时间戳随帧递增；
- 不影响现有视频播放。

当前已实现工具：

```text
tools/video_latency/openrd_sei.py
tools/video_latency/openrd_h264_sei_filter.py
tools/video_latency/openrd_video_sei.py
tools/video_latency/test_openrd_sei.py
tools/video_latency/README.md
```

本地文件验证示例：

```bash
python3 tools/video_latency/openrd_video_sei.py inject-h264 \
  /tmp/openrd-camera.h264 /tmp/openrd-camera-sei.h264 \
  --fps 30 --source-id openrd-uvc

python3 tools/video_latency/openrd_video_sei.py inspect-h264 \
  /tmp/openrd-camera-sei.h264 --json --latency
```

注意：这一步使用文件级注入验证 payload/SEI/parser，不等同于当前 `openrd-video-native` 实时推流已经逐帧注入采集时间戳。实时注入需要后续把 shell 版 `gst-launch-1.0` pipeline 升级到可按 buffer 处理 metadata 的 GStreamer API/C++/Python runtime，或在编码后增加专门的 bitstream filter。

当前已经增加编码后 bitstream filter 路径：

```text
openrd-video-native --mode rtmp-sei
  -> gst-launch byte-stream H.264 stdout
  -> openrd_h264_sei_filter.py
  -> ffmpeg copy/remux RTMP
```

这个路径先使用过滤器看到 VCL NAL 时的 `CLOCK_REALTIME`/`CLOCK_MONOTONIC` 写 SEI。它能先让 ZLMediaKit 保留 SEI、sidecar 解析和前端显示形成闭环，但还不是严格的 V4L2 capture timestamp。严格采集时间戳仍需要后续 GStreamer API/C++ runtime。

### Phase 2：验证 ZLMediaKit 是否保留 SEI

目标是确认当前 RTMP -> ZLMediaKit -> RTSP/HTTP-FLV 转发链路不会剥离 SEI。

任务：

- 推送带 SEI 的 H.264 到云端 ZLMediaKit；
- 从云端 RTSP 或 HTTP-FLV 拉流；
- 在云端或本机 parser 中解析 OpenRD SEI。

验收：

- 经过 ZLMediaKit 后仍能解析 `frame_seq`；
- parser 能统计丢帧、重复帧和延迟；
- 如果 SEI 被丢弃，必须调整 parser 位置或推流封装策略。

### Phase 3：云端 sidecar 与状态 API

目标是让云端自动计算视频延迟并通过状态 API 暴露。

任务：

- 新增 `openrd-video-latency-sidecar` 或等效进程；
- sidecar 拉取 ZLMediaKit 本地流并解析 SEI；
- sidecar 输出延迟状态；
- `openrd-control-service` 将指标合并进 `/video/status`。

验收：

- 前端无需解析视频流即可拿到 `video_latency_ms`；
- 无视频流时状态为 `no_stream`；
- 有流但无 SEI 时状态为 `no_sei`；
- 延迟数据过期时状态为 `stale`。

### Phase 4：前端展示

目标是在 Flutter 前端显示视频延迟。

任务：

- 视频状态栏增加延迟显示；
- 调试区显示 p50/p95、帧号和状态；
- 过期或异常时显示状态原因。

验收：

- 启动视频后前端能看到实时视频延迟；
- 停止视频后延迟状态不再显示为正常；
- 网络抖动时 p95 能反映异常。

## 风险与缓解

### SEI 被中间链路丢弃

缓解：

- Phase 2 必须实测；
- 如果 ZLMediaKit 拉流输出丢 SEI，可把 sidecar 放到 ZLMediaKit ingest 前或 RK3588 出站侧；
- 避免引入转码链路。

### 浏览器无法解析 SEI

缓解：

- 第一版不让 Flutter Web 解析码流；
- 使用云端 sidecar 解析；
- 前端只读取 control service 状态字段。

### 两端时钟不同步

缓解：

- RK3588 和云端都启用 chrony/NTP；
- sidecar 上报时钟同步状态；
- 时钟异常时不显示数值。

### B 帧或缓冲导致解释困难

缓解：

- 当前驾驶视频优先使用低延迟编码参数；
- 第一版尽量禁用 B 帧；
- UI 中区分当前值、p50 和 p95，不只看单帧瞬时值。

### 指标被误用为安全判断

缓解：

- 文档和代码中保持约束：视频延迟只用于观测；
- 控制安全仍由 control agent watchdog、ROS2 safety 和 ESP32 超时停车负责。

## 当前建议

短期不要先改 Flutter 播放器。推荐顺序：

1. 先做画面时间戳叠加，获得肉眼基准；
2. 做本地 H.264 SEI 注入和解析验证；
3. 验证 SEI 能穿过 RTMP/ZLMediaKit；
4. 做云端 sidecar；
5. 扩展 `/video/status`；
6. 前端显示视频延迟。

这条路线可以把风险集中在码流处理和中间转封装验证上，不干扰当前已经可用的视频播放与底盘控制链路。
