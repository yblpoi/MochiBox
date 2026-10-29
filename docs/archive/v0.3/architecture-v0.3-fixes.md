# v0.3 两项缺陷修复 · 架构设计

**作者**：高见远（Architect）
**范围**：BUG-11（`lookup(raw, key)` 收 raw 不用）+ `profile_locked`（从 `browser_exited_early` 拆出）
**性质**：**只设计，不改源码、不构建**。本文所有"现状"结论均标注了 file:line 证据；查不到实据的一律写"未取证 + 该查哪里"。
**基线**：`Resources/agent_mvmz.js` 831 行 / `Sources/` 25 文件 / `Tests/qa/final-sha256.txt` 记录的 14:55 快照。

---

## ① 两项目标与验收判据

### 目标 A（BUG-11）：同一 `mapKey`、不同 `raw` 前缀时，控制码不得串行

**不变量**（本项目最核心，历史 4 个 bug 的根因）：
| 身份 | 定义 | 谁算 | 用在哪 |
|---|---|---|---|
| 行身份 | `surface + raw`（实际画到屏幕的串，**含控制码**） | Agent | 去重、`occurrences` |
| 翻译身份 | `mapKey`（剥码后 text 段 U+001F 连接） | Agent | 页面译文 Map 的键 |
| 缓存键 | `cacheKey`（Host 侧 sha256，含归一化） | Host | 持久化缓存、扇出 |

BUG-11 的实质：**把"翻译身份"当成了"行身份"来取用**——`lookup` 拿到 `mapKey` 后直接返回该 mapKey 名下唯一那份 `translatedRaw`，而那份字符串里带着**别的行**的控制码。

**验收判据（可自动化，逐条给判据不给感受）**

| ID | 判据 | 判定命令 | 期望 |
|---|---|---|---|
| A1 | 先下发 plain 译文，再画带码行 → 码保留 | `node Tests/qa/lookup_variant_probe.mjs` | `PASS \| BUG-11 \| 画 "\C[2]こんにちは"`，实际 `"\\C[2]你好"` |
| A2 | 反向：先画带码行、再画 plain 行 → **不加码** | 新增用例（本文 §③ 用例表 C2） | `こんにちは` 仍渲染 `你好` |
| A3 | `\N[1]は元気` 与 `\N[2]は元気`（同 mapKey、不同变量号）各自保留自己的 `\N[n]` | 新增用例 C3 | `\N[1]你好` / `\N[2]你好`（**人名不被串**：这是危害等级最高的一类） |
| A4 | 段数对不上 → **回退原文**，屏幕不出现拼错的码 | 用例 C6（喂 `segments` 文本段数与 raw 不等） | 渲染出原 raw 原文，`probe().mergeFallback ≥ 1` |
| A5 | 双端码表逐值一致不被破坏 | `bash Tests/qa/skip_parity.sh` | 7/7（退出码 0） |
| A6 | 既有正常替换不回退 | `--selftest`（D 组 `agent_emits_and_replaces`） | 全绿、`state.errors == 0` |

### 目标 B（profile_locked）：让"锁清不掉"有独立错误码与可执行文案

**验收判据**

| ID | 判据 | 判定方式 | 期望 |
|---|---|---|---|
| B1 | 锁清不掉时**不再**报 `browser_exited_early` | §⑥ 构造法 A（活 pid + 不可删锁）→ `--play` | stdout 有 `error_code: profile_locked`，退出码 **3** |
| B2 | 文案指向真因 | 同一输出 | 含 profile 目录绝对路径、含 `SingletonLock` 文件名、含 `chflags -h nouchg`/`rm -f` 命令、含一条排除项 |
| B3 | 浏览器根本没被拉起（不再产生误导性 Chromium 日志） | 同上 + `ls -l <profile>/../*.log` | 日志里**没有**新的 `Failed to create a ProcessSingleton` 行；`play: http=` 未打印 |
| B4 | 静态服务端口未被占用（门禁在起监听之前） | 同上 + `nc -z 127.0.0.1 <port>` | 端口空闲；下一次 `--play` 拿到同一端口（AC-4 不受影响） |
| B5 | 不误伤：正常 profile（无锁 / 锁可删）行为不变 | `--selftest` F 组 `web_runner_stop_partial` + `Tests/e2e/play_e2e.sh` | 三条子用例全绿；`PLAY_E2E_PASS` |
| B6 | 码表与文案两个 switch 都补齐（否则编译失败） | `swiftc` 编译（`skip_parity.sh` 第一步就编 `Models.swift`） | 退出码 0 |

---

## ② BUG-11 现状取证

### 2.1 `lookup` 现状（逐行）

`Resources/agent_mvmz.js:277-283`
```js
function lookup(raw, key) {
  var entry = translations[key];
  if (entry && typeof entry.translatedRaw === 'string' && entry.translatedRaw !== '') {
    return entry.translatedRaw;      // ← raw 参数从头到尾没被读过
  }
  return null;
}
```
- 写入侧 `putTranslation`（`agent_mvmz.js:266-275`）存的是 `{ translatedRaw, segments }`，键 `item.key`（Host 下发的 `mapKey`）。
- **`segments` 已经在 Map 里存着，从来没被读过**（`grep` 全文件：`entry.segments` 零处引用）。
- 唯一调用点 `agent_mvmz.js:470-474`：`hit = lookup(raw, key);`，`raw` 就在手里。

### 2.2 完整故障链（含 Host 侧，逐环节取证）

| # | 环节 | 证据 | 行为 |
|---|---|---|---|
| 1 | 行 A `こんにちは` 上报 | js:441-453 `payload.segments = splitSegments(raw)` | Host 用 A 的 segments 重算 cacheKey |
| 2 | Host 算两级键 | `SessionController.swift:390-397`（`mapKey = Segmenter.mapKey(payload.segments)`，`cacheKey = Segmenter.cacheKey(...)`，**丢弃 Agent 的 key**） | `\C[2]こんにちは` 与 `こんにちは` 得到**同一个 cacheKey**（`Segmenter.swift:236-247` 只吃 text 段） |
| 3 | 翻译结果回填 | `SessionController.swift:458-463`：`translatedSegments(...)` + `reassemble(...)`，然后 `delivered[cacheKey] = (raw, segments)` | A 路径：`segments=[{text,你好}]`、`raw="你好"` |
| 4 | 下发 Agent | `SessionController.swift:536-546`：`TranslationPushItem(key: mapKey, translatedRaw: raw, segments: segments)`；`mapKeyByCacheKey[cacheKey]`（397 行） | `key="こんにちは"`，`translatedRaw="你好"` |
| 5 | 行 B `\C[2]こんにちは` 到达 | `SessionController.swift:435-445`：`delivered[cacheKey]` 命中 → 直接 `applyTranslation` 并 **`return`（不再 push）** | JS 侧**永远不会**收到 B 的版本；B 只能借用 A 的那一格 |
| 6 | 画 B | `agent_mvmz.js:465-474` | `key="こんにちは"` 命中 → 返回 `"你好"` → **`\C[2]` 丢失** |
| 7 | 反向顺序 | 同上，`delivered` 里存的是 `raw="\C[2]你好"` | 画 `こんにちは` → **凭空加色** |

