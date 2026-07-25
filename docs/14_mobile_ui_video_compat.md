# 14 手机端驾驶 UI 与视频兼容方案

本文档记录 OpenRD 手机端控制界面的下一阶段方案。背景是：桌面端控制台已经可以通过云端入口连接底盘控制链路，但实测手机浏览器暴露出两个独立问题：

- iPhone 默认浏览器不支持此前的 HTTP-FLV 播放方案；
- 桌面端控制台压缩到手机屏幕后，触控摇杆很难稳定触发，页面自身滚动和触摸事件会干扰驾驶输入。

当前结论：手机端不应继续复用桌面控制台布局，而应单独做一个移动端驾驶界面；视频链路已从 HTTP-FLV 推进到默认 WHEP/WebRTC，HTTP-FLV 只保留为桌面排障 fallback。

## 目标

- 为手机浏览器提供独立的驾驶 UI，而不是压缩桌面端页面；
- 优先保证连接、松手停、急停、低速驾驶和状态可见；
- 兼容 iOS Safari、Android Chrome 等主流手机浏览器；
- 保留现有云端底盘控制链路，不改变 RK3588、ESP32 和 control service 的基础架构；
- 为后续 PWA、全屏驾驶和手机端视频预览打基础。

## 历史问题

### iOS 视频播放

此前桌面端主要使用云端 ZLMediaKit HTTP-FLV 地址：

```text
http://43.139.25.165:8888/live/openrd.live.flv
```

这个方案在桌面浏览器中可用，但 iOS Safari 不原生支持 FLV，也不支持依赖 Media Source Extensions 的典型 flv.js 播放路径。因此 iPhone 默认浏览器上不能把 HTTP-FLV 作为长期视频方案。

影响：

- 手机端打开页面后，控制链路可以连接，但视频区域可能无法播放；
- 用户容易误判为推流失败，实际上是浏览器播放协议不兼容；
- 即使 Android Chrome 可播放，也不能代表 iOS 兼容。

### 触控驾驶体验

当前桌面控制台在手机上存在明显触控问题：

- 页面整体是可滚动、可点击、可输入的复杂布局；
- 摇杆区域和页面滚动手势会互相抢触摸事件；
- 按钮、状态、视频和调试信息挤在同一屏，驾驶时误触风险高；
- 手机端缺少固定横屏、全屏、禁滚动、触摸捕获等驾驶模式处理；
- 急停和 stop 虽然存在，但不够像手机驾驶界面的第一优先级控件。

这说明手机端应该作为单独产品界面处理，而不是把桌面端做响应式缩放。

## 推荐方向

### 控制 UI

新增一个手机专用驾驶界面，例如 `MobileDriveView`。进入方式可以是：

- 根据屏幕宽度和触摸能力自动进入移动端布局；
- 或在桌面控制台增加“手机驾驶模式”入口；
- 云端部署时后续也可以单独提供 `/openrd/mobile/` 路由。

移动端驾驶模式应默认横屏使用：

```text
+------------------------------------------------------+
| 顶部状态：连接 / RK / ESP32 / 电量 / 控制延迟 / 速度档 |
+------------------------------+-----------------------+
|                              |  STOP                 |
|        左侧驾驶触控区          |                       |
|   steering / throttle        |  ESTOP                |
|                              |                       |
|                              |  低速 / 中速 / 高速    |
+------------------------------+-----------------------+
| 可折叠：视频小窗 / 事件日志 / 调试状态                 |
+------------------------------------------------------+
```

第一版建议：

- 默认低速档，速度上限 `200` 或 `300`；
- 左侧大触控区输出 `steering` 和 `throttle`；
- 右侧固定 `STOP` 和 `ESTOP`，始终可见；
- 页面不滚动，驾驶区使用固定尺寸和触摸捕获；
- 手指离开、触摸取消、页面失焦、切后台立即发送 stop；
- 视频先作为辅助小窗，不抢占急停和控制区域。

### 视频兼容

手机端视频建议分阶段处理：

1. **短期：明确降级显示**
   - iOS Safari 检测到 HTTP-FLV 不可播时，不显示“视频故障”，而显示“当前浏览器不支持 FLV，请使用兼容视频模式”；
   - 手机端控制 UI 不依赖视频可用才允许低速调试，但要明确提示风险；
   - 保留 Android/桌面 HTTP-FLV 能力。

2. **中期：增加 HLS 播放**
   - ZLMediaKit 可输出 HLS 时，给 iOS 使用 `.m3u8`；
   - 优点是 iOS Safari 原生支持；
   - 缺点是延迟通常高于 FLV/WebRTC，不适合作为最终低延迟驾驶视频；
   - 可作为“能看见画面”的兼容 fallback。

