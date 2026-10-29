# 对白翻译失效修复 · 交接文档（2026-10-27）

## 1. 根因

- `Resources/agent_mvmz.js:2405` 原为整句原子判据：一条消息任意一行查不到译文，整条保持日文。
- 流水线把 `？？？`/`……` 等纯标点行判为 punctuation 故意跳过，这些行永不进表；两条策略互相否决。
- 行级命中 10609/10822 = 98.03%，却放大成整句未译 231/5940 = 3.89%；开场 Map002 未译 36/36。

一句话：行级几乎全中，但"整条一起死"的判据把 1.97% 的行级缺口放大成 3.89% 的句级缺口，且在开场图这种纯标点行密集的地方放大到 100%。

## 2. 修复

- 8778dc7：`hookStartMessage` 改逐行独立写回，未命中行保留原文；`replacedTextsByIndex` 语义不变。
- 效果（运行态 231 基线）：未译 231 → 69；增益 162 条消息 / 199 行；Map002 已译 0/36 → 31/36；Map015 1/25 → 23/25。
- 口径警告：`loadPersisted` 每次 attach 会 purge「译文=原文」条目，运行态基线是 231；未 purge 快照（5515 条）为 210 → 69。任何复算必须先冻结快照并注明是否已 purge。

约束保持不变：数组长度与转义码位置不动，逐行写回只替换 `text` 段的译文，未命中的行原样保留——所以"整句退回日文"这个行为被降级成了"这一行退回日文"。

## 3. 验证

- contract 15/546、domain 14/373、kernel 14/165、faults 10/55、selftest 74/0/1。
- 关键测试设计：K14 判据钉在 `$gameMessage._texts` 而非 drawLog（绘制期 drawTextEx 自己也会查表替换，用渲染结果断言会在回退时仍绿）。
- 真机证据：开场 `ここは……` 实机显示「这里是……」；同条 `？？？` 未被改写。截图 /tmp/mochibox-run3/best.png。

第 2 条值得单独记住：任何"看屏上是不是中文"的断言都测不出这个 bug 的回退，因为渲染层自己会再查一次表，把 `_texts` 的日文补成中文。判据必须钉在替换完成后的内存结构上。

## 4. 官方补丁对照（逆向结论）

- 57MB `Game.exe` = 原版 nw.exe + Enigma Virtual Box（与 Gamejp.exe 差 56 字节 PE 头）；45MB 高熵段是 73 张重画 UI 图，非密文。
- 替换逻辑为 `DLsite_TranslationConvertMVMZ_v1_0_2.js`，零渲染 hook，在 `Scene_Boot.terminate`/`Scene_Map.start` 改 `$data*`；键为整段多行、零归一化。
- 键粒度：官方整段 99.9% / 单行 19.0%；MTool 整段 24.7% / 单行 99.5%。本仓库按行是正确的，不要改成整段。

官方能按整段做，是因为它的语料是人工补的整段译文，覆盖 99.9%；本仓库的语料来自按行抽取的机器翻译，单行 99.5% 而整段只有 24.7%。照抄官方粒度会把命中率打到四分之一，这条不要"对齐官方"。

## 5. 五项后续（按优先级）

### P0-1 全文下发失败不重试且被记成成功

- 现象：`SessionController.swift:496-512` 首片失败即 return，后续分片全丢；`FullTextController.swift:944` 仍写 lastPushedCount 并打「已下发」，之后非 force 的 pushAll 被短路。
- 后果：一次 attach 失败 = 整场无译文（菜单也不中文）。
- 修法：send 返回成败；失败不写 lastPushedCount、notice 改失败文案；整份指数退避重试（分片幂等）；重试需带会话代次，避免旧失败在新会话重放。

### P0-2 双 launch 竞态 + adapter 被输家覆盖

- `SessionController.swift:222/226-233/267-268`、`GameLauncher.swift:304/321/523`；状态闸只读枚举，不是 single-flight；`self.adapter` 在 launch 成功前发布，输家覆盖赢家 → `attach_failed：尚未注入 Agent`。
- 修法：start 加在飞标记 + sessionGeneration，defer 复位；GameLauncher 加 launchingWebRoots 同 webRoot 去重；self.adapter 延后到 attach 成功再赋值，fail/stop 只作用于本 flow 的 adapter。

### P2 握手期丢弃 error 信封

- `AgentInjector.swift:226-230` 计数后不重放；被丢的正是首条 `start_message_*` 诊断，而闸门是「首条立即报」。
- 修法：error 也 append 进 backlog，出握手后回灌。顺带建议 pushAll 后打一行 `probe().mapSize`，把「表进没进页面」变成日志证据。

### 体验 首次启动授权弹窗

- 首次访问「下载」目录弹系统授权，未点允许前启动静默卡住，无 stderr、无 .ips、无会话日志。
- 建议：启动前检测并给出可操作提示，或把授权失败落到日志。

### 加固 repair 后的二次 guard

- `FullTextController.swift:459` 的 guard 在 `repairGlossaryViolations()`（:465）之前；attach 落在 repair 期间时，:491 `saveGlossaryIfDirty()` 与 :492 `pushAll()` 无二次代次校验。今天无数据风险（glossaryDirty 已置 false、repair 改不脏、旧 targets 在新语料为 nil），但属「靠推理才安全」。
- 修法：:491 前补 `guard epoch == attachEpoch else { return }`（约 5 行，零行为变化）。crossgame 与 verify 独立建议补。

## 6. 交付边界

- 本轮共 21 个提交，全部在本地分支，推送目标 origin/fix/sample-portrait-black-freeze（注意：该分支原属上一个任务，本轮改动与其混在同一分支）。
- 真机验收用的产物是按 `bd6171e` 用 git worktree 干净构建的 `/tmp/mochibox-head/build/MochiBox.app`；`build/` 下另有一个含未提交改动的旧产物，勿用于验证。

## 7. 复现与验证命令

- `bash Tests/e2e/run.sh --suite contract` / `--suite domain` / `--suite kernel` / `--suite faults`；注意 **domain 含 D9 会启动 MochiBox.app**，与真机验收不可同时进行。
- 离线复算需先冻结 `~/Library/Application Support/MochiBox/fulltext/<gameHash>.json` 并注明条目数与是否已 purge。
