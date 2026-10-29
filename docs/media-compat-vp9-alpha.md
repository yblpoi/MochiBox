# 媒体兼容：VP9-alpha 黑块与循环视频停帧

> 状态：当前有效。注入层现行实现为 `f16e5db`（到达 EOS 前主动回绕）与 `a73dc99`（2D canvas 桥接）；
> 转码层与静态服务接入见 §六，三步判定链见 `35afc6c`。
> 本文所有"实测"都带具体数字，采集方法见 §十一。
> 数据基线：注入层数字绑 `Resources/agent_mvmz.js` sha256 `771bcf6089ed1755…`（随 canvas 桥接提交更新）；
> 转码层数字来自本轮对素材库全量 1208 个 `.mpon/.webm` 的扫描，绑 ffmpeg 3,212,040 字节这一版。

RPG Maker MZ 的两类素材在 WKWebView 上各有一个致命缺陷：**带 alpha 的 VP9 视频丢透明**
（立绘变成大黑块）和 **`<video loop>` 第二次到达 EOS 后永久停帧**（待机动画卡死）。
两者都不在游戏侧，也不在翻译链路，属于播放器能力缺口。本文记录根因、排除过的替代方案、
现行修法与实测数据，避免后续再走一遍弯路。

## 一、症状

| 现象 | 现场值 | 触发条件 |
|------|--------|----------|
| 立绘大面积纯黑 | 1280×1280 的 `.mpon/.webm` 在 720p 画面上呈现为 640×640 的纯黑块，人物只剩外轮廓 | 素材带 alpha 平面（Matroska BlockAdditions） |
| 循环动画停帧 | 第 1 圈正常，第 2 圈到达 EOS 后画面定格；`currentTime` 停在 `duration`，`paused=false`、`readyState=4`、`error=null` | 用 `<video loop>` 做待机动画（如 `某影片插件`） |

第二条的隐蔽之处：DOM 状态全部"正常"，任何基于 `paused`/`error` 的看门狗都不会报警。
挂 DOM、`display:none`、完全游离三种情况表现一致，所以"把元素塞进文档"绕不过去。

## 二、根因一（解码层）：WebKit 在解析层丢掉 VP9 alpha

### 2.1 机制

带 alpha 的 VP9 WebM 把透明信息放在 Matroska 的 **BlockAdditional** 里：
`BlockAddID == 1` 是 alpha 平面，`BlockAddID == 0x04` 是 HDR 元数据。
WebKit 的 Cocoa WebM 解析器（`SourceBufferParserWebM.cpp` 的
`consumeAdditionalBlockData`）**只处理 `0x04`，其余 ID 直接跳过**，alpha 平面在
进入解码器之前就被扔掉了。对应 WebKit bug 275908，上游修复 PR 至今未合入。

这不是解码器"解不出来"，而是解析器**没把第二平面交给解码器**：同一份文件，Chromium 的
VP9 路径四角透明，WKWebView 四角不透明，差异在解析层而不是渲染层。

### 2.2 实测证据

| 取样 | WKWebView（内置内核） | Chromium 内核 |
|------|----------------------|---------------|
| 画面四角 RGBA | `[0,0,0,255]`（不透明黑） | `[0,0,0,0]`（全透明） |
| 整帧 alpha 最小值 | `255` | `0` |
| `alphaZeroFrac`（alpha==0 像素占比） | `0.000` | 与素材一致 |
| 64×64 网格里的半透明像素 | 0 | 约 7% 落在 `0<a<255` |

### 2.3 为什么不在 JS 层补救（都试过，别再来一遍）

| 方案 | 结果 |
|------|------|
| `a = max(r,g,b)` 反预乘 + 抠黑 | 把 **87.25%** 的人物像素算成 `alpha<255`：整体发白、暗部被放大成发光蓝斑，比黑块更难接受 |
| WebCodecs `VideoDecoder` | 没有 alpha 输入/输出通道，`VideoFrame` 拿不到第二平面 |
| `ImageDecoder` | 不支持视频容器（只吃图片） |
| CSS `mask` / `-webkit-mask` | 不能引用 `<video>` 作为遮罩源 |

