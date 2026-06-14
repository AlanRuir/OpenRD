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
- RK 摄像头实时预览
- 支持 MediaMTX 的 WebRTC 页面嵌入
- 折叠式调试区和事件日志

## 运行方式

在工程目录执行：

```bash
flutter run -d chrome
```

如果你已经用 `flutter build web --release` 打包了，也可以直接用任意静态服务器打开 `build/web`。

## 视频配置

前端视频区需要填写：

- `RK IP`：RK3588 板子的 IP
- `Path`：MediaMTX 的流路径，默认是 `live`
- `WebRTC`：走 `http://<rk-ip>:8889/<path>`，作为低延迟主链路

MediaMTX 官方文档说明浏览器可以直接访问 WebRTC 页面，也支持把它嵌入到外部网站中。

## 手柄输入

当前 Web 端通过浏览器 Gamepad API 轮询手柄状态，并把输入映射到前端本地驾驶状态：

- 左摇杆 X：方向
- 左摇杆 Y：油门/倒车
- LT/RT：倒车/油门
- D-pad：数字方向输入
- A/B：停止

手柄面板会显示连接状态、设备名和当前按下的按钮；方向/油门显示的是已经映射后的驾驶值。当前阶段只接入前端状态和事件日志，尚未通过 WebSocket/ROS2 发给车端。

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
  "stop": true,
  "source": "gamepad"
}
```

当前阶段控制链路只到 mock server，尚未接 ROS2 bridge 和 ESP32 dry-run。

## 注意

- 当前前端优先服务于局域网 MVP。
- 如果浏览器拦截自动播放，先保留 `静音` 选项，再手动点击播放。