> **第 5 步是本 bug 的结构性原因**：`delivered` 命中分支没有 `pushTranslation`，所以"每行各自的 raw 版本"从来没有被下发过。这不是漏写，而是"缓存/扇出按翻译身份"的正确设计所带来的必然后果——**所以修复不能放在"多推几条"，只能放在"用本行 raw 当骨架重组"**。

### 2.3 ★ Host 侧 `segments` 到底装了什么（本设计的判定前提，已取证）

**结论：`segments` 是"逐文本段的译文 + 逐码段的原文码值"的完整有序分段数组，可以直接用于纯本地重组。不需要改下发协议。**

取证链（三处独立证据）：

1. **生产构造函数**：`Segmenter.translatedSegments(segments:translatedText:)`（`Sources/Domain/Segmenter.swift:288-313`）
   ```swift
   for segment in segments {
       if segment.kind == .code { output.append(segment) }                    // 码段：原样保留（本行自己的码值）
       else { output.append(Segment(kind: .text, value: pieces[cursor])) ... } // 文本段：按序取译文分片
   }
   ```
   入参 `segments` 是**当事行**的分段（`payload.segments` / `item.translatedSegments`），`pieces` 是后端返回的 `translatedText` 按 U+001F 切开的**逐段译文**。所以输出数组里：`code` 段 = 该行原文码值（未改写，大小写也未被上转）；`text` 段 = 该段译文。
2. **下发序列化**：`Models.swift:757-766` `pushItemToJSON` 把 `[Segment]` 序列化为 `[{"kind":"code"|"text","value":"…"}]`，与 `agent_mvmz.js:141-175` `splitSegments` 产出的 `{kind,value}` 结构**同构同序**。
3. **唯一字段定义**：`Models.swift:695-705` `TranslationPushItem { key, translatedRaw, segments: [Segment] }`（`segments` 非可选），`SegmentKind` 只有 `.text` / `.code` 两值（`Models.swift:318-321`）。

**"够不够用"的精确回答**：
- **够**：重组只需要"逐文本段译文"，`segments` 正是这个；码值从本行 `raw` 的 `splitSegments` 取，码数量必须与 `segments` 的文本段数一一对应。
- **不需要**的是 `segments` 里的 `code` 段值——它属于**先到的那一行**（见 §2.2 第 5 步）。所以规则一句话：**`segments` 只当"译文文本段队列"用，`code` 段一律丢弃、改发本行 raw 的码值。**
- **不需要改协议**的理由：`TranslationPushItem` 已有 `segments` 且线上一直带着；JS 侧 `putTranslation` 已存；改协议（新增字段/新消息类型）会同时牵动 `HostCommand`、`Models.swift`、`SelfTestRunner` 的 `host_command_json` 断言（`SelfTestRunner.swift:1090-1096`）与两端 parity 脚本，**收益为零、回归面为正**。

### 2.4 一个必须写下来的反例修正（对 brief 的例子）

brief 里用 `\C[2]350` / `350` 举例。这两条**在真实产品路径上拿不到同一条译文**：`350` 会被跳过判据判成 `numeric`（`Segmenter.swift:352-374` / js:353-365），`status=skipped`、不入队、不查缓存（`SessionController.swift:412-427`）。所以这个 pair 只能用来解释"身份语义"，不能当回归样本。

**真正能复现且危害更大的样本**（按危害排序，全部进 §③ 用例表）：
| 样本 | 同 mapKey | 后果 | 危害 |
|---|---|---|---|
| `\N[1]は元気` / `\N[2]は元気` | `は元気` | 一个角色的名字被画成另一个角色 | **语义错误**（B 级） |
| `\V[1]が足りない` / `\V[2]が足りない` | `が足りない` | 显示错误的变量值（金币/血量） | **语义错误** |
| `\C[2]勇者よ` / `勇者よ` | `勇者よ` | 颜色丢失 / 凭空加色 | 呈现（A 级） |
| `\FS[20]テキスト` / `テキスト` | `テキスト` | 字号错乱 | 呈现 |
| `\c[3]やあ` / `\C[2]\c[3]やあ` | `やあ` | 码前缀串行；顺带覆盖"低case码不被上转" | 呈现 + 契约 |

---

## ③ 重组算法与伪码

### 3.1 算法（一句话）

> 以**本行 `raw` 的 `splitSegments` 结果为骨架**：`code` 段发本行自己的码值；`text` 段按序取 `entry.segments` 里的译文文本段。文本段数对不上就**不猜**——回退原文。

### 3.2 设计伪码（**仅供 Engineer 参照，本文不改源码**）

替换 `agent_mvmz.js:277-283`，并新增一个纯函数（建议放在 `textOf` 之后，与分段工具同区）：

```js
/// 用本行 raw 的分段骨架重组译文。**不抛异常**，用返回值表达四种结局。
/// 返回 { ok:true, value } 或 { ok:false, reason:'no_text'|'no_segments'|'bad_segment'|'count_mismatch' }
function mergeBySkeleton(rawSegments, translatedSegments) {
  var textCount = 0, i;
  for (i = 0; i < rawSegments.length; i++) {
    if (rawSegments[i].kind === 'text') { textCount++; }
  }
  // 全 code 行（`\i[17]` / `\g`）没有可替换的文本段：返回 null 等价于"不替换"更省事。
  if (textCount === 0) { return { ok: false, reason: 'no_text' }; }

  // 老 Host / 未带 segments：拿不到文本段队列。
  if (!translatedSegments || typeof translatedSegments.length !== 'number') {
    return { ok: false, reason: 'no_segments' };
  }
  var pieces = [];
  for (i = 0; i < translatedSegments.length; i++) {
    var seg = translatedSegments[i];
    if (!seg || typeof seg.kind !== 'string' || typeof seg.value !== 'string') {
      return { ok: false, reason: 'bad_segment' };
    }
    // 只收 text 段；code 段**故意丢弃**（那是先到那一行的码值，不是本行的）。
    if (seg.kind === 'text') { pieces.push(seg.value); }
  }
  if (pieces.length !== textCount) {
    return { ok: false, reason: 'count_mismatch', pieces: pieces.length, textCount: textCount };
  }

  var out = '', cursor = 0;
  for (i = 0; i < rawSegments.length; i++) {
    if (rawSegments[i].kind === 'text') {
      out += pieces[cursor];
      cursor++;
    } else {
      out += rawSegments[i].value;   // ★ code 段：只用本行 raw 的值，大小写原样（不上转）
    }
  }
  return { ok: true, value: out };
}

function lookup(raw, key, rawSegments) {
  var entry = translations[key];
  if (!entry || typeof entry.translatedRaw !== 'string' || entry.translatedRaw === '') { return null; }

  var merged = mergeBySkeleton(rawSegments, entry.segments);
  if (merged.ok) { return merged.value === '' ? null : merged.value; }
  if (merged.reason === 'no_text') { return null; }        // 本行没有文本段，无需替换
  if (merged.reason === 'no_segments') {                   // 无法重组但也没矛盾：保持 v0.2 行为
    state.mergeFallback++;
    return entry.translatedRaw;
  }
  state.mergeFallback++;                                   // 有信息但自相矛盾：宁可回退原文
  return null;
}
```