结论：**解码层只能在"能解出 alpha 的解码器"上重编码**，即旁路一次转码，而不是在页面里补。但这只修好了「解码层」——**光转码黑底不会消失**：
游戏把 video 直接当 WebGL 纹理上传时 WebKit 还会再抹一次 alpha（见 §三），
上传层必须另垫一层 2D canvas（见 §5.4）。

## 三、判据纠正：2D canvas 上 alpha 正确 ≠ 游戏里正确

上一版拿「`drawImage` 到 2D canvas 后四角 alpha=0」当作「黑底已修」的判据。**这条判据是错的。**
游戏根本不走 2D canvas：PIXI 把 `<video>` 直接当 WebGL 纹理上传，而 WebKit 在这一步会把整帧的
alpha 抹平。同一帧、同一时刻、三路对照（64×64 网格 = 4096 个采样点的 alpha 直方图）：

| 路径 | a0 / 中间值 / a255 | 四角 RGBA | 说明 |
|------|-------------------|-----------|------|
| `drawImage(video)` → 2D canvas | 2693 / 728 / 675 | `[0,0,0,0]` | 解码层的 alpha 是好的 |
| 该 canvas → `texImage2D` | 2693 / 728 / 675 | `[0,0,0,0]`（与 2D 一致） | canvas 当源不丢 alpha |
| `video` 直接 → `texImage2D` | 0 / 0 / 4096 | `[0,0,0,255]` | **alpha 全被抹成 255** |

两条结论：

1. **WebKit 把 video 帧直接上传成 WebGL 纹理时会抹掉 alpha**：透明像素一个不剩，4096 个采样点
   全变成 255。这与 §二 的解析层缺陷是两个独立的坏点，叠在同一份素材上。
2. **转码只解决「解码层」，不解决「上传层」**。转出来的 HEVC-alpha 本身 alpha 完好
   （alpha 平面 min=0、transparent 2778 / partial 614），但游戏照旧把 video 递给 `texImage2D`，
   黑底一模一样地回来。要真正透明，必须在两者之间垫一层 2D canvas（见 §5.4）。

### 3.1 三条测量纪律（不遵守会读出假数据）

- **游戏的 WebGL 上下文是 `alpha:false`**，对游戏画布 `readPixels` 的 A 通道**恒为 255**，
  拿它判断「是否透明」永远得到「不透明」。只能看**合成结果**：在立绘下面垫一块不透明白色 quad，
  读该点是否变白（变白 = 透出了背景，仍是黑 = 没透）。
- **引擎的 `Sprite.updateVisibility` 每帧会把 `visible` 重置回 `true`**，用 `visible=false`
  做背景对照会被引擎自己改回来；对照必须用 `renderable=false`。
- **采样前必须确认立绘 bounds 完整覆盖采样矩形**，否则读的是背景而不是立绘，整组读数无效。

## 四、根因二：`<video loop>` 第二次 EOS 后停帧

WKWebView 里循环视频的 `ended` 事件**只在第 1 圈派发**（一次 4 圈实测：`wraps=4`、
`ended=1`）。第 2 圈起元素停在 EOS，但：

- `paused === false`（不是暂停，是"卡在末帧"）；
- `readyState === 4`、`error === null`（没有解码错误）；
- `requestVideoFrameCallback` 不再出帧（帧计数定格）。

于是"靠 `ended` 复位"的写法只能管第 1 圈。只靠 500ms 定时扫描也能救活，但救得晚：
真机验收里每个回绕点有 **0.7–1.0s 定格**（3s 的待机循环上等于原缺陷）。三个叠加原因：

1. `ended` 后续圈不派发，没有即时信号；
2. 500ms 扫描粒度太粗，EOS 后最多干等一轮，还要再等"连续两轮不动"的判据；
3. **首次写 `currentTime = 0` 常不生效**，要等下一轮扫描再补一次，等于再翻一倍。

## 五、修复一：注入层（Agent 侧）

补丁位置：`Resources/agent_mvmz.js` 的 `patchMediaCompat()`，在 `emit('hello')` 之后安装，
不进 `installedHooks`（内核用例硬断言恰好四条 hook）。

### 5.1 机制纠正：期望循环的视频全程不得派发 `ended`

