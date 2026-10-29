# BUG-11 · Host 侧同型点修复记录（dev 分支）

**状态**：已修（dev 分支）　**基线**：`3151cb53b016babf…`（2026-10-22 10:47 干净重建）
**前置结论**：Agent 侧 BUG-11 已在 V0.3（`96a87474`）修复，探针 C1–C9 9/9。本文件只记录 **Host 侧**那一半。

## 一、缺陷本体

`cacheKey` 是**翻译身份**（剥码），同一句的多种画法共享它：

| 行 | raw | 行身份 | 翻译身份 |
|----|-----|--------|----------|
| A | `\N[1]は元気` | 唯一 | `は元気` |
| B | `\N[2]は元気` | 唯一 | `は元気` |

修复前 `TextStreamStore.applyTranslation` 把后端结果的**整串 raw** 扇出给所有同键行：

```swift
rows[index].translated = translatedRaw   // 先到行 A 的串，含 \N[1]
```

后果：UI 译文列、复制、JSONL 导出里，B 行显示成 `\N[1]…` —— **一个人名被画成另一个人**。
游戏画面不受影响（Agent 侧 `lookup` 已按本行骨架重组），所以这是**显示/导出的语义错误**，
比"不翻译"更严重：它看起来是成功的。

## 二、修法

`segments` 只当**译文文本段队列**用，`code` 段一律丢弃，再按**目标行自己的骨架**重组：

```text
rows[i].translated = merge(code 段取 rows[i].segments，text 段按序取译文)
```

- `rows[i].segments` 是该行 Agent 上报的真实骨架，**不重新 `splitSegments(raw)`**
  ——两端分段器只要有一处差异，重切就会算错段数。
- 文本段数与译文条数不符 → 该行落 `.error(segmentMismatch)`，`translated = nil`；
  **绝不回退到别的行的整串**（与 Agent 侧"宁可画原文，不串人名"同一裁决）。
- `translatedSegments` 用同一函数产出，保证显示串与导出段同源。

代码位置：

| 文件 | 改动 |
|------|------|
| `Sources/Domain/Segmenter.swift` | 新增 `translatedTextPieces` / `mergeBySkeleton` / `mergeSegments` |
| `Sources/Domain/TextStreamStore.swift` | `applyTranslation` 改为逐行骨架重组；无段证据时才整串回退 |
| `Sources/Domain/SessionController.swift` | `delivered` 去掉 `raw` 字段，只存译文段 + backend（消除"存首行整串"的入口） |

## 三、双端判据（必须逐值一致）

| 条件 | Agent `lookup` | Host `applyTranslation` |
|------|----------------|--------------------------|
| 有 `segments` 且文本段数相符 | 按本行骨架重组 | 按本行骨架重组 |
| 有 `segments` 但段数不符 | 画原文（不替换） | `.error(segmentMismatch)`，不显示译文 |
| `segments` 缺失/为空 | 回退 `translatedRaw`（v0.2 兼容） | 回退 `translatedRaw`（v0.2 兼容） |

差异只在后果：Agent 决定"画什么"，Host 决定"列什么"；两边都**不允许**借用别人的控制码。

## 四、验证（全部绑 `3151cb53`）

| 门禁 | 结果 |
|------|------|
| `--selftest` | **45 / 0**，exit 0 |
| `skip_parity.sh`（双端跳过判据） | **9 / 9**，exit 0 |
| `lookup_variant_probe.mjs`（打包内 agent） | **9 / 9**，exit 0 |
| `store_probe.sh` | **16 pass / 5 fail**（新增 S8a–d、S9a–c 全 PASS） |
| `play_e2e.sh`（真游戏 RJxxxxxx） | **11 / 0**，`PLAY_E2E_PASS`（AC-2 captured=4、AC-3 translated=3 replaced=3、AC-4 两次同端口 39366） |

`store_probe` 的 5 条失败是**改动前就存在**的（`S7` + `W1/W4a/W5/W6`，Store 时间窗口自保 OBS-1）：
同一脚本在 `03a1c71` 干净副本上跑出 **pass=9 fail=5**，失败集合完全相同，
新增的 7 条断言全绿 —— 即本改动零回归。

## 五、未覆盖 / 不在本次范围

- **AC-8 窗口模式**仍未取证（受管环境拿不到窗口证据），与本次改动无关。
- `store_probe` 的 S7/W 组（Store 自身没有 800ms 窗口）仍红，属 OBS-1，产品路径不可达。
- `Tests/qa/final-sha256.txt` 是 **V0.3 历史快照**（`96a87474`），不要拿它校验本分支二进制。

## 六、复现

```bash
bash Scripts/build.sh
./build/MochiBox.app/Contents/MacOS/MochiBox --selftest | tail -2
bash Tests/qa/store_probe.sh
bash Tests/qa/skip_parity.sh
node Tests/qa/lookup_variant_probe.mjs build/MochiBox.app/Contents/Resources/agent_mvmz.js
bash Tests/e2e/play_e2e.sh          # 约 5.5 分钟，需要真实游戏与 Chromium 内核
```