同时在 `processText`（js:460-477）里让"分段只算一次"，并让 `mapKey` 保持**只有一个定义**（本项目反漂移纪律：两套实现必然漂移）：

```js
function mapKeyOfSegments(segments, raw) {      // ★ 新增：mapKey 的唯一实现
  var text = textOf(segments);
  return text === '' ? raw : text;
}
function mapKeyOf(raw) { return mapKeyOfSegments(splitSegments(raw), raw); }  // 行为与现状逐字节一致

function processText(raw, surface) {
  if (typeof raw !== 'string' || raw.length === 0) { return null; }
  var segments, key;
  try {
    segments = splitSegments(raw);
    key = mapKeyOfSegments(segments, raw);
  } catch (e) { state.errors++; return null; }
  var hit = null;
  if (state.enabled) {
    hit = lookup(raw, key, segments);            // ← 三参：传骨架，避免二次 split
    if (hit !== null) { state.replaced++; }
  }
  collect(raw, surface, key, hit !== null);
  return hit;
}
```

**副作用与收益**：
- `drawTextEx` 每帧每行原本 `splitSegments` 跑 **2 次**（`mapKeyOf` 一次 + `collect` 一次），改后 1 次（若把 `segments` 也传给 `collect`）或仍 2 次——**不会变差**，常见情形变好。
- `state` 新增 `mergeFallback`（初值 0），`probe()`（js:710-726）输出里加一个键即可（现有断言 `hooks.contains("\"errors\":0")` 是子串匹配，`--play` 用 sed 取 `"replaced":N`，**加键不会破任何既有断言**，已核对 `SelfTestRunner.swift:901/944`、`play_e2e.sh:178`）。

### 3.3 降级矩阵（**规范**，四种结局一一对应动作）

| 条件 | 结局 | 动作 | 是否计 `mergeFallback` |
|---|---|---|---|
| 本行无文本段（全 code） | `no_text` | 返回 null（不替换） | 否 |
| `entry.segments` 缺失/非数组 | `no_segments` | 返回 `translatedRaw`（v0.2 行为，**无信息时不做更坏的猜测**） | 是 |
| `entry.segments` 元素畸形 | `bad_segment` | 返回 null（回退原文） | 是 |
| 文本段数 `M ≠ N` | `count_mismatch` | 返回 null（回退原文，**绝不拼错码**） | 是 |
| `M == N` | `ok` | 返回重组串 | 否 |

**为什么 `count_mismatch` 选"回退原文"而不是"回退整条 `translatedRaw`"**：`translatedRaw` 正是带**别人码值**的那条串，回退它等于把 bug 在自己修的地方重新放回去。而"回退原文"的代价只是这一行保持日文——用户看得见、可复现、不会误以为翻译错了。
**为什么 `no_segments` 仍允许回退 `translatedRaw`**：那是"拿不到任何分段信息"的情形（只可能来自非本工程的 Host），此时没有任何判据可依，保持 v0.2 行为是不制造新回归的唯一选择；并且 `mergeFallback` 计数让它**可被观测**（QA 可断言正常会话里恒为 0）。

**段数不匹配在正常情况下不可能发生**（说明为什么这个分支只是保险）：
`cacheKey` 由 `joinForBackend(segments)` 归一后哈希得到（`Segmenter.swift:236-247`），`splitSegments` 永不产出空 text 段（js:151/164/173 只在 buffer 非空时 flush），`normalizeForKey` 不剥 U+001F（`Segmenter.swift:157-167` 白名单只有 5 个空白码位）。因此 cacheKey 相同 ⟹ 归一后 join 相同 ⟹ text 段数相同。

### 3.4 用例表（QA 直接照抄进探针）

| ID | 先下发（key / translatedRaw / segments） | 再画 raw | 期望渲染 |
|---|---|---|---|
| C1 | `こんにちは` / `你好` / `[{text,你好}]` | `\C[2]こんにちは` | `\C[2]你好` |
| C2 | `こんにちは` / `\C[2]你好` / `[{code,\C[2]},{text,你好}]` | `こんにちは` | `你好`（**不得**是 `\C[2]你好`） |
| C3 | `は元気` / `你好` / `[{text,你好}]` | `\N[1]は元気` 与 `\N[2]は元気` | `\N[1]你好` / `\N[2]你好` |
| C4 | `やあ` / `你好` / `[{text,你好}]` | `\c[3]やあ` | `\c[3]你好`（**小写码不上转**） |
| C5 | `テキスト` / `文本` / `[{text,文本}]` | `\FS[20]テキスト\FS[24]` | `\FS[20]文本\FS[24]`（尾码保留） |
| C6 | `こんにちは` / `你好` / `[{text,你},{text,好}]` | `こんにちは`（1 个文本段） | 原文 `こんにちは` + `mergeFallback==1` |
| C7 | `こんにちは` / `你好` / 无 `segments` 字段 | `\C[2]こんにちは` | `你好`（v0.2 兼容路径）+ `mergeFallback==1` |
| C8 | 下发 key `\i[17]` / translatedRaw `\i[17]` / `[]` | `\i[17]` | `\i[17]`（不替换，`mergeFallback==0`） |

---

## ④ 身份一致性走查表（缓存 / 去重 / 回绘，逐条点名）