上一版为了拿到「一圈结束」的信号，拦截 `loop` 的 setter 并把原生 `loop` 恒写 `false`，
让内核在每圈 EOS 派发 `ended`。真机上这是**灾难**：

- 3.1s 处派发 `ended`（素材长 3.000s）；
- 插件 `某影片插件` 在 `autoEraseOnEnd=true` 时的逻辑是
  `if (this.bitmap.isEnded() && param.autoEraseOnEnd) this.eraseVideo();`
- `eraseVideo()` 把整个立绘擦掉 —— **立绘整体消失**，比黑块更糟。

现行做法：**完全不碰 `loop`**（插件每帧都会把它写回 `true`，`isPlayingWait()` 与
`autoEraseOnEnd` 都依赖它），保留原生循环，在 `currentTime >= duration - 0.08`
（30fps 下约 2–3 帧）时主动把 `currentTime` 写回 0 并补一次 `play()`，元素**永不到达 EOS**。
500ms 扫描只在「停在 EOS 附近且 `currentTime` 连续两轮不动」时兜底，介入方式同样是
`currentTime = 0`（不再升级到 `load()` —— 那会毁掉纹理）。`ended` 监听**只做观测**
（`probe().mediaEndedSeen`），不在回调里复位。

真机复现与验证（`mac01_wait_nomalA`，200ms 采样 × 20s）：

| | 上一版（原生 loop 恒 false） | 现行（保留 loop + 提前回绕） |
|---|---|---|
| `ended` 次数 | 1（t≈3.1s） | **0** |
| 立绘状态 | `bitmap=null`、`erased=1`，整体消失 | 全程存在 |
| 循环 | 被擦掉，只有 1 圈 | **6–7 个完整循环**（3.07 / 6.14 / 9.24 / 12.31 / 15.19 / 18.29s） |
| 回绕前最大 `currentTime` | 3.000（= EOS） | 2.929 < 3.000 |
| 最大停滞 | — | **82ms**（相邻采样「墙钟 − 播放进度」之差） |

**不变量（改这段之前先读）：期望循环的视频全程不得派发 `ended`。**

### 5.2 结构

- **只读 `loop`，不写**：`loop` 是插件每帧都要写的属性，补丁只在读的时候跟随；
  拦截 setter 会把 `isPlayingWait()` / `autoEraseOnEnd` 的判断改坏（见 §5.1）。
- **登记元素**：hook `play()` 与 `load()`，同时覆盖「先 play 后设 loop」「从不设 loop 的一次性
  视频」与插件的 `createElement('video') → load() → autoplay=true`（这条路径没有 JS 侧 `play()`）。
- **rVFC 逐帧检查（主路径）**：对登记元素订阅 `requestVideoFrameCallback`，每帧读
  `duration/currentTime`，一进 `duration - 0.08` 就回绕，精度 ±1 帧。
- **回绕守卫**：同一元素两次回绕至少隔 60ms（约 2 帧）。seek 写入是异步的，间隔太短会把计数刷爆；
  60ms 又足够短——万一某次 seek 没写进去，下一帧还能在 EOS 之前补一次。
- **500ms 扫描兜底**：rVFC 不可用、元素换源、帧回调意外断掉时走它；判据是「到 EOS 附近**且**
  `currentTime` 连续两轮不动」。正常回绕的元素回绕点在 `duration - 0.08`，比容差更早，
  永远走不到这条分支。
- **`uninstall()` 完全撤回**：逐元素撤 rVFC 订阅、清扫描定时器、摘 `ended` 监听、
  还原 `play`/`load` 钩子。

### 5.3 三条不变量（不得违反）

1. **期望循环的视频全程不得派发 `ended`**。这是插件 `autoEraseOnEnd` 的擦除触发条件；
   靠「派发 ended 再复位」的写法等于每圈擦一次立绘（见 §5.1）。
2. **`el.paused === true` 一律不碰**。游戏的待机动画用 `pause()/play()` 控制暂停态，
   暂停时 `currentTime` 当然不动 —— 那不是停滞。恢复交给 `play()` 钩子重新起帧。
3. **`loop === false` 的一次性视频必须让它自然 `ended`**。这类视频的 `ended` 是游戏逻辑的输入，
   不能被补丁吞掉：`loop` 一旦为假就撤订阅、清停滞状态，保持原生行为。

