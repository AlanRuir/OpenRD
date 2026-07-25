# 13 云端前端部署方案

本文档记录 OpenRD Flutter Web 控制台部署到云服务器的方案。这里部署的是 Flutter Web 构建后的静态文件，不是在云端运行 `flutter run`，也不是新增 Flutter 后端服务。

## 目标

- 手机和桌面浏览器可以通过公网地址打开 OpenRD 控制台；
- 前端静态资源由腾讯云服务器托管；
- 前端 API 请求复用现有 `openrd-control-service`；
- 视频播放复用现有 ZLMediaKit WHEP/WebRTC，HTTP-FLV 仅作为 fallback；
- 为手机端 PWA 控制和后续 HTTPS/访问控制打基础；
- 避免公网裸露控车入口，正式使用前补充访问控制。

## 非目标

- 不在云端长期运行 `flutter run -d web-server`；
- 不新增 Flutter 后端进程；
- 不改变 RK3588、ESP32、control service、ZLMediaKit 的核心链路；
- 不把 SSH 密钥或 systemd 能力放进前端。

## 当前部署形态

```text
浏览器
  -> http://43.139.25.165:8080/openrd/
  -> Caddy 静态目录 /var/www/openrd
  -> Flutter Web 静态文件

浏览器
  -> http://43.139.25.165:8080/openrd-control/
  -> Caddy 反代 127.0.0.1:8790
  -> openrd-control-service

浏览器
  -> http://43.139.25.165:8080/index/api/webrtc?app=live&stream=openrd&type=play
  -> Caddy same-origin proxy
  -> 127.0.0.1:8888 ZLMediaKit WHEP/WebRTC
```

当前 Caddy 8080 路由：

```text
/openrd/          -> /var/www/openrd 静态 Flutter Web
/openrd-mobile/   -> /var/www/openrd-mobile 静态 Flutter Web 手机入口
/openrd-control/  -> 127.0.0.1:8790 openrd-control-service
/index/api/webrtc -> 127.0.0.1:8888 ZLMediaKit WebRTC API
其他路径           -> 既有默认反代
```

## 构建方式

云端发布必须使用 release build，并显式关闭 Flutter Web CDN 资源：

```powershell
cd D:\Projects\OpenRD\frontend\openrd_frontend
flutter build web --release --base-href /openrd/ --no-web-resources-cdn
```

`--no-web-resources-cdn` 是当前必需项。原因是国内网络环境下浏览器访问 `gstatic` 不稳定，CanvasKit 或 Roboto 字体加载失败时会出现黑屏、无文字或首屏卡住。

构建产物应包含：

- `build/web/main.dart.js`；
- `build/web/flutter_bootstrap.js`；
- `build/web/canvaskit/`；
- `build/web/assets/assets/fonts/NotoSansSC.ttf`；
- `build/web/assets/FontManifest.json`。

`frontend/openrd_frontend/web/index.html` 内的 `window.openrdBuild` 和 `flutter_bootstrap.js?v=...` 用作缓存标识。发布明显 UI 变化时应更新该值。

## 发布步骤

本机打包：

```powershell
cd D:\Projects\OpenRD\frontend\openrd_frontend
if (Test-Path -LiteralPath build\openrd-web.tar.gz) { Remove-Item -LiteralPath build\openrd-web.tar.gz }
tar -czf build\openrd-web.tar.gz -C build\web .
```

上传：

```powershell
scp -i C:\Users\Alan\.ssh\openrd_tencent_ed25519 `
  -o BatchMode=yes `
  build\openrd-web.tar.gz `
  ubuntu@43.139.25.165:/tmp/openrd-web.tar.gz
```

远端替换静态目录：

```powershell
ssh -i C:\Users\Alan\.ssh\openrd_tencent_ed25519 -o BatchMode=yes ubuntu@43.139.25.165 `
  "set -e; sudo mkdir -p /var/www/openrd; sudo rm -rf /var/www/openrd/*; sudo tar -xzf /tmp/openrd-web.tar.gz -C /var/www/openrd; sudo chown -R www-data:www-data /var/www/openrd; sudo systemctl reload caddy"
```

## 验证清单

发布后至少验证：

```powershell
curl.exe -I --max-time 10 http://43.139.25.165:8080/openrd/
curl.exe -I --max-time 10 http://43.139.25.165:8080/openrd/main.dart.js
curl.exe -I --max-time 10 http://43.139.25.165:8080/openrd/canvaskit/canvaskit.js
curl.exe -I --max-time 10 http://43.139.25.165:8080/openrd/assets/assets/fonts/NotoSansSC.ttf
curl.exe -I --max-time 10 http://43.139.25.165:8080/openrd-control/health
```

浏览器端验证：

- 桌面端可打开 `/openrd/`；
- 页面显示暗色远程驾驶舱，而不是旧表单式控制台；
- 顶部状态条、中心视频主画面、右侧控制轨正常显示；
- 控制连接按钮可点击；
- 急停按钮始终可见；
- DevTools Network 不应请求 `gstatic`；
- Console 不应出现 CanvasKit 或字体加载失败。

## 2026-07-05 测试部署记录

已完成第一版云端静态部署验证：

- 本地执行 `flutter build web --release --base-href /openrd/`；
- 将 `frontend/openrd_frontend/build/web/` 打包并部署到云端 `/var/www/openrd`；
- Caddy 测试入口为 `http://43.139.25.165:8080/openrd/`；
- `/openrd-control/` 反代到 `openrd-control-service`；
- Caddy reload 后保持 `active`。

## 2026-07-13 桌面驾驶舱部署记录

已完成桌面端产品化 UI 部署：

- 桌面端由旧的“表单 + 调试面板”改为暗色远程驾驶舱；
- 视频面板成为主画面，右侧为驾驶控制轨；
- 调试配置和事件日志收进“系统检查器”；
- 急停按钮在顶部和控制轨均保留；
- `web/index.html` cache 标识更新为 `desktop-cockpit-20260713-apple`；
- Flutter Web release 构建改为 `--no-web-resources-cdn`；
- 静态包内置本地 CanvasKit 和 Noto Sans SC 字体；
- 已验证远端 `/openrd/`、`main.dart.js`、`canvaskit/canvaskit.js`、本地字体文件均返回 `200`；
- Playwright/Edge 抓图确认桌面端 UI 正常显示，Network 不再依赖 `gstatic`。

## 风险与后续

- 当前公网入口仍未作为正式权限边界，应在正式控车前增加 Basic Auth、Token 或更完整的用户认证；
- 手机端和桌面端默认使用 WHEP/WebRTC；如 WHEP 不可用，再使用 HTTP-FLV 桌面 fallback；
- 如果前端静态部署失败，回滚 `/var/www/openrd` 静态目录即可；
- 如果 Caddy 反代影响 control service 或 ZLMediaKit，优先撤销对应路径反代，恢复原端口访问。