| # | 位置 | 用的哪个身份 | 判定 | 说明 |
|---|---|---|---|---|
| 1 | **取译文** `agent_mvmz.js:277-283`（`lookup`） | 用 `mapKey` 取了"带码的行内容" | ❌ **BUG-11 本体** | 本文 §③ 修 |
| 2 | **页面译文 Map 的键** `js:266-275` / `SessionController.swift:542` | `mapKey` | ✅ 正确 | 页面只认 mapKey，Host 下发的 key 就是 mapKey（`mapKeyByCacheKey`，`SessionController.swift:397/538`） |
| 3 | **持久化缓存** `Stores.swift:648` `put(key:text:translatedText:backend:)` | `cacheKey`；**存的是无码的 `translatedText`** | ✅ 正确 | 缓存里没有控制码，命中后由 `translatedSegments(segments: <当事行>)` 用**当次行的**码值重组（`Segmenter.swift:288-313`）。**缓存路径从未被 BUG-11 污染**，这解释了为什么"清缓存"修不好这个 bug |
| 4 | **采集去重** `js:395-414`，调用 `js:430` `shouldEmitFor(surface, raw)` | 行身份 = `surface + raw` | ✅ 正确（BUG-8 已修） | `350` 与 `\C[2]350` 签名不同，两条都上报。**注意**：文件第 30/67 行注释仍写 `surface + key`，实现是 `surface + raw`（`docs/qa-report.md:224` 已列为"注释漂移，危险度高于普通漂移"）。本任务顺手改注释，**不改逻辑** |
| 5 | **Host 扇出** `TextStreamStore.swift:120-122 / 159-174` | `cacheKey` | ✅ 设计如此（AC2.2b 要求） | `350`/`\C[2]350` 必须同时收敛，否则一行永远 `pending` |
| 6 | **Host 译文列内容** `TextStreamStore.swift:165` `rows[index].translated = translatedRaw` | ⚠️ **用先到行的 raw 填了所有行的译文列** | ⚠️ **BUG-11 的 Host 侧同型点（显示层）** | `\C[2]350` 那行的译文列会显示 `350` 那行的码前缀。**只影响显示/导出，不影响屏幕、不影响计费**。修法与本设计同构（`TextEvent.segments` 已存本行分段，`TextEvent.translatedSegments` 已存译文分段，纯本地可重组），但会改动扇出语义，**建议本轮不做**（见 §⑦ R4） |
| 7 | **回绘** `js:732-751` `requestRepaint` | 只调 `refresh()`，重绘时引擎再次交出**它自己持有的串** | ✅ 正确（桩页） | `Fixtures/mv_stub/index.html:172-174` 每帧从 `gameMessage._texts` 重画 → 传的是原 raw → `processText` 重跑 → 修好 `lookup` 后自然正确 |
| 8 | **回绘（真实引擎）** `js:595-639` `hookStartMessage` **原地改写** `$gameMessage._texts[j]` | 引擎此后持有的 `raw` 已是**译文** | ⚠️ **未取证** | 若 MV/MZ 逐字重画 `_texts`，则下一条 TextEvent 的 `raw` 是中文、`mapKey` 也是中文 → 存在"译文被再翻译一次"的风险。**该查哪里**：`--play` 跑真游戏后过滤 jsonl 里 `raw` 为 CJK 译文的行（`grep '"raw":"[^"]*[一-龥]'`），或读 `RJxxxxxx/www/js/rpg_windows.js` 的 `Window_Message.processCharacter`。**与本任务不耦合**（不修也不恶化） |
| 9 | **Host 下发键的归一化稳定性** `SessionController.swift:390-397` + `Segmenter.swift:219-225` | `cacheKey` 归一化而 `mapKey` 不归一 | ⚠️ **观察项 OBS-A（P2）** | 全角/半角等价样本 `ＡＢ` 与 `AB`：`cacheKey` 相同（NFKC 后同串），但 `mapKey` 不同（`ＡＢ` ≠ `AB`），而 JS 只按 `mapKey` 查表 → 后到的那个变体**查不到**、永远显示原文。由代码直接可判，无需实测。**与本轮两项无关，仅登记** |

**结论**：除 #1（要修）与 #6（登记、建议不做）外，其余三处（缓存 #3、去重 #4、回绘 #7）**没有**再用错身份。#6 是"同一 bug 的显示层投影"，不影响 AC-8 的截图证据。

---

## ⑤ `profile_locked` 判定点与文案

### 5.1 判定时机与精确插入位置

**插入点：`Sources/Adapters/Web/WebGameRunner.swift` 第 106 行之后、第 108 行（`pageURL = …`）之前。**

现状：
```
105        reclaimOrphanBrowser()
106        clearStaleSingletonLocks(manager: FileManager.default)
107
108        pageURL = "http://..."
…（111-118 起静态服务）…（138 拉浏览器）
```
改为：
```
105        reclaimOrphanBrowser()
106        let lockState = clearStaleSingletonLocks(manager: FileManager.default)
107        if let lockError = ProfileLockState.error(for: lockState) {          // ★ 新增
108            config.log?.error("WebGameRunner", "拒绝启动：profile 单实例锁未清空", [
109                "state": lockState.logValue, "profile": config.profileDir.path
110            ])
111            throw lockError                                                  // ★ 新增
112        }
   …（原 108 起的代码整体下移）
```

**为什么正好在这里**（四条理由，全都可验证）：
1. **必须在 `reclaimOrphanBrowser()` 之后**：回收才是把锁变成"可清理"的那一步（`WebGameRunner.swift:290-319`）；提前判定会对"本来能自愈"的残留误报。
2. **必须在起静态服务之前**（111-118 行）：这里是**唯一**能做到"失败即无残留"的位置——`self.server` 还是 nil、没有端口被绑、`GameLauncher.launch` 的 catch（`GameLauncher.swift:480-488`）里 `runner.stop()` 幂等且无事可做。放在起监听之后就要多背一份回滚正确性。
3. **必须在拉浏览器之前**（138 行）：这样 Chromium 那句 `Failed to create a ProcessSingleton … Aborting now` **根本不会被写进日志**，B3 判据可断言"日志里没有这一行"——否则真因永远和现象混在一起。
4. **判据就地取现成结论**：`clearStaleSingletonLocks` 在 448-454 行**已经**做了"锁是否还在"的终检，只是现在只 `warn`。把它的"发现"变成"返回值"，是零额外探测。

### 5.2 状态机（替代现在的"只 warn"）

> **行号说明（本设计写于实现之前）**：§5.1/§5.2 引用的"第 106/108/418-455/447-454 行"是**改动前基线**的行号。实现落地后行号已下移，实际锚点为：门禁 `WebGameRunner.swift:155-160`（注释 149-154）、`ProfileLockState` 定义 `:70-105`、`clearStaleSingletonLocks -> ProfileLockState` `:478-536`（终检 `:513-516`、只对 `SingletonLock` 硬失败 `:524-530`）、`profileLockError(for:)` `:542+`。**以代码为准，行号仅用于回溯设计意图。**

新增（建议与 `WebRunnerConfig` 同级放在 `WebGameRunner.swift` 顶部；**只用 Foundation，无 SwiftUI/AppKit**，不触碰核心层约束）：

```swift
enum ProfileLockState: Equatable, Sendable {
    case clear
    case heldByLiveBrowser(pid: Int32, target: String)      // 锁指向的 pid 活着，且确实是本 profile 的浏览器
    case unremovable(path: String, target: String?, detail: String)  // 删了（或尝试删了）但它还在
}
```
`clearStaleSingletonLocks(manager:) -> ProfileLockState` 的改写规则（**判据是"最终还在不在"，不是"删除有没有抛错"**）：

| 观测 | 状态 | 理由 |
|---|---|---|
| `SingletonLock` 不在（含"悬空软链也判不在"） | `.clear` | 正常 |
| target 可解析出 pid，`isOurBrowser(pid)` == true（424-433 分支） | `.heldByLiveBrowser(pid, target)` | 等于"同一存档正被另一实例使用" |
| 删除尝试**之后**仍能 `destinationOfSymbolicLink` 读到（447-454 的终检） | `.unremovable(path, target, detail)` | 不许只看抛错：文件可能在检查与删除之间被别人删掉（TOCTOU），那种情况不该失败 |
| 其余（target 不是 `<host>-<pid>` 形态、pid 已死且删除成功） | `.clear` | Chromium 自己认得出 stale |

