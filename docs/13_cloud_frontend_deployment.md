# 13 云端前端部署方案

本文档记录 OpenRD Flutter Web 控制台部署到云服务器的方案。这里部署的是 Flutter Web 构建后的静态文件，不是在云端运行 `flutter run`，也不是新增一个 Flutter 后端服务。

## 目标

- 手机和桌面浏览器可以通过公网地址打开 OpenRD 控制台；
- 前端静态资源由腾讯云服务器托管；
- 前端 API 请求复用现有 `openrd-control-service`；
- 视频播放复用现有 ZLMediaKit HTTP-FLV；
- 为后续手机端 PWA 控制打基础；
- 上线前加入访问控制，避免公网裸露控车入口。

## 非目标

- 不在云端长期运行 `flutter run -d web-server`；
- 不新增 Flutter 后端进程；
- 不改变现有 RK3588、ESP32、control service、ZLMediaKit 的核心链路；
- 不在第一步引入复杂用户系统，先用轻量认证保护入口。

## 当前开发模式

开发时前端运行在本机：

```text
Windows 开发机
  -> flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5173
  -> 浏览器访问 http://127.0.0.1:5173
  -> 请求 http://43.139.25.165:8790
  -> 拉流 http://43.139.25.165:8888/live/openrd.live.flv
```

这种方式适合开发调试、热重载和快速验证 UI，不适合作为手机端长期访问入口。

## 目标部署模式

推荐正式形态：

```text
手机浏览器 / 桌面浏览器
  -> HTTPS 公网入口
  -> 云端静态 Flutter Web 控制台
  -> /api/* 反代到 openrd-control-service:8790
  -> /live/* 反代到 ZLMediaKit:8888
  -> RK3588 / ESP32
```

如果暂时没有域名，可以先用公网 IP 和 HTTP 端口验证：

```text
http://43.139.25.165:<frontend-port>/
```

但手机端控车进入常用阶段前，建议切到域名 + HTTPS + 访问控制。

## 推荐 URL 形态

有域名时建议统一同源：

```text
https://openrd.example.com/
https://openrd.example.com/api/vehicles/openrd-001/drive/status
https://openrd.example.com/api/vehicles/openrd-001/video/status
https://openrd.example.com/live/openrd.live.flv
```

同源部署的好处：

- 减少浏览器 CORS 处理；
- 手机浏览器和 PWA 行为更稳定；
- HTTPS、认证、日志可以集中在 Caddy/Nginx；
- 前端配置可以从绝对公网 IP 逐步改成相对路径。

## 构建产物

在本地或云端执行：

```bash
cd frontend/openrd_frontend
flutter build web --release
```

构建产物位于：

```text
frontend/openrd_frontend/build/web/
```

部署到云端静态目录，例如：

```text
/var/www/openrd
```

云端不需要运行 Flutter SDK 或 Dart VM 来提供页面；Web 服务器只需要托管 `build/web` 里的静态文件。

## Caddy/Nginx 路由建议

如果使用 Caddy，建议逻辑如下：

```text
openrd.example.com {
  root * /var/www/openrd
  file_server

  handle_path /api/* {
    reverse_proxy 127.0.0.1:8790
  }

  handle_path /live/* {
    reverse_proxy 127.0.0.1:8888
  }
}
```

实际落地时需要结合当前服务器已有 Caddy/ZLMediaKit 配置，避免覆盖现有视频中继端口。

## 访问控制

手机端控车不应公网裸奔。上线前至少做一种保护：

- Caddy Basic Auth 保护整个前端入口；
- 或启用 `OPENRD_CONTROL_VIEWER_TOKEN`，前端请求 API 时带 token；
- 或两者都启用：页面入口 Basic Auth，API 再带 viewer token。

推荐最小安全形态：

```text
浏览器访问控制台
  -> 先过 Basic Auth
  -> 前端加载页面
  -> API 请求携带 viewer token
  -> control service 校验 token
```

不要把 token、密码、私钥写入仓库。部署时应放在云端环境文件或 Caddy 服务器配置中。

## 前端配置建议

短期可以继续使用现有默认公网地址：

```text
Cloud API: http://43.139.25.165:8790
ZLM Host: 43.139.25.165
Path: live/openrd
```

部署成同源后，建议逐步改成：

```text
Cloud API: /api
Video URL: /live/openrd.live.flv
```

这样手机端不需要关心云端内部端口，也更容易迁移域名和 HTTPS。

## 部署步骤

### 阶段 1：本地 release build 验证

- 执行 `flutter build web --release`；
- 用本地静态服务器打开 `build/web`；
- 确认桌面端现有控制台可加载；
- 确认云端 control service 和 ZLMediaKit 地址仍能正常访问。

### 阶段 2：云端静态目录

- 在云端创建 `/var/www/openrd`；
- 上传 `build/web` 内容；
- 配置 Caddy/Nginx 静态服务；
- 先只开放前端页面，不改 API 和视频反代。

### 阶段 3：同源反代

- 增加 `/api/* -> 127.0.0.1:8790`；
- 增加 `/live/* -> 127.0.0.1:8888`；
- 调整前端默认配置或提供部署环境配置；
- 验证视频状态、底盘状态、视频播放都正常。

### 阶段 4：访问控制

- 加 Caddy Basic Auth 或等价入口认证；
- 启用 control service viewer token；
- 验证未授权浏览器无法打开控制台或调用 API；
- 验证授权手机可以正常连接、控车、急停。

### 阶段 5：手机端/PWA

- 增加移动端驾驶模式；
- 增加 Web App Manifest；
- 验证手机浏览器“添加到主屏幕”；
- 验证横屏、失焦停、松手停、断连停。

## 验收标准

- 云端 URL 可以打开 Flutter Web 控制台；
- 页面刷新后仍能正确加载静态资源；
- `/api/vehicles/openrd-001/drive/status` 可通过前端读取；
- `/api/vehicles/openrd-001/video/status` 可通过前端读取；
- HTTP-FLV 视频可播放或显示明确状态；
- 未授权访问被拒绝；
- 授权后桌面端现有控制能力不退化；
- 手机浏览器可以打开页面并看到适配后的控制入口。

## 回滚策略

- 保留上一版 `/var/www/openrd` 目录备份；
- Caddy/Nginx 配置变更前先备份；
- 如果前端静态部署失败，回滚静态目录即可；
- 如果反代影响现有 control service 或 ZLMediaKit，先撤销 `/api/*`、`/live/*` 反代，恢复原端口访问。

## 当前建议

下一步先做 **阶段 1 + 阶段 2**：本地 release build 验证，并把静态控制台部署到云端一个受保护的测试入口。等手机端驾驶模式实现后，再切到同源 `/api` 和 `/live` 反代，并把它作为手机 PWA 的正式入口。