### 5.4 2D canvas 桥接（上传层修复）

判据纠正之后（§三）补的第三层修复，同样装在 `patchMediaCompat()` 里。

**探测：自证式，不看文件名。** `loadeddata` / `canplay` 之后把当前帧 `drawImage` 到 64×64
临时 canvas，`getImageData` 扫 A 通道，只要存在 `< 255` 的像素就判定需要桥接；结论按 video
缓存在 `WeakMap`（这一帧读不到就返回 `null`，等下一个事件，不缓存）。无 PIXI / 无 DOM 时
整体静默降级为 `off`，自测与沙箱都不受影响。

**桥接：视频帧先落到 canvas，再当纹理上传。** 建 canvas + `new PIXI.BaseTexture(canvas)`，
再把原 `PIXI.Texture.from(video)` 的 `baseTexture` 指向 canvas、`frame` 重设为
`(0, 0, videoWidth, videoHeight)`。插件把纹理存进 `Bitmap._baseTexture`、每帧只读它，
所以**已经贴到 Sprite 上的立绘不需要重贴**。逐帧在 rVFC 里
`clearRect → drawImage → baseTexture.update()`，每个视频帧只上传一次；无 rVFC 的内核退化成
rAF + `currentTime` 去重。

`clearRect` 不能省：`drawImage` 是 source-over，透明像素抹不掉上一帧的残留，漏一次就是鬼影。

**只对探测到 alpha 的视频生效。** `bg_light01`（VP9 yuv420p，无 alpha）实测不建桥：
`mediaBridged` 不变、纹理仍是 video 源、逐帧零开销。

**尺寸**：canvas 长边默认上限 **640**（`window.MOCHI_MEDIA_BRIDGE_MAX` 覆盖，NW.js 这类带
`process` 的宿主再读 `process.env.MOCHI_MEDIA_BRIDGE_MAX`；下限 64，防止糊成马赛克）。
逻辑尺寸靠 `resolution = canvasW / videoW` 保持 `videoWidth/videoHeight`，MZ 的
`Sprite._refresh` 才不会把立绘裁小。

**hook 与卸载**：hook `PIXI.Texture.from`，参数与返回值语义原样透传（options/strict 交给原实现，
纹理缓存与 scaleMode 不受影响）；PIXI 未就绪时 500ms 轮询、最多 60s，始终没有就记
`unsupported` 并静默跳过。`uninstall()` 逐个 cancel rVFC、清 `WeakMap` 与活跃表、
还原 `PIXI.Texture.from`；之后 `probe().mediaBridge=off`、`mediaBridged=0`、帧数停止增长。

### 5.5 桥接开销（1280×1280 源，同机 A/B）

| 指标 | 桥接关 | 桥接开 |
|------|--------|--------|
| rAF 帧间隔 p50 | 17ms | 17ms |
| p95 | 18ms | 22ms |
| max | 18ms | 23ms |
| ≥33ms 的掉帧 | 0 | **0** |

- 单次 `clearRect + drawImage`：640×640 p50 **3.9–4.3ms**、1280×1280 p50 **4.2ms**，
  都在 33.3ms 帧预算的 13% 以内。
- **640 与 1280 在这一档测不出差异**（都是满帧、无掉帧）。上限留在 640 是为了带宽与显存
  （1280 要多传 4 倍像素），不是因为 1280 会卡。

### 5.6 实测

**EOS 停帧本身**（50ms 采样，每素材 ≥4 圈，EOS 滞留 = `currentTime` 连续落在
`[duration-0.02, duration]` 的采样数 × 50ms）：

| 素材 | 修复前 | 修复后 |
|------|--------|--------|
| `titleback.webm` 3.0135s | `[50, 626, 997, 993]`，最大 **997ms**，中位 **809.5ms** | `[50, 50, 50]`，最大 **50ms**，中位 **50ms** |
| `bg_smoke02.mpon` 10.033s | `[50, 692, 582, 636]`，最大 **692ms**，中位 **609ms** | `[50, 50]`，最大 **50ms**，中位 **50ms** |