**关于"删除失败但 pid 已死"会不会是误报**——不会，且有实证：`docs/qa-report-v0.2.md:373-385` 记录了真实发生的一次（沙箱内 `unlink` 被拒 `Operation not permitted`，锁指向 01:15 那次已死的 pid 79634），Chromium 报 ProcessSingleton 并退出。原理是 Chromium 的 reclaim 需要**同一个目录写权限**去 rename；`unlink` 被拒时 rename 也会被拒。所以"删不掉 ⟹ 大概率 abort"，`.unremovable` 硬失败是**有因**的，不是防御性猜测。

> **已裁决（team-lead）**：`heldByLiveBrowser` 与 `unremovable` **两个分支都硬失败**，不做"仅 held 硬失败"的条件性降级（见 §⑧ Q2）。Engineer 不得实现任何"放宽判据/跳过门禁"的分支；误报的证伪由上表的反例 R1/R2 在 #4 阶段证明。

### 5.3 一个码，三种文案：取舍与理由

**结论：只新增 1 个码 `profile_locked`，按状态给不同 `message`。**（`uiMessage` 给通用兜底，`retryable = false`。）

理由：
1. **处置动作同类**：三条分支的下一步都是"去处理这个 profile 目录里的锁/实例"，不是三类不同的产品能力。
2. **码表成本是复利的**：`ErrorCode` 每加一个值要同步 5 处——`Models.swift:376-386`（枚举）、390（`retryable`）、399（`uiMessage`）、`AttachCLI.swift:429-435`（`environmentCodes` → 退出码 3 + `error_code:` 行）、`docs/archive/v0.2/architecture-v0.2-web-runner.md:1089-1097`（§9.1 表）。加 3 个码 = 15 处，其中两处 switch 漏写会**编译失败**（B6）——收益不抵风险。
3. **`retryable` 三条分支同值**（都是 false：不解决就必然同样失败；对比 `webPortBusy` 为 true 是因为换端口/换时机**可能**成功）。
4. **将来要机器区分时不用改码**：分支标识放进 `underlying`（`reason=held_by_live_browser pid=…` / `reason=unremovable errno=…`），脚本 `grep 'reason=unremovable'` 即可分支。这与 `browser_exited_early` 现在把 5 种原因写进 `message` 的做法**不同**：那里没有可机读的分支标识，这里一开始就有。

**明确的取舍代价（写下来给下一个人）**：`uiMessage` 只能给一句通用话（"浏览器 profile 被占用，单实例锁无法清理"），分支指引**必须**写在抛错点的 `message` 里。这不是缺陷——`docs/archive/v0.2/architecture-v0.2-web-runner.md:1116` 已经规定 UI 显示的是 `code.rawValue + message`，指引写进 `message` 就是可见的（`docs/archive/v0.2/architecture-v0.2-web-runner.md:1108-1116` §9.3）。

### 5.4 文案（四要素：做什么 / 哪个文件或环境变量 / 具体命令 / 一条排除项）

参照 `BrowserResolver.failureMessage`（`Sources/Adapters/Web/BrowserResolver.swift:177-189`）的写法：首行 `（detail: <code> reason=…）`、后续"请…"清单、括号里排除项。

**分支 ①：锁被活着的本 profile 浏览器持有（= 同一存档正被另一实例使用）**
```
这个游戏的浏览器 profile 正被另一个实例占用，无法启动（detail: profile_locked reason=held_by_live_browser pid=<pid>）。
profile 目录：<config.profileDir.path>
单实例锁：  <profile>/SingletonLock -> <target>
请先关掉那个实例：本机另一个 MochiBox 窗口（或你手动用 Chrome 打开过这个 profile 的窗口），然后重试。
若你确认 pid=<pid> 已经不是浏览器（被系统复用给了别的进程），直接删锁：
  rm -f "<profile>/SingletonLock" "<profile>/SingletonCookie" "<profile>/SingletonSocket"
（排除项：不是"找不到浏览器"——本机已解析到 <browser.executable.path>；也不是端口占用，换端口无效。）
```

**分支 ②：锁删不掉（权限 / immutable / 受管策略）**
```
浏览器 profile 的单实例锁删不掉，启动被阻止（detail: profile_locked reason=unremovable）。
文件：<profile>/SingletonLock（指向 <target 或"无法解析">；错误：<detail>）
请依次执行：
  chflags -h nouchg "<profile>/SingletonLock"          # 若该文件被设为不可变（macOS 上 uchg 会拒绝 unlink）
  rm -f "<profile>/SingletonLock" "<profile>/SingletonCookie" "<profile>/SingletonSocket"
  ls -ldO "<profile>"                                   # 需要 0700 且属主是你
若仍失败，把运行时目录指到可写位置即可绕开（存档/端口表一起搬）：
  MOCHI_DATA_DIR=/tmp/mochibox-data  ./MochiBox --play "<game>"
（排除项：不是浏览器缺失，也不是 CPU 架构/`--no-sandbox` 问题——那两个只会在浏览器已经起来之后才表现为 browser_exited_early。）
```

要点：
- 首行都给 **`detail: profile_locked reason=…`**，与 `browser_not_found` / `browser_exited_early` 的 `detail:` 约定一致，脚本与用户都认同一套前缀。
- 两个分支都**点名绝对路径**（用户能直接复制执行）；分支 ② 额外给 `MOCHI_DATA_DIR`（这是本工程已验证的逃生门，`K.webProfileDirectoryName` + `Stores.swift:37-42`）。
- 排除项**各写一条、互不重叠**：分支 ① 排除"缺浏览器/端口"（因为这两个是 `browserExitedEarly` 文案里混进来的邻居），分支 ② 排除"架构/沙箱"（它们是"浏览器起来了才失败"的那类）。

### 5.5 `ErrorCode` 三处必须同步（否则编译失败 / 脚本拿不到码）

```swift
// Models.swift:386 之后（v0.2 区末尾）
/// 浏览器 profile 的单实例锁清不掉（残留锁不可删 / 被另一实例持有）。
case profileLocked = "profile_locked"

// Models.swift:390 retryable —— 不加进 true 分支（默认 false 即正确，无需写代码，但要在注释里说明为什么）
// Models.swift:399+ uiMessage
case .profileLocked: return "浏览器 profile 被占用，单实例锁无法清理（请关闭另一个实例或手动删锁）"

// AttachCLI.swift:429-435 environmentCodes —— ★ 漏了这一处，--play 会退化成退出码 1 且不打 error_code: 行
.profileLocked,
```
`AttachCLI.swift:487-495` 的 catch 逻辑无需改：码进了 `environmentCodes` 就自动打印 `error_code: profile_locked` + `play failed: <message>` 并 `return 3`（B1/B2 判据）。

### 5.6 与 QA 实测日志的边界：为什么前置门禁优先、日志解析只做二级（**不要反向覆盖**）

