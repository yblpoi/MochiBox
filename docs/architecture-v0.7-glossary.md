# V0.7 设计：术语资产表与全文翻译质量

> 状态：当前有效（实现已落地，验收见 `Tests/e2e/cases/domain/10_glossary.mjs`）

## 1. 要解决的问题

全文翻译把「技能名 / 道具名 / 系统术语」和「对话 / 描述」放进同一个提示词，只有一条规则：
"逐条翻译、保持数组长度与分段数"。后果：

- 同一个词在不同批次被译成不同名字（HP → "HP" / "生命值" / "体力"）；
- 技能名被译成解释性短语，物品名带句号；
- 纯 ASCII 术语（HP/MP/TP/EXP/Lv）在扫描时被 `scanCandidate` 丢弃，运行期却会单独送模型；
- 改提示词后旧缓存仍然命中，用户看不到改善（缓存键不含 prompt）。

## 2. 三层方案

### 2.1 锁定映射（零请求）

```
术语整串命中 → 直接写回，不送模型
```

- 内置种子（`GlossarySeed`）：只收能核对的官方默认日文术语；`レベル→等级`、`経験値→经验值`、`所持金→持有金钱`；HP/MP/TP/EXP/Lv 标 `keepAsIs`（回填输入原文，不改写大小写）。
- 每游戏术语表（`glossary/<gameHash>.json`）：用户在「全文 → 术语」页编辑，或从 `{原文:译文}` JSON 导入。
- 扫描启动时 Agent 在 `text.scanStart` 的 ack 里带回 `$dataSystem.terms.*`（**不走 scanCandidate**，所以 HP 与单字术语不会丢）：纯 ASCII 的进 `keepAsIs`，其余等语料翻完后学习。
- 名称类条目翻完立即 `learn` 进表，后续描述/对话批次自动带上。

### 2.2 分类提示（约束模型）

扫描时按 `source` / `path` 推导 `TranslationCategory`：

| 类别 | 来源 | 提示规则 |
| --- | --- | --- |
| `systemTerm` | `system.terms.*` / currencyUnit / 类型名 | 对齐官方中文；HP/MP/TP/EXP/Lv 保留 |
| `entityName` | `skill/item/.../N.name` | 2–8 字、不加括号/句号 |
| `place` | `mapInfo.N.name` | 简短地名 |
| `description` | `.description` / `.profile` | 保留句式、不补主语 |
| `dialogue` / `other` | 事件文本 / 未知 | 口语化 |

- 翻译顺序按 `category.rank` 排序：系统术语 → 名称 → 地名 → 描述 → 对话。**不增加任何模型调用**。
- 每批只注入本批出现过的术语（≤40 条 / ≤1200 字）；keepAsIs 单独成段（"以下词保持原文"）。
- keepAsIs 不参与子串注入以外的改写；**产品语义不做运行时文本替换**（中日文无词边界）。

### 2.3 译后校验（只标记）

`FullTextQuality` 标五类问题，不自动重试：

- `placeholder_lost`：`%1` 多重集不一致；
- `kana_left`：中文译文残留假名；
- `identical`：译文 == 原文（术语短路条目抑制）；
- `glossary_violation`：锁定术语的译名没出现；
- `length_anomaly`：过短/过长。

UI 的「语料」页有「只看质量问题」筛选，行尾显示警告图标。

## 3. 缓存与重翻

- `cacheKey = sha256(engine|src|tgt|profile|normalize(text))`；**profile 为空时与旧公式逐字节相同**，升级不导致全量失效（有字面量测试）。
- `profile = p2|c:<category>|g:<本条命中的术语束哈希>`（只算本条用到的术语，改一个词只影响包含它的句子）。
- `.other` 与 `.dialogue` 归一到同一桶：从落盘加载的条目 path 已丢失，避免永远命中不了实时缓存。
- 全文与实时共用 `TranslationProfile.id`；实时优先用全文扫描时判定的类别（`categoryByTextKey`），重启后从 `FullTextFile.categories` 恢复。
- 「按术语重翻」只清 `origin != .manual` 且 profile 过期的条目；人工译文一条不动。
- 落盘新增四个可选 map：`origins` / `profiles` / `issues` / `categories`（旧文件缺省即可）。
- `origin` **必须**落盘：否则重启后人工译文变 `.cache`，重翻会静默覆盖用户导入的译文。

## 4. 关键文件

| 文件 | 职责 |
| --- | --- |
| `Sources/Domain/GlossaryModels.swift` | 术语模型、类别、归一/匹配、`GlossaryBox` |
| `Sources/Domain/GlossarySeed.swift` | 内置种子（Swift 常量，不改打包） |
| `Sources/Infra/GlossaryStore.swift` | 每游戏术语文件、导入导出、损坏隔离 |
| `Sources/Domain/FullTextQuality.swift` | 五类质量标记 |
| `Sources/Infra/Translators.swift` | 目标语言 + 类别规则 + 术语注入（system message） |
| `Sources/Domain/FullTextController.swift` | 排序、整串短路、学习、校验、重翻 |
| `Sources/Domain/SessionController.swift` | 实时短路、共享 profile、类别回填 |
| `Sources/UI/FullTextPanel.swift` | 语料 / 术语子页、质量筛选、重翻 |

## 5. 已知边界

1. **DeepL** 没有 system prompt：术语与类别通过 `context` 传，best-effort；UI 已标注约束弱于 OpenAI 兼容后端。
2. 实时流只有「扫描到过的句子」能拿到正确类别；没扫过的一律按 `.dialogue` 处理（同句可能多花一次请求）。
3. 术语保存瞬间，已经在飞的旧结果可能晚到并覆盖一次 → 下一次重绘自愈（没有实现 superseded 状态机）。
4. `System.terms.messages` 是模板句（`%1は%2のダメージ`），运行时画的是代入后的实例，模板译文永远不会命中；本轮只做 `%N` 保真校验。
5. 用户删掉的术语会写墓碑，重启不复活；「恢复内置」清空墓碑（用户删掉的已学词会重新学回来）。
6. 自动学到的资产名会落盘（`kind = asset/actor/place`），系统术语每次启动由种子 + 扫描重建。