3. **长期：切到 WebRTC/WHEP**
   - 手机端驾驶视频最终应优先 WebRTC；
   - iOS/Android 浏览器都支持 WebRTC；
   - 延迟更适合远程驾驶；
   - 需要继续完善云端中继、ICE/TURN、鉴权和播放稳定性。

当前判断：HLS 适合作为 iOS 兼容 fallback，WebRTC 才是手机远程驾驶的目标视频链路。

## 技术设计

### 路由和入口

建议保留桌面控制台，同时新增手机入口：

```text
/openrd/          桌面/通用控制台
/openrd/mobile/   手机驾驶模式，后续可选
```

如果短期不拆路由，也可以在 Flutter 内通过屏幕和触摸能力切换：

```text
isMobileDrivePreferred =
  shortestSide < 600 || hasTouchInput
```

但进入驾驶模式应由用户显式确认，避免手机打开页面后直接进入可驾驶状态。

### 触摸输入

手机驾驶触控区建议：

- 使用 `Listener` 或等价底层指针事件，而不是依赖普通按钮点击；
- `PointerDown` 后捕获当前 pointer id；
- `PointerMove` 持续计算归一化坐标；
- `PointerUp`、`PointerCancel` 立即归零并发送 stop；
- 阻止驾驶区域内的页面滚动和选择行为；
- 控制命令仍按 10-20Hz 节流发送，不按触摸事件原始频率直接发送。

归一化建议：

```text
steering = clamp((x - centerX) / radius, -1.0, 1.0)
throttle = clamp((centerY - y) / radius, -1.0, 1.0)
```

可以后续加入死区和曲线：

```text
deadzone = 0.08
curve = sign(value) * value^2
```

这样低速微操更稳。

### 安全停

手机端必须实现以下前端保护：

- `pointerup` / `pointercancel` 发送 stop；
- `visibilitychange` 页面隐藏发送 stop；
- `pagehide` 发送 stop；
- `blur` 发送 stop；
- 控制链路状态变为 error/disconnected 时 UI 进入不可驾驶；
- 连续状态请求失败超过阈值时发送 stop；
- 切换速度档不发送运动命令，只改变后续上限；
- ESTOP 使用独立按钮和二次确认或长按策略，避免误触，但必须始终可达。

车端和 ESP32 的 TTL/watchdog 仍然是最后防线，手机端不要依赖它们作为唯一停车机制。

### 视频策略

前端可以根据浏览器能力选择播放方式：

```text
iOS Safari:
  优先 HLS / WebRTC
  不使用 HTTP-FLV

Android Chrome:
  短期可继续 HTTP-FLV
  后续优先 WebRTC

桌面 Chrome/Edge:
  保留 HTTP-FLV 调试
  后续同样切 WebRTC
```

UI 文案应区分：

- 推流未启动；
- 车端/云端视频链路故障；
- 当前浏览器不支持该播放协议；
- 视频延迟过高，不建议高速驾驶。

## 分阶段计划

### 阶段 1：手机驾驶 UI 骨架

- 新增移动端驾驶视图；
- 横屏优先，禁用页面滚动；
- 顶部状态栏显示连接、ESP32、电量、控制延迟；
- 左侧触控驾驶区；
- 右侧 STOP / ESTOP / 速度档；
- 复用现有云端底盘控制 endpoint。

### 阶段 2：触控安全闭环

- 实现 pointer 捕获、归一化、死区；
- 松手停、取消停、失焦停、切后台停；
- 控制命令 10-20Hz 发送；
- 默认低速档；
- 实车低速验证前进、后退、转向、停止。

### 阶段 3：视频兼容 fallback

- 检测 iOS Safari 并隐藏/禁用 FLV 播放入口；
- 增加明确的“不支持 FLV”状态；
- 评估 ZLMediaKit HLS 输出并接入 iOS fallback；
- 记录 HLS 首帧时间和端到端延迟。

### 阶段 4：WebRTC/WHEP 手机视频

- 接入云端 WebRTC/WHEP 播放；
- 验证 iOS/Android 浏览器兼容；
- 对比 HTTP-FLV、HLS、WebRTC 的首帧时间和端到端延迟；
- 手机驾驶模式默认使用 WebRTC。

### 阶段 5：PWA 与访问控制

- 增加 PWA manifest；
- 支持添加到主屏幕；
- 验证横屏启动和全屏体验；
- 上线 Basic Auth / viewer token；
- 防止公网未授权控车。