QA 在基线 `834d603d` 上抓到一条真实样本（窗口模式，外层沙箱禁止 unlink）：
```
[12903:…:ERROR:chrome/browser/process_singleton_posix.cc:334] Failed to unlink …/SingletonLock: Operation not permitted (1)
[12903:…:ERROR:chrome/browser/process_singleton_posix.cc:349] Failed to create …/SingletonLock: File exists (17)
[12903:…:ERROR:chrome/app/chrome_main_delegate.cc:624] Failed to create a ProcessSingleton … Aborting now
```
QA 建议把 stderr tail 当**判定输入**（按 `Operation not permitted` / `File exists` 分流成 `profile_locked` 的两个子因）。

**判定：这个样本已被前置门禁覆盖，不需要靠日志解析；日志解析可以作为二级补充，但不得替代门禁。** 三条理由：

1. **该样本必然命中 `.unremovable`**：`clearStaleSingletonLocks` 在拉浏览器**之前**（`start()` 内、现有实现的 155 行）就尝试 `removeItem`。沙箱拒绝 Chrome 的 `unlink` 与拒绝我们的 `unlink` 是同一个 syscall、同一组凭证 → 我们也会失败 → `removeFailure` 有值 + 终检 `stillExists` 为真（实现见 499-530 行）→ `.unremovable` → 在起监听与拉浏览器之前抛 `profile_locked`。**证据链来自"同一 syscall 同权限"，不是推断 Chrome 的意图。**
2. **反向情形也不产生假阳性**：若外层限制只作用于 Chrome 子进程、而我们能删掉锁，那么门禁判定为 `.clear`、不报错，Chrome 拿到干净 profile 正常启动（它那句 `Failed to unlink` 本来就是在删**上一个**残留锁）。**门禁唯一的失败模式是"我们也删不掉"，而那正是 Chrome 会 Abort 的充分条件**（`unlink` 与 reclaim 用的 `rename` 同目录同权限）。
3. **日志解析版本脆弱**：`process_singleton_posix.cc:334/349` 是**行号**，绑定 Chrome for Testing 156 这一版源码布局；换内核（Edge/Brave/Chromium 各版本）行号必漂。若将来真要做二级判定，**只允许匹配稳定子串**（`Failed to create a ProcessSingleton` / `Failed to unlink` / `Operation not permitted` / `File exists`），**禁止匹配行号或 `ERROR:` 前的进程号**，并且只用于**改写 `browser_exited_early` 的文案**，不得新开码、不得改退出码。

**本轮明确不做**（防止实现走样）：在 `waitForReady` 的 `!alive` 分支（`WebGameRunner.swift` 原 149-158 行区域）加"读 tail 反推错误码"的逻辑。它只能在后置阶段生效（浏览器已经白起一次），而前置门禁已覆盖同一类；把它塞进本轮只会扩大改动面并引入版本耦合。**登记为后续项**（若 QA 在 #4 发现"我们删得掉但 Chrome 仍然 Abort"的客例，再补这一层，并附一条新的实测样本）。

### 5.7 登记两件事：BUG-12（"已连接但零产出"）不修 + 一条**已撤回**的归因

**① 归因撤回（必须留痕，否则后来者会照错的前提设计）**
本设计初稿曾按 QA 的首版描述，把窗口模式白屏写成"`mach_port_rendezvous` Permission denied → **渲染子进程已死** → 白屏但 `installed=true`"。**该归因已被 QA 撤回**：那两条日志时间戳为 09:52:48，距启动 152 秒 —— 正是 `--duration 150` 收尾 SIGTERM 的时刻，**运行期 150 秒内浏览器日志零错误**。因此"渲染子进程死亡"这个机制**不成立**，本文不再据此设计任何东西（例如 `page_renderer_dead`）。

**仍然成立的事实**（这些是数字，不是机制）：
- 窗口模式一次 150s：`probe.installed=true`、UI 显示"已连接/已注入"，但 `hooks` 只有 `Bitmap.drawText`（`Window_Base.drawText*`、`Window_Message.startMessage` 全缺 → 游戏 JS 主逻辑没起来）、`emitted=1`、`captured=1`、`skipped=1(tooShort)`、截图纯白、exit 1、**无任何错误码**。
- 排除项：同一份游戏 + headless + 全新 profile 一切正常（hooks 四个齐），故非游戏本体/链路问题。
- **成因未定位**；候选三个：外层沙箱影响窗口模式 Chrome 子进程 / 真实 profile 累积状态（含 02:42 旧 `SingletonLock` 指向 pid 92806） / 窗口模式 GPU 合成路径。未做隔离实验。
- 记录位置：`docs/qa-baseline-834d603d.md` §5.2。

**② BUG-12 本轮不修的裁决（team-lead）与三条理由**
1. 本轮范围已锁定 BUG-11 + `profile_locked`，两项都改了资源/错误路径；再加一个"报告层"改动，要把 selftest / E2E / AC-2 的判据整体重验一遍，收益不抵风险。
2. **更关键的一条（本轮最重要的设计教训）**：这类诊断手段（`captured==0 且 frame 空白`、`installed=true 但 Render 目标缺失`）**本身就是环境相关信号**。今晚这个空白帧的根因是受管环境的 rendezvous 权限、且**已撤回**，不是产品渲染逻辑；这套判据在真机上的**假阳性率未取证**。**拿未取证的判据去做硬失败，等于把"静默假成功"换成"静默假失败"。**
3. 真修法是产品决策（补渲染存活探针 vs 把窗口模式失败降级成显式错误码），需要产品口径，不该由工程侧顺手定。

**推论（写给将来做 BUG-12 的人）**：即使要做，形态只能是**诊断字段**（例如收尾打印一行 `diagnosis: connected_no_output`，依据是 `probe` 数字 + 时长，**不是**某个未证实的崩溃机制），**不得改退出码、不得改 `status` 语义、不得参与验收判定**；一旦它参与判定，就把失败模式从"静默假成功"换成了"静默假失败"，而后者更难查。

---

## ⑥ 可测构造方法（给 QA：让这条路径被实测，而不是只看代码）

前置：`BIN=build/MochiBox.app/Contents/MacOS/MochiBox`；`export MOCHI_DATA_DIR=/tmp/mtlock-$(date +%s)`（`Stores.swift:37-42` 会把整个运行时目录搬走，不动用户目录）。
profile 目录可由 `--play` 自己打印：`play: http=… debug=… page=… profile=<path>`（`AttachCLI.swift:480`），且因 `gameHash` 确定性派生（`K.webProfileDirectoryName`），**同一 webRoot 反复运行得到同一 profile 路径**。

