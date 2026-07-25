# openrd_frontend

OpenRD 的 Flutter 前端，当前承担桌面端远程驾驶舱、手机端驾驶 HUD、视频预览、手柄/触屏输入和公网控制链路接入。

## 当前能力

- 桌面端 Apple 风格远程驾驶舱：暗色沉浸背景、顶部状态条、中心视频主画面、右侧控制轨。
- 手机端独立驾驶 HUD：横屏游戏化布局、触屏摇杆、速度档位、连接/急停控件。
- 浏览器 Gamepad API 手柄输入，支持方向、油门、D-pad 和停止按钮映射。
- 公网控制链路：默认连接 `http://43.139.25.165:8080/openrd-control`。
- 直连调试链路：仍可配置到 ESP32 / OpenRD-Driver HTTP 地址。
- 视频播放：默认 WHEP/WebRTC；部署页会通过 `http://43.139.25.165:8080/index/api/webrtc?app=live&stream=openrd&type=play` 同源反代播放，HTTP-FLV 仅作为 fallback。
- 视频按需启停：通过云端 control service 通知 RK3588 video agent 启停推流。
- 电池电压、电量估算、控制状态、视频状态和事件日志展示。
- 本地 Web 资源构建：CanvasKit 和中文字体随静态包发布，避免浏览器运行时依赖 Google CDN。

## 运行方式

开发调试：

```bash
flutter run -d chrome
```

本地静态调试：

```powershell
flutter build web --debug
python -m http.server 8791 --bind 127.0.0.1 -d build\web
```

浏览器打开：

```text
http://127.0.0.1:8791/
```

## 生产构建

云端发布使用 release build，并显式关闭 Flutter Web CDN 资源：

```powershell
flutter build web --release --base-href /openrd/ --no-web-resources-cdn
```

这样构建出的 `build/web/` 会包含：

- `canvaskit/`：本地 CanvasKit JS/WASM；
- `assets/assets/fonts/NotoSansSC.ttf`：OpenRD 前端本地字体，并映射为 Roboto family；
- `assets/FontManifest.json`：字体映射清单。

这么做的原因是国内网络环境下浏览器访问 `gstatic` 不稳定，CanvasKit 或 Roboto 字体加载失败时会出现黑屏、无文字或首屏卡住。

## 桌面端驾驶舱

桌面端入口仍是：

```text
http://43.139.25.165:8080/openrd/
```

桌面端布局原则：

- 视频是主内容，占据页面中心大面积区域；
- 顶部状态条只保留关键状态：底盘、视频、手柄、电池、输入模式、最近指令；
- 右侧控制轨固定承载连接、手动模式、急停、速度上限、电池和备用控制；
- 急停按钮保持红色高优先级，顶部和右侧均可触达；
- 调试配置和事件日志收进“系统检查器”，避免常态驾驶时干扰。

## 手机端驾驶 HUD

手机端当前使用独立入口：

```text
http://43.139.25.165:8080/openrd-mobile/
```

手机端设计目标是先保证控车体验：

- 横屏优先；
- 黑屏/视频不可用时也可低速调试控制；
- 左侧触屏摇杆、右侧速度和急停；
- 全屏/PWA 体验继续迭代；
- 手机端 HUD 已复用 WHEP/WebRTC 播放器；视频不可用时仍显示黑屏占位并保留低速控制。

## 视频配置

前端视频区默认播放腾讯云 ZLMediaKit 的 WHEP/WebRTC 流。浏览器部署入口使用 Caddy 同源反代：

```text
http://43.139.25.165:8080/index/api/webrtc?app=live&stream=openrd&type=play
```

车端和服务端状态里仍保留 ZLMediaKit 直连地址 `http://43.139.25.165:8888/index/api/webrtc?app=live&stream=openrd&type=play`；前端在同主机 `:8080` 部署页运行时会自动改写为上面的同源代理，避免浏览器跨端口 CORS。

HTTP-FLV fallback 地址仍保留用于桌面排障：

```text
http://43.139.25.165:8888/live/openrd.live.flv
```

调试区字段：

- `ZLM Host`：ZLMediaKit 服务器地址，默认 `43.139.25.165`；
- `Path`：流路径，默认 `live/openrd`；
- `Cloud API`：公网视频控制服务地址，默认 `http://43.139.25.165:8790`。

前端会优先使用 control service 返回的 `whep_url`；如果云端状态暂未返回 WHEP 地址，则根据 `ZLM Host` 和 `Path` 自动拼接 `/index/api/webrtc?app=...&stream=...&type=play`。

视频面板不会在页面打开时自动拉起推流。点击“启动视频推流”后，前端请求云端 control service，再由 RK3588 上的 `openrd-video-agent` 启动 `openrd-video-native.service`。播放期间前端每 30 秒续约一次；点击“停止视频推流”或续约超时后，车端会停止推流，避免持续消耗公网流量。

## 控制链路

默认控制地址：

```text
http://43.139.25.165:8080/openrd-control
```

连接后，前端会：

- 请求 `GET /api/vehicles/openrd-001/drive/status` 获取车辆/agent/ESP32 状态；
- 约 20Hz 发送当前驾驶状态；
- 急停/停止立即插队发送；
- 页面失焦、暂停、关闭时主动停车；
- 连接后读取电池电压，并按 12V/3S 电池估算电量。

直连 ESP32/OpenRD-Driver 的 HTTP 调试能力仍保留，便于局域网实车排查。

## 手柄输入

当前 Web 端通过浏览器 Gamepad API 轮询手柄状态，并映射到本地驾驶状态：

- 左摇杆 X：方向；
- 左摇杆 Y：油门/倒车；
- LT/RT：倒车/油门；
- D-pad：数字方向输入；
- A/B：停止。

手柄面板会显示连接状态、设备名和当前按下按钮。方向/油门显示的是映射后的驾驶值，发送时会按速度上限换算成底盘控制命令。

## 注意事项

- 桌面端和手机端共享同一套控制链路，但 UI 是独立体验。
- 视频链路和控制链路底层分开，前端产品体验上统一为一个远程驾驶 session。
- 当前公网入口仍是测试入口，正式控车前应补访问控制。
- 如果浏览器显示旧 UI，优先使用带版本参数的 URL 或清理站点缓存。