- 50ms 是本方法的采样下限。用 16ms 采样复核 `titleback.webm`：EOS 区间跨度 15–43ms，
  `currentTime` 正好等于 `duration` 只占 1 个采样点，即**定格 ≤1 帧**。
- 两次真机 run 的 `mediaLoopFails` 都是 `0`。上一版把复位点提前到 EOS 边界后，第一次 seek
  就生效、不必升级到 `load()`；现行实现保留原生 loop，干脆不再调用 `load()`，该计数恒为 0。
- 上表「修复后」是 EOS 滞留口径。现行实现保留原生 loop 并把回绕点再提前到 `duration - 0.08`，
  20s 观测 6–7 圈、`ended=0`、最大停滞 82ms（见 §5.1），立绘全程存在。
- 反例：`pause()` 后静置 3s，`currentTime` 一字不动（0.751330225 → 0.751330225）；
  `loop` 为 `false` 的 3s 视频在 4.5s 后 `t=duration`、`ended=true`、`ended_events=1`
  （没有被回绕），`mediaRestarts` 保持 0（无残留定时器）；`uninstall()` 后 `mediaPatch=off`、
  `loop` 属性回读 `true`、`play` 钩子已摘。
- HEVC-alpha 的 `.mov`（1280×1280 / 3.000s）走同一补丁：15s 内 5 圈、`mediaRestarts=5`、
  `mediaLoopFails=0`，readyState 全程 4、无 error。上一版（原生 loop 恒 false）实测它的
  `ended` 每圈都派发（`ended=5`）；现行实现保留原生 loop，这几条素材没有单独复跑
  `endedSeen`，不据此外推。

## 六、修复二：转码层（静态服务按需）

### 6.1 自带的静态 ffmpeg

系统里没有能同时做"VP9 alpha 解码 + HEVC alpha 编码"的可执行文件：VideoToolbox 不向第三方
提供 VP9 解码器（`VTDecompressionSessionCreate` 返回 `-12906`），而 alpha 编码必须走
`hevc_videotoolbox`。所以自带一份静态精简 ffmpeg：

| 项 | 值 |
|----|----|
| 组成 | ffmpeg 9.0.2 + libvpx 1.15.0（仅 VP9 解码），arm64 单架构 |
| 体积 | 3,212,040 字节（约 3.2MB），stripped |
| 依赖 | `otool -L` 只有系统框架（VideoToolbox / CoreMedia / CoreVideo / CoreFoundation / CoreServices / libSystem） |
| 授权 | ffmpeg LGPL-2.1-or-later + libvpx BSD-3-Clause，许可文本随产物一起分发 |
| 构建 | `bash Scripts/build-ffmpeg.sh`（首次编译，之后增量跳过）；产物 `vendor/media/ffmpeg`，不入库 |
| 打包 | `Scripts/build.sh` 发现有 `vendor/media/ffmpeg` 就复制到 `Contents/Resources/media/`；没有则只打印一行提示，照常出包 |

### 6.2 判定链：标签 → 首帧 min → 0.8×duration 补帧

**范围只到 `.mpon`**。`.webm` 一律照原样服务，原因不是"懒得做"，而是做了会更糟：
WKWebView 的媒体层按 **URL 扩展名**选解复用器，不只看 `Content-Type`。把同一份
HEVC-alpha 字节按 `video/mp4` 挂在以 `.webm` 结尾的 URL 上，`<video>` 直接
`NotSupportedError`、`readyState=0`，标题画面整段空白，`--kernel-smoke` 由 PASS 变 FAIL；
同一份字节挂在 `.mpon` 或 `.mov` 上则正常播放。游戏里的 URL 由它自己拼，我们改不了。
本作 1415 个素材里只有 1 个 `.webm`（`titleback.webm`），且它的 alpha 平面全不透明，
**实际损失为零**。自测里有一条 `!isCandidate("movies/titleback.webm")` 防回归。

判定分三步，每一步失败都往"转"的方向退（**宁可多转一次，不可漏透明**）：

1. **标签**：`<ffmpeg> -hide_banner -nostdin -i <src>`（不给输出目标，非 0 退出属于正常），
   从 stderr 认 `alpha_mode: 1` 或 `yuva420p`。没有标签直接按原样服务，不做任何解码。