### 构造 A：锁删不掉（分支 ②，活 pid + 不可变锁）—— 推荐，已在本机验证机制成立
```bash
# 1) 先跑一次，拿到 profile 路径（顺便保证目录存在）
PROFILE=$("$BIN" --play "$GAME" --headless --duration 3 2>&1 | sed -n 's/.*profile=//p' | tail -1)
# 2) 造一个"看起来被活着的进程持有、且删不掉"的锁
sleep 600 & LIVE=$!
ln -sfn "$(hostname)-$LIVE" "$PROFILE/SingletonLock"
chflags -h uchg "$PROFILE/SingletonLock"      # ← macOS 上 uchg 会让 unlink 返回 EPERM
# 3) 复现
"$BIN" --play "$GAME" --headless --duration 3; echo "exit=$?"
# 期望：exit=3、stdout 含 error_code: profile_locked、message 含 profile 路径与 chflags -h nouchg、浏览器日志无 ProcessSingleton 行
# 4) 清场（务必写进 trap）
chflags -h nouchg "$PROFILE/SingletonLock"; rm -f "$PROFILE"/Singleton{Lock,Cookie,Socket}; kill $LIVE
```
**已实测的机制证据**（本机 macOS，本设计取证时跑的）：
```
$ ln -s "$(hostname)-999999" SingletonLock && chflags -h uchg SingletonLock
$ python3 -c "import os; os.unlink('SingletonLock')"
UNLINK BLOCKED: 1 [Errno 1] Operation not permitted: 'SingletonLock'
```
即：`chflags -h uchg` 确实让 `unlink` 失败，而 `FileManager.removeItem` 走的就是 `unlink` 语义 → `clearStaleSingletonLocks` 的 437-445 catch 会命中，447-454 终检仍能看到锁 → `.unremovable`。（`chflags` 必须带 `-h`：不带时它作用在软链**目标**上，对悬空链会报 `No such file or directory`——这条坑我踩过，写进脚本注释。）

### 构造 B：锁被活着的本 profile 浏览器持有（分支 ①）—— 无需游戏、无需 root
```bash
BROWSER="$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium-* 2>/dev/null | sort -V | tail -1)"
BROWSER="$(ls -d "$BROWSER"/chrome-mac*/*.app 2>/dev/null | head -1)/Contents/MacOS/Chromium"
"$BROWSER" --user-data-dir="$PROFILE" --headless=new --no-sandbox --no-first-run about:blank &
HOLDER=$!
# 等 SingletonLock 出现（≤5s）
for i in $(seq 1 50); do [ -L "$PROFILE/SingletonLock" ] && break; sleep 0.1; done
"$BIN" --play "$GAME" --headless --duration 3; echo "exit=$?"
# 期望：exit=3、error_code: profile_locked、reason=held_by_live_browser
kill $HOLDER
```
判定为什么成立：`isOurBrowser`（`WebGameRunner.swift:351-367`）要求 ①`kill(pid,0)==0` ②`proc_pidpath` 含 `Chrome/Chromium/Edge/Brave/Vivaldi` ③argv 里有 `--user-data-dir=<本 profile>` 前缀匹配；上面三条全中 → 424-433 分支保留锁 → `.heldByLiveBrowser`。

### 构造 C：等价但不含外部浏览器的版本（用 pid 文件语义造"孤儿"）
```bash
# 让产品自己拉起浏览器，然后抹掉 pid 文件再杀 CLI（SIGKILL 不触发收尾）
"$BIN" --play "$GAME" --headless --duration 30 & CLI=$!
sleep 6; rm -f "$PROFILE/.mochibox-browser.pid"; kill -9 $CLI
# 此时浏览器活着、pid 文件没了 → reclaimOrphanBrowser 找不到线索 → 锁被"活浏览器持有"
```
构造 C 的价值：它精确复现"用户在受管环境里 `kill -9` 过 CLI"这一真实路径；副作用是慢（要等浏览器起来）。

### 反例回归（必须同时跑，防"修成永远报 profile_locked"）
```bash
# R1 干净 profile：不得出现 profile_locked
"$BIN" --play "$GAME" --headless --duration 5   # 期望 exit=0，无 error_code
# R2 残缺锁（pid 已死、可删）：产品应静默清掉（不报错）
ln -sfn "$(hostname)-999999" "$PROFILE/SingletonLock"
"$BIN" --play "$GAME" --headless --duration 5   # 期望 exit=0，日志有"清理残留的 Chromium 单实例锁"
```

---

## ⑦ 风险与回归面（哪些既有用例会被动到）

| # | 风险 | 触发条件 | 处置 |
|---|---|---|---|
| **R1** | `Tests/qa/lookup_variant_probe.mjs` 的 `XFAIL` 会变 `PASS` | 修好 lookup | 该脚本自身写着"若 PASS 说明可以升级成正式断言"。**任务要求：把它从 xfail 升级为 §3.4 的 C1-C8 表驱动硬门禁**（退出码非 0 即失败） |
| **R2** | `Tests/qa/final-sha256.txt` 里 `Resources/agent_mvmz.js` 的 sha256（第 4-5 行）**必然变化** | 改 JS | 必须由 QA 重新基线；否则"源码晚于二进制"的假绿防线失效 |
| **R3** | `bash Tests/qa/skip_parity.sh` 编译 `Models.swift` + `Segmenter.swift` + `Constants.swift` | 新增 `ErrorCode` 值 | 两个 switch 必须补齐，否则 `swiftc` 直接失败（这也是 B6 的守卫）。JS 侧不动码表/归一化，parity 应保持 7/7 |
| **R4** | `TextStreamStore.swift:165` 的"译文列用先到行 raw"（§④#6） | 不修则保持现状 | **建议本轮不修**：只影响显示/导出，不动扇出语义。若后续要修，算法与 §③ 同构（`row.segments` 作骨架 + `translatedSegments` 取文本段），且 `Tests/qa/store_probe.swift` S1/S2/S3 **不会红**（S2 不断言 `translated` 字符串，只断言 `status`/`stats.fresh`——已逐行核对 100-140 行） |
| **R5** | `--selftest` D 组 `agent_emits_and_replaces`（`SelfTestRunner.swift:938-947`） | 改 lookup | 该用例推的是 `segments:[{text,你好}]`、画 `こんにちは`（无码）→ 重组结果仍是 `你好`，`state.errors` 仍为 0。**预期不变绿也不变红**；建议顺手加一条带 `\c[3]` + `\I[n]` 的用例 |
| **R6** | `--selftest` F 组 `web_runner_stop_partial`（`LauncherCaseSupport.swift:250-377`） | 改 `WebGameRunner.start()` | 三条子用例的 profileDir 都是全新临时目录（`<hash>-partial-<port>`），**不会有锁** → 恒走 `.clear`。三条断言（browserNotFound / cdpTimeout / 幂等 stop + 端口可重绑）不受影响 |
| **R7** | `Tests/e2e/play_e2e.sh` AC-2/AC-3/AC-4 | 同上 | 每轮用**全新** `DATA_DIR`（脚本 57-63 行），profile 干净 → 不会被 `profile_locked` 拦。AC-4 的端口确定性也不受影响（门禁在分配/绑定之前） |
| **R8** | 误报把用户挡在门外（"永远 profile_locked"） | 若"删不掉"判据写成"删除抛错"而非"最终还在" | §5.2 已规定判据是**终检仍在**；并用 §⑥ 的 R1/R2 反例回归守住 |
| **R9** | `state` 新增 `mergeFallback` 破坏既有 probe 断言 | 改 `probe()` 输出 | 已核对：`SelfTestRunner.swift:901` 是子串匹配、`play_e2e.sh:178` 用 sed 取 `"replaced":N` → 加键安全。**不要**改任何既有键名 |
| **R10** | 二次翻译（§④#8） | 真实 MV/MZ 原地改写 `_texts` | 与本轮两项**不耦合**：修 lookup 不会让它变坏也不会变好。登记为待取证 |
| **R11** | 构建产物 `build/MochiBox.app/Contents/Resources/agent_mvmz.js` 是**拷贝** | — | 必须只改 `Resources/agent_mvmz.js`（`Scripts/build.sh` 负责拷贝）；**不许**直接改 build 目录里的副本 |
| **R12** | 文档漂移会复活已修的 BUG-8 | 注释与实现不一致 | `agent_mvmz.js:30` / `:67` 注释写的 `surface + key`，实现是 `surface + raw`（`docs/qa-report.md:224` 已点出）。本任务**顺手改注释**，零逻辑改动 |
| **R13** | **`hit !== null` 与"空串"的隐含契约**（team-lead 复核时提出，已核实本轮未踩） | 谁将来放宽 `lookup` 的空串处理 | `processText:593` 用 `hit !== null` 判命中（旧代码是 `if (hit)`）。三条出口都拦住了空串：`lookup:376` 空 `translatedRaw` → null、`:397` `merged === ''` → null、`:381` 全 code 行 → null。**因此当前安全**。但若有人把 `lookup` 改成"空串也算命中"，`args[0]` 会被赋成空串 → **整行文字被静默擦掉**（不报错、不计数、截图才发现）。改 `lookup` 返回契约时必须同步看这一行 |
| **R14** | BUG-12（"已连接但零产出"）**本轮不修**（team-lead 裁决，详见 §5.7） | — | 诊断信号本身是环境相关的、假阳性率未取证；拿未取证判据做硬失败 = 把"静默假成功"换成"静默假失败"。登记为下一轮单开任务，形态只能是诊断字段，**不得参与验收判定** |
| **R15** | 一条**已撤回**的归因曾写进本文（§5.7 ①） | 有人照"渲染子进程已死"去设计探针 | 该机制**不成立**（日志时间戳落在收尾 SIGTERM 时刻，运行期零错误）。凡看到"`page_renderer_dead`/渲染子进程死亡"的说法，一律以 §5.7 为准 |

