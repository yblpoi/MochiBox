# CDP 注入链路 · 可行性验证记录

日期：2026-10-20 · 执行者：主理人（齐活林）
目的：在写第一行产品代码前，先证明「macOS 上通过 CDP 向 Chromium/NW.js 游戏注入 JS」这条唯一可行通道确实成立。

## 环境
- macOS (darwin), arm64
- 浏览器：Playwright 缓存中的 `Google Chrome for Testing 156.0.8078.4`
  路径 `~/Library/Caches/ms-playwright/chromium-1248/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`
- 客户端：Node 22.22.2 + `ws@8`

## 验证步骤与结果

1. **启动带调试端口的浏览器**（等价于给 NW.js 游戏追加同参数）
   ```
   ".../Google Chrome for Testing" --headless=new --no-sandbox --disable-gpu \
       --remote-debugging-port=9338 --user-data-dir=/tmp/cdpprofile7 /tmp/probe.html
   ```
   日志出现：`DevTools listening on ws://127.0.0.1:9338/devtools/browser/<uuid>` ✅

2. **HTTP 发现端点**
   `GET http://127.0.0.1:9338/json/list` → 200，返回含 `type:"page"` 与 `webSocketDebuggerUrl` 的数组 ✅

3. **浏览器级 WebSocket + 目标绑定**
   `Target.getTargets` → 返回 `page:file:///private/tmp/probe.html` ✅
   `Target.attachToTarget {targetId, flatten:true}` → 返回 `sessionId` ✅

4. **代码注入（关键一步）**
   ```json
   {"id":3,"method":"Runtime.evaluate",
    "params":{"expression":"document.title+\"|\"+location.href","returnByValue":true},
    "sessionId":"7F71831959FC2A3EB515C5CD4FA7278B"}
   ```
   响应：`{"result":{"type":"string","value":"mvstub|file:///private/tmp/probe.html"}}` ✅

## 两个必须写进设计的坑

1. **直连 page 级 WebSocket（`/devtools/page/<id>`）在本机只握手成功、`Runtime.evaluate` 永无响应**；
   而 **browser 级端点 + `Target.attachToTarget(flatten)` + `sessionId`** 全链路正常。
   → 适配器必须实现后者（这也正是 Playwright/Puppeteer 的做法）。
2. **渲染进程会被本机沙箱杀掉**：不加 `--no-sandbox` 时，`Target.getTargets` 能通，但
   `Runtime.evaluate` 超时（渲染进程未起来，日志见 `sandbox initialization failed: Operation not permitted`）。
   → 自动化测试必须带 `--no-sandbox --disable-gpu`；**面向真实游戏时不得默认加 `--no-sandbox`**，
   仅作为「启动失败时的可选项」暴露在设置里。

## 结论

- 通道成立，`--remote-debugging-port` + CDP 是 macOS 上对 NW.js 系引擎唯一无需签名豁免的注入面。
- 使用方（Swift）需要：HTTP 发现 → WebSocket 握手 → 请求/响应按 `id` 关联 → `sessionId` 透传。
- 该验证只用了一个空白页，**尚未验证 MV/MZ 真实钩子**（需真实游戏或 MV 运行时替身）。

## Swift 侧客户端选型验证（决定工程能否用 `URLSessionWebSocketTask`）

用 Swift 写了一个 30 行的探针（`/tmp/swws/main.swift`），只依赖 Foundation：

```swift
let verData = try Data(contentsOf: URL(string: "http://127.0.0.1:9341/json/version")!)
let wsURL = URL(string: ver["webSocketDebuggerUrl"] as! String)!
let task = URLSession.shared.webSocketTask(with: wsURL)
task.resume()
task.send(.string(#"{"id":1,"method":"Target.getTargets"}"#)) { ... }
task.receive { ... }
```

实测输出：

```
compiled=0
endpoint ready after 1s
browserWS=ws://127.0.0.1:9341/devtools/browser/a9d7b608-...
SENT
RECV {"id":1,"result":{"targetInfos":[{"targetId":"...","type":"page","url":"file:///private/tmp/probe.html",...
OK
exit=0
```

→ **零第三方依赖成立**：`URLSessionWebSocketTask` 能直连 Chromium DevTools 端点并收发 JSON-RPC，
无需引入 `ws`/Starscream。工程不需要自研 WebSocket 帧编解码。

其他已实测可用的系统能力（都写成 10 行探针验证过）：

| 能力 | 探针结果 |
|---|---|
| `import SQLite3` + `sqlite3_open` | `sqlite-open: true`，`sqlite-ver: 3.54.0` |
| `NWListener(using: .tcp, on: 0)` | `nwlistener: true` |
| SwiftUI `@main` + `swiftc -parse-as-library` | 编译通过，产出 arm64 Mach-O |
| `NSApplication` + `NSWindow` 显示 | `window-created true`，`NSScreen.screens.count = 1`（有窗口服务器，UI 可真测） |