## 验收标准

第一版手机驾驶 UI 验收：

- 手机浏览器可以进入独立驾驶界面；
- 页面驾驶时不滚动，不影响摇杆触摸；
- 低速档下可稳定控制前进、后退、转向、停止；
- 松手、取消触摸、切后台、锁屏后车辆停车；
- STOP 和 ESTOP 始终可见且可触发；
- 控制链路状态、电量、延迟持续刷新；
- 不影响桌面端控制台。

视频兼容验收：

- iOS Safari 不再误显示为普通视频故障；
- iOS 可通过 HLS 或 WebRTC 看到视频；
- Android 和桌面端原有视频播放不退化；
- UI 能明确显示当前使用的视频协议；
- 视频不可用时不阻塞低速控制测试，但必须有明显提示。

## 历史建议

当时建议先实现 **阶段 1 + 阶段 2**，也就是手机专用驾驶 UI 和触控安全闭环。视频方面先做浏览器能力识别和明确降级文案，暂时不急着把 HLS/WebRTC 一次性做完。

这样可以先解决“手机端不好控”的核心问题，同时避免把视频协议切换和触控 UI 两个风险点绑在同一次开发里。

## 2026-07-06 第一版实现记录

已在 Flutter Web 控制台内增加第一版手机端驾驶界面：

- 小屏或手机横屏时自动进入手机驾驶 HUD，桌面端原控制台布局保持不变；
- 底层为全屏视频区域；在 iOS FLV 暂不支持时先显示黑屏占位；
- 顶部半透明状态栏显示连接状态、视频状态、电池、速度上限和最近指令；
- 左下悬浮触控摇杆使用底层 pointer 事件，避免复用桌面端滚动页面里的摇杆；
- 右侧叠加 `STOP` 和 `ESTOP`，并提供 `200 / 300 / 500` 三档速度上限；
- 底部叠加方向、油门和控制 endpoint 读数；
- 触控区 `pointerup` / `pointercancel` 后立即停车；
- 页面进入 inactive / hidden / paused / detached 生命周期时自动停车；
- 控制链路继续复用云端底盘控制 endpoint，不新增车端通信链路。

2026-07-06 第二轮调整：

- 放弃第一版“面板式手机 UI”，改为类似游戏驾驶的横屏 HUD；
- 控件不再挤占画面主体，而是叠加在视频/黑屏背景之上；
- 虚拟摇杆改为半透明悬浮圆盘，降低遮挡；
- STOP/ESTOP 作为右侧高优先级 HUD 按钮保留；
- 当前黑屏占位只是视频兼容 fallback，后续接入 HLS/WebRTC 后应替换为真实画面。

2026-07-12 PWA 沉浸模式调整：

- Web manifest 改为 `display: fullscreen`，并增加 `display_override: ["fullscreen", "standalone"]`；
- Web manifest orientation 改为 `landscape`，让添加到主屏幕后优先横屏启动；
- `index.html` 增加 iOS Web App meta、`viewport-fit=cover`、禁缩放和黑色主题；
- 手机 HUD 顶部增加全屏按钮，Android Chrome/桌面浏览器可通过 Fullscreen API 请求沉浸模式；
- iOS Safari 普通网页仍不能强制默认全屏，推荐通过“添加到主屏幕”进入 PWA。

当前仍未解决：

- iOS Safari 的视频播放仍未接入 HLS/WebRTC fallback；
- 手机端还没有独立路由或 PWA manifest；
- ESTOP 当前与 STOP 一样发送停车，后续应接入真正的云端急停 API；
- 移动端 UI 需要实机手感测试后再调触控区尺寸、死区和速度档。

## 2026-07-14 WHEP 接入状态

视频兼容方案已推进到 WebRTC/WHEP 默认链路：

- RK3588 默认以 `whip` 模式向 ZLMediaKit WHIP endpoint 推流；
- Flutter Web 优先使用 control service 返回的 `whep_url` 创建 `RTCPeerConnection`；
- 手机 HUD 背景视频已复用同一个 WHEP 播放器，黑屏只作为未启动或不可用 fallback；
- 视频 iframe 已禁用 pointer events，避免全屏或横屏时拦截“连接”、STOP、ESTOP 和摇杆触控；
- HTTP-FLV 保留为桌面调试 fallback，不再作为 iOS/手机端目标方案。

仍需实测：

- iOS Safari / PWA 下 WHEP SDP 交换、自动播放和横屏 HUD 触控；
- Android Chrome 下 WHEP 首帧时间和稳定性；
- 跨网 ICE 是否需要 TURN。