### 变更清单（给 Engineer，逐文件）

| 文件 | 改动 | 类型 |
|---|---|---|
| `Resources/agent_mvmz.js` | 新增 `mergeBySkeleton`；`lookup` 三参并改实现；新增 `mapKeyOfSegments` 并让 `mapKeyOf` 变成薄壳；`processText` 只切一次段；`state.mergeFallback` + `probe()` 加键；改 30/67 行注释 | 逻辑 |
| `Sources/Adapters/Web/WebGameRunner.swift` | 106 行改返回值 + 107-112 新增门禁；`clearStaleSingletonLocks` 返回 `ProfileLockState`；新增 `ProfileLockState`（含两条 message 构造） | 逻辑 |
| `Sources/Domain/Models.swift` | 386 行后加 `profileLocked`；`uiMessage` 加一行 | 枚举 |
| `Sources/App/AttachCLI.swift` | `environmentCodes`（429-435）加 `.profileLocked` | 1 行 |
| `Tests/qa/lookup_variant_probe.mjs` | xfail → 表驱动硬门禁（C1-C8） | 测试 |
| `Tests/qa/final-sha256.txt` | 重新基线 | 测试 |
| `docs/archive/v0.2/architecture-v0.2-web-runner.md`（§9.1 表 + 1243 行的"不修"表述）、`docs/qa-report.md:137` | 状态更新 | 文档 |

**任务分组建议**（与团队既有 #3 对齐，不新增并行链路）：
- **T-fix-1（JS，P0）**：`agent_mvmz.js` 全部改动 + `lookup_variant_probe.mjs` 升级。仅依赖无。
- **T-fix-2（Swift，P0）**：`Models.swift` + `AttachCLI.swift` + `WebGameRunner.swift`。仅依赖无（与 T-fix-1 无交集，可并行）。
- **T-verify（QA，P1）**：`skip_parity.sh` + `store_probe.sh` + `--selftest` + §⑥ 构造 A/B/C + 反例 R1/R2 + 重跑 `play_e2e.sh` + 重新基线 sha256。

---

## ⑧ 待明确事项

| # | 事项 | 影响 | 建议 |
|---|---|---|---|
| Q1 | 真实 MV/MZ 下 `hookStartMessage` 原地改写 `_texts` 是否导致"译文被再翻译一次"（§④#8） | 只影响真实引擎，不影响本两项的验收 | 不阻塞本轮；QA 用 `--play` 真游戏 + `grep '"raw":"[^"]*[一-龥]'` 取一次证 |
| Q2 | `.unremovable` 硬失败的误报率 | 会挡住用户（比文案误导更难受） | **✅ 已裁决（team-lead）：两分支都硬失败，不做"仅 held 硬失败"的降级。**依据：`unremovable` 且 pid 已死时 Chromium 的 ProcessSingleton 同样会在 unlink 处 Abort（unlink 与 rename 同权限），早失败 + 精确文案优于让它起不来再报 5 因混杂的 `browser_exited_early`。**误报的证伪责任在 #4**：正常启动不得抛 `profile_locked`（§⑥ 反例 R1/R2）。**放弃原降级方案**（曾写"改动面 3 行"），Engineer 不要实现条件性放宽 |
| Q3 | `TextStreamStore.swift:165` 的译文列同型点（§④#6）要不要同轮修 | 只影响显示/导出 | **✅ 已裁决（team-lead）：本轮不修**，进交接文档下一版的已知问题清单；不在本轮扩大改动面。（若将来要修：按 §③ 同构实现 + 补 `merge_parity` 双端守门 —— 本工程"两套实现必然漂移"的教训） |
| Q4 | `profile_locked` 是否需要 GUI 侧的专门引导（弹一个"一键删锁"按钮） | UI 交互 | 本轮只做 CLI/错误码；GUI 那条路径 `SessionController.start` catch → `fail` → `lastError` → `MainWindow.sessionHeader` 已能显示 `code + message`（`docs/archive/v0.2/architecture-v0.2-web-runner.md:1108-1116`），不需要改 UI |
| Q5 | 是否加排障开关（如 `MOCHI_SKIP_PROFILE_LOCK_GATE=1` 跳过硬失败） | 逃生门 vs 新配置面 | **✅ 已裁决（team-lead）：不加。**未经验证的逃生门只会变成新的坑；逃生门仍只有已验证的 `MOCHI_DATA_DIR`（`Stores.swift:37-42`） |
| Q6 | `mergeFallback` 是否要上报给 Host（`emit('error', …)`） | 可观测性 | 首版只进 `probe()`（QA 可看）；不新增 Agent→Host 消息类型，避免动协议（§2.3 的结论同样适用） |

---

## 附：图（独立文件，避免覆盖既有 v0.1/v0.2 图）

- `docs/archive/v0.3/class-diagram-v0.3-fixes.mermaid`
- `docs/archive/v0.3/sequence-diagram-v0.3-fixes.mermaid`