2. **首帧像素**：`-c:v libvpx-vp9 -i <src> -frames:v 1 -vf "alphaextract,scale=64:64"
   -f rawvideo -pix_fmt gray <scratch>`，取 4096 字节里的最小值；min<255 → 转。
3. **补一帧**：首帧 min==255 时，再按 `-ss 0.8×duration` 解一帧，仍是 255 才判定
   "纯不透明，不转"。任一步失败 / 超时 / 输出不是 4096 字节 → 退化为"标签为真就转"。

| 素材 | 判定过程 | 结果 |
|------|----------|------|
| `mac01_wait_nomalC` | `alpha_mode=1`，首帧 min=0 | 转码；四角 `[0,0,0,0]`、a0=790 / mid=73 / a255=161，响应 `video/mp4` 3,130,818 B |
| `bg_light01` | 无标签 | 不探测像素、不转码；原始 922,402 B，`media-cache` 不增长 |
| `ev08-A-01-01` | 有标签，首帧 min=255、`t≈0.8×duration` 仍 255 | **不转码**；原始 1,255,732 B，`media-cache` 不增长 |

跑完整库后 `media-cache` 只有 **1 个文件 / 3,130,818 B**，说明 248 个"假 alpha"确实被
判定阶段挡掉，没有付出转码与缓存成本。

> 取样网格说明：上表的 a0/mid/a255 按 **32×32** 网格统计。独立复跑改用 64×64 网格
> （4096 像素）得到 a0=3139 / amid=318 / a255=639，透明像素占比 76.6% 与 77.1% 一致；
> 四角同为 `[0,0,0,0]`，缓存产物同为 3,130,818 B 且响应 `video/mp4`。
> 两条反例的响应都是 `application/octet-stream`、字节数与源一致（922,402 / 1,255,732），
> `media-cache` 不增长。

为什么必须有第 3 步：全库有 **2** 个慢热素材（`ev07-B-02-05` / `ev07-B-03-03`），开头几帧
全不透明、到 `t≈0.8×duration` 才出现 alpha；只看首帧会把它们误判成"不用转"，画面重新变黑。
反过来，**248 个（20.5%）**"有标签但全程不透明"的素材正是第 2、3 步要拦的那一类 ——
这个数字也是"不能只看标签"的直接证据（1208 个带标签素材里，标签与"真的有 alpha"并非等价）。

两条实现坑（都是实测踩出来的，改这段之前先看）：

- **自带精简 ffmpeg 没编 pipe 协议**：`-f rawvideo ... -` 会报
  `Error opening output pipe:: Protocol not found` 并输出 0 字节。alpha 取样必须写一个
  4KB 的临时文件再读（`NSTemporaryDirectory()` 下的 `*.gray`，用完即删）。
- **`Duration: 00:00:03.01` 不能直接按 `:` 切**：`Duration` 自带一个冒号，直接切会得到
  4 段、时长恒为 nil，第 3 步会静默退化成"按标签转"。必须先剥掉 `Duration:` 前缀再切。

### 6.3 缓存与开关

| 项 | 设计 |
|----|------|
| 缓存目录 | 数据根下的 `media-cache/`（`MOCHI_DATA_DIR`，默认 `~/Library/Application Support/MochiBox`） |
| 缓存键 | `FNV-1a 64(源路径 + 字节数 + mtime)`——换素材/热更新后不复用旧产物 |
| 上限 | **4GB**，超出后按 mtime 从旧到新删（刚写好的那个永不删） |
| 并发 | 转码串行化（同一时刻只编一个）；同一文件的并发请求不排队，先按原样服务 |
| 关闭开关 | `MOCHI_MEDIA_RENDITION=off`（`0`/`false` 同义） |
| 覆盖二进制 | `MOCHI_FFMPEG=<path>` |
| 找不到 ffmpeg | 一次性 disabled，之后零文件 IO、零进程 |

### 6.4 不变量：任何失败一律回退原始字节

转码层对外只有一个同步方法，返回 `nil` 就表示"照原样服务源文件"。以下全部走这条路径：
没有 ffmpeg、探测无 alpha、转码非 0 退出、超时（120s）、rename 失败、产物被外部删掉。
**宁可这一次没有 alpha，也不能把请求打成 500 或空响应**。同理，产物只落 `media-cache/`，
**绝不写游戏目录**。

