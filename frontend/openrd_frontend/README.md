# openrd_frontend

OpenRD 的 Flutter 前端，当前先做 Web MVP：驾驶控制台 + 实时视频预览。

## 当前能力

- 顶部驾驶状态栏
- 大屏实时视频主视图
- 右侧驾驶控制侧栏
- 前/后/左/右/停备用控制按钮
- 触屏摇杆输入区
- 浏览器 Gamepad API 手柄输入
- WebSocket 控制输出和本地 mock server 验证
- OpenRD-Driver HTTP 直连控制
- OpenRD-Driver 电池电压/电量显示
- RK 摄像头实时预览
- 支持云端 ZLMediaKit HTTP-FLV 视频播放
- 折叠式调试区和事件日志

## 运行方式

在工程目录执行：

```bash
flutter run -d chrome
```

如果你已经用 `flutter build web --release` 打包了，也可以直接用任意静态服务器打开 `build/web`。

## 视频配置

前端视频区默认播放腾讯云 ZLMediaKit 的 HTTP-FLV 公网流：

```text
http://43.139.25.165:8888/live/openrd.live.flv
```

调试区的视频字段含义：

- `ZLM Host`：ZLMediaKit 服务器地址，默认是 `43.139.25.165`
- `Path`：ZLMediaKit 流路径，默认是 `live/openrd`
- `Cloud API`：公网视频控制服务地址，默认是 `http://43.139.25.165:8790`
- 实际播放 URL 会自动拼成 `http://<zlm-host>:8888/<path>.live.flv`

视频面板不会在页面打开时自动拉起推流。点击“启动视频推流”后，前端会请求云端 control service，再由 RK3588 上的 `openrd-video-agent` 启动 `openrd-video-native.service`。视频播放期间前端每 30 秒续约一次；点击“停止视频推流”或续约超时后，车端会停止推流以避免持续消耗公网流量。

RK3588 板端通过 `openrd-video-native.service` 主动推送 RTMP 到云端：

```text
rtmp://43.139.25.165:1935/live/openrd
```

不需要看视频时可以停止板端推流，避免消耗公网流量：

```bash
ssh linaro@192.168.100.108 "sudo systemctl stop openrd-video-native.service"
```

需要恢复视频时再启动：

```bash
ssh linaro@192.168.100.108 "sudo systemctl start openrd-video-native.service"
```

ZLMediaKit 服务器当前关闭 HLS/MP4 录制，只做直播转发，避免生成切片或录像文件占用磁盘。本机 MediaMTX/WebRTC 链路保留为局域网回退调试方案，但不再是前端默认播放源。

## 手柄输入

当前 Web 端通过浏览器 Gamepad API 轮询手柄状态，并把输入映射到前端本地驾驶状态：

- 左摇杆 X：方向
- 左摇杆 Y：油门/倒车
- LT/RT：倒车/油门
- D-pad：数字方向输入
- A/B：停止

手柄面板会显示连接状态、设备名和当前按下的按钮；方向/油门显示的是已经映射后的驾驶值。连接 OpenRD-Driver HTTP 地址后，前端会按速度上限把手柄输入换算成四路电机速度并发送给 ESP32。

## OpenRD-Driver 直连

默认控制地址：

```text
http://192.168.100.114
```

点击顶部“连接”后，前端会先请求：

```text
GET /status
```

确认目标是 `OpenRD-Driver`。连接成功后，手柄、触屏摇杆和备用控制按钮都会通过：

```text
POST /control
```

发送 `m1`、`m2`、`m3`、`m4` 四路速度。换算规则：

- 前进/后退：四轮同向。
- 当前实车物理映射：`M1/M2 = 左侧`，`M3/M4 = 右侧`。
- 左旋：`[-,-,+,+]`。
- 右旋：`[+,+,-,-]`。
- 组合输入会归一化，不超过界面里的“速度上限”。

建议首次实车测试把速度上限调到 `200` 或 `300`，确认方向正确后再提高。

连接 OpenRD-Driver 后，前端会每 3 秒刷新一次 `/status`，并在连接成功后立即请求一次 `/read_vol`，之后每 30 秒请求一次 `/read_vol` 触发驱动板读取电池电压。这个频率相对 10Hz 左右的电机速度控制通信很低，主要用于 UI 展示，不会明显增加驱动板压力。

顶部状态栏显示电池摘要，驾驶控制面板显示电压、估算百分比和状态提示。当前按 12V/3S 电池估算：

- 12.6V：满电参考；
- 10.8V 以下：低电提醒；
- 10.2V 以下：建议限速；
- 9.6V 以下：建议停止；
- 8.1V：硬件放电截止参考。

## 控制链路 mock

先用本地 mock WebSocket server 验证控制消息：

```bash
dart run ../../tools/mock_control_ws_server.dart
```

前端默认控制地址：

```text
ws://127.0.0.1:8080/control
```

连接后，前端会以约 20Hz 发送当前驾驶状态；急停/停止会立即插队发送。消息格式：

```json
{
  "type": "drive",
  "seq": 1,
  "timestamp_ms": 1710000000000,
  "steering": 0.0,
  "throttle": 0.0,
  "speed_limit": 500,
  "stop": true,
  "source": "gamepad"
}
```

WebSocket mock 仍保留，用于不接车时验证前端控制消息。HTTP 直连用于当前 ESP32/OpenRD-Driver 实车调试；后续接入 ROS2 bridge 时可以继续使用同一个上层手柄输入模型。

## 注意

- 当前前端默认使用云端 ZLMediaKit 视频流，控制链路仍可直连局域网内的 OpenRD-Driver。
- 如果浏览器拦截自动播放，先保留 `静音` 选项，再手动点击播放。