### 6.5 接入点

`StaticWebServer` 在"URL 解析 + 越权校验之后、stat 之前"把路径换成转码产物，
所以替换不会绕过 root 检查；`mov` 的 MIME 映射为 `video/mp4`（WKWebView 只认 hvc1 的
mp4/mov 容器）。整个服务器共享一份实例，翻页/重播不再 spawn 进程。

## 七、参数硬约束（写错就废）

| 参数 | 写错的后果 |
|------|------------|
| `-c:v libvpx-vp9` 必须在 `-i` **之前** | 原生 vp9 解码器不读 BlockAdditions，报 `Requested planes not available` / 0 字节；产物全不透明 |
| `-alpha_quality 0.75`（默认 0） | `0` = 不编 alpha：文件能播但完全没透明（实测四角 `[0,0,0,255]`） |
| `-vtag hvc1` | `hev1` 在 WKWebView 里 `play()` 直接 `NotSupportedError`，readyState=0，整页洋红 |
| 输出用 `-f mov` 或 `.mov` 扩展名 | 临时文件叫 `.mov.part` 且不带 `-f` 时 ffmpeg 选不出封装格式，**exit 234**，每次转码必失败、永远回退原始字节 |
| ffmpeg 必须 **9.x** | 7.1.5 转出来 tag 是 `hvc1` 但 hvcC 里只有一组 VPS/SPS/PPS——alpha 根本没进码流，画面仍是不透明 |
| 只编 mov muxer | `-f mp4` 会报 `Unknown format`，别写；`.mov` 扩展名或 `-f mov` 才安全 |
| 无音轨素材 | 不用特判：命令照样 EXIT=0，只会多一条"b:a 未使用"的无害警告 |
| 无 alpha 素材 | **不要转**：产物体积反而 3.12×，且没有任何收益 |

验证产物有没有真的带 alpha，看 hvcC 里的参数集数量（**SPS=2 / PPS=2** 才说明 alpha 层进了码流），
不要只看 `codec_tag_string=hvc1`——7.1.5 就是"tag 对但没 alpha"。注意：自带的精简 ffmpeg
没有 mov **demuxer**，不要用它回读产物做校验，用 ffprobe 或 WKWebView。

## 八、性能与体积

| 项 | 实测 |
|----|------|
| 单文件转码 | 1280×1280 / 3s 稳态约 **1.1s**（首次冷启动 1.44s） |
| 产物体积 | 源的 **3.0–3.5×**；加 `-b:v 3M -maxrate 4M` 可压到 **1.94×** |
| 全库规模 | 1208 个带标签素材里真正需要转的约 **962** 个；248 个"假 alpha"在判定阶段被跳过（不转、不缓存） |
| 缓存占用 | 约 **2.0GB**（4GB 上限留出余量） |
| 首次播放代价 | 第一次请求同步等 1–2s（探测约 40ms + 像素取样 60–90ms + 转码约 1.1s），之后命中缓存 |

## 九、端到端验收：黑底消失了多少

三层修完（转码 + canvas 桥接 + 提前回绕）后的窗口级取数，比任何单点探针都难造假：
`--play` 真作 + `--control`，定格在 `mac01_wait_nomalA` 的同一帧，对立绘矩形
（1280×1280 = 1,638,400 像素）逐像素比对：

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| 立绘矩形内「近黑」像素占比 | 75.10% | **0.00%**（18 / 1,638,400） |
| 立绘矩形平均亮度 | 43.27 | **177.46** |
| 与背景逐点一致的比例 | — | **72.04%** |
| 立绘四角 | `(0,0,0)` | 与背景**完全相同** |

18 个未与背景一致的像素占 0.0011%，保留两位小数即 0.00%。四角从纯黑变成与背景同色，
说明修掉的是「整片不透明黑」本身，而不是把亮度整体调高了。

> 取数前提见 §3.1：`alpha:false` 下 A 通道恒 255，必须靠白底合成结果判断透明；
> 背景对照用 `renderable=false`；采样矩形必须被立绘 bounds 完整覆盖。

## 十、已知限制与未修项

- **`ControlServer` 的应答截断（已修）**：socket 是 `O_NONBLOCK`，旧 `write` 遇 `EAGAIN`
  直接 `return`，超过 8192 字节的应答被静默截断且不补换行。现在写满为止（`poll(POLLOUT)`
  等待，5s 总预算，超时断连并记一行 stderr）。修复前 12000 及以上全部截在 8192，
  修复后 4000–64000 各档都完整收到；取超大数组仍建议分块，减少单条帧的体量。
- **Chromium 内核能原生解 alpha**：非默认路径（需要本机有 Chromium），不作为产品依赖。
- **判定的额外成本**：每个带标签素材多一次解码取样（首帧 60–90ms，必要时再补
  `0.8×duration` 一帧）；判定失败时保守转码，不会漏透明。
- **首帧延迟**：冷缓存下第一次播放会多等 1–2s；热缓存无感。
- **只覆盖 `.mpon`**：`.webm` 因 URL 扩展名决定解复用器而不能替换（见 §6.2），
  `.mp4` 也不走转码层。

## 十一、验收方法

- **内核探针**：`--kernel-smoke` 的 `video=` 现在表示 `readyState`（不是数量），
  且已把非 DOM 视频（PIXI BaseTextureCache 里的）纳入统计——MZ 的影片插件普遍
  `createElement('video')` 后从不 `appendChild`。
- **驱动探针**：`MOCHI_E2E=1 <binary> --play <game> --control <sock>`，客户端说 NDJSON
  （`{"id":1,"op":"eval","expression":"..."}`）。单条应答不再有 8192 字节截断（见 §十）。
- **采样纪律**：WKWebView 会在窗口被遮挡/计时器节流时把 `setInterval` 钳到 **1Hz**，
  而 `document.visibilityState` 仍可能报 `visible`（实测：11s 后采样间隔从 50ms 变成 1000ms）。
  判数据质量要看**采样间隔中位数**，不要只看 visibility。
- **透明度只看合成结果**：`alpha:false` 的画布 `readPixels` A 通道恒为 255（见 §3.1），
  必须垫纯色 quad 合成后读该点颜色；2D canvas 上的 alpha 只能证明解码层没坏，
  不能证明游戏里透明（见 §三）。
- **回归门禁**（当前 HEAD）：
  `--selftest` **74 pass / 0 fail / 1 skip**、`Tests/e2e/run.sh --suite contract`
  **14 cases / 541 assertions**、`--suite kernel` **13 cases / 153 assertions**；
  真机 `probe().errors` 必须为 0。
- **真机基线**（本作标题画面，`--kernel-smoke`）：
  `PASS scene=Scene_Title canvas=1280x720 video=4 video_ready=4 video_paused=false autoplay=verified`。
  其中 `video=` 是 readyState 不是数量；`video_ready=4` 说明 4 个视频都解码就绪。

## 十二、关键文件与复现

| 文件 | 职责 |
|------|------|
| `Resources/agent_mvmz.js` | 注入层：只读 `loop` + 提前回绕、rVFC 调度、2D canvas 桥接、扫描兜底 |
| `Sources/Adapters/Media/MediaRenditions.swift` | 转码层：判定、缓存、串行化、失败回退 |
| `Sources/Adapters/Web/StaticWebServer.swift` | 接入点：校验之后、stat 之前替换路径 |
| `Sources/Adapters/Web/StaticWebRequest.swift` | `mov` → `video/mp4` |
| `Scripts/build-ffmpeg.sh` | 静态精简 ffmpeg 的可复现构建 + 自检 |
| `Scripts/build.sh` | 打包时按需把 `vendor/media/ffmpeg` 塞进 `.app` |

```bash
# 1) 媒体工具链（可选，不入库）
bash Scripts/build-ffmpeg.sh
MOCHI_MEDIA_SAMPLE=/path/to/xxx.mpon bash Scripts/build-ffmpeg.sh   # 带真实素材自检

# 2) 出包
bash Scripts/build.sh

# 3) 回归
./build/MochiBox.app/Contents/MacOS/MochiBox --selftest | tail -2
bash Tests/e2e/run.sh --suite contract
bash Tests/e2e/run.sh --suite kernel
```
