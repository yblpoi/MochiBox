# RGSS 数据层接线说明（RPG Maker XP / VX / VX Ace）

面向：把 Marshal 读写层接进"引擎识别 → 文本提取 → 写回"流程的人。
实现：Sources/Adapters/Marshal/（7 个文件，只 import Foundation）
验证：Tests/e2e/cases/contract/19_marshal.mjs（59 条断言，含 87 个真实文件往返）

## 1. 对外接口

| 接口 | 签名 | 用途 |
|---|---|---|
| 文件派发 | static func RGBSGameFile.detect(fileName: String, version: RGSSVersion? = nil) -> RGBSGameFile? | 扩展名定版本、文件名定 Kind（Map001 → .map(1)）；不认识返回 nil |
| 解析（磁盘） | static func RGSSDocument.load(url: URL, version: RGSSVersion? = nil, options: RGBSExtractOptions = .init()) throws -> RGSSDocument | 读盘 + 解析 |
| 解析（内存） | RGSSDocument(parsing: Data, file: RGBSGameFile, options: RGBSExtractOptions = .init()) throws | 已有字节时用，便于写回后复解析 |
| 取文本 | func textEntries() -> [RGBSTextEntry] | 按路径取出所有可翻译字符串 |
| 写回 | func serialize() throws -> Data | 序列化整棵树 |
| 自检 | func hasLosslessRoundTrip() throws -> Bool | 没改动时是否与源文件字节完全相同 |
| 选项 | struct RGBSExtractOptions { var defaultEncoding: RGBSTextEncoding?; var detectEncoding: Bool = true } | 编码兜底与覆盖 |

RGBSTextEntry 的成员：

- path: String —— 见第 3 节
- text: String? —— 按判定出的编码解码，失败为 nil
- raw: Data —— 原始字节（解码失败时也不要丢）
- encoding: RGBSTextEncoding —— .shiftJIS / .utf8 / .gb18030
- declared: MarshalEncodingIVar? —— 数据里原有的 :E / :encoding 声明
- node: MarshalValue —— 解析树节点；共享对象是同一实例
- func setText(_ newText: String, encoding override: RGBSTextEncoding? = nil) throws —— 编码失败抛 RGBSTextError.cannotEncode，原值保持不动

最小用法：

```swift
guard let doc = try? RGSSDocument.load(url: url) else { return }
for entry in doc.textEntries() where entry.path.hasSuffix(".name") {
    guard let text = entry.text else { continue }   // 解不出来先跳过，不要丢字节
    print(entry.path, text)
}
let data = try doc.serialize()   // 未改动 == 源文件
```

## 2. 编码判定

1. 字符串带 :E => true → UTF-8（RGSS3 常态；Ruby 2.x 对非 UTF-8 非二进制还会写 :encoding => "名称"，按名称映射）
2. 无 ivar → 版本默认：RGSS1/2 = CP932(Windows-31J)，RGSS3 = UTF-8
3. detectEncoding = true 时再猜一次：纯 ASCII → 用默认；**合法 UTF-8 且含多字节 → UTF-8**；否则默认能解就用默认；再否则依次试另两种
4. CP932 写不出的字符（简体中文）→ encode 返回 nil → 抛错，绝不静默写问号（M-WB-CP932 验证）

要点：

- CP932 与 Shift_JIS 不是一回事（①②③、㈱ 是 Windows 扩展）。解码先 CP932，失败再退回严格 Shift_JIS
- GB18030 自动猜测**不可靠**：CP932 往往"能解开"只是乱码。汉化版请显式传 defaultEncoding: .gb18030
- 第 3 条让"RGSS1/2 文件里混入 UTF-8 字节"也能正确显示（实测遇到过：有的工具直接写 UTF-8 而不转码）

## 3. 三版字段形状差异（照这张表写码表）

| 项 | XP (RGSS1 .rxdata) | VX (RGSS2 .rvdata) | VX Ace (RGSS3 .rvdata2) |
|---|---|---|---|
| 字符串 :E | 无 | 无 | 有（:E => true） |
| 默认编码 | CP932 | CP932 | UTF-8 |
| 用语表类 | RPG::System::Words | RPG::System::Terms | RPG::System::Terms |
| 用语表形状 | system.words.gold（扁平 20 个字符串 ivar） | system.terms.level_a（扁平 33 个） | system.terms.basic[0] / .params[0] / .etypes[0] / .commands["fight"] / .messages["level_up"]（数组 + 哈希） |
| Map ivar 数 | 11（实测） | 18（实测） | 18 + @display_name（无真实样本，按 VX 推） |
| Map @tileset_id | 有 | 无 | 无 |
| Map @display_name | 无 | 无 | 有 |
| Map 视差/滚动组 | 无 | 有（parallax_name/loop_x/loop_y/sx/sy/show、disable_dashing、scroll_type） | 同 VX |
| @bgm / @bgs 类 | RPG::AudioFile(ivar: volume/name/pitch) | RPG::BGM / RPG::BGS(ivar: name/pitch/volume) | 同 VX |
| MapInfos 结构 | Hash {地图 id => RPG::MapInfo} | 同 | 同 |
| Actor 文本字段 | name / description | name / description / nickname | name / nickname / description |

通用：

- EventCommand 三版同构：@code / @indent / @parameters；文本在 parameters 里，可能嵌套数组（102 的选项就是 [[...], n]）
- 消息相关 code：101 起消息、401 正文、102 选项、402 分支、404 结束选项、405 滚动文本
- **不要依赖 ivar 顺序**：同一个引擎里 XP 的 @bgm 是 volume/name/pitch，VX 是 name/pitch/volume。一律按名字查（RGSSRecordView.string("name") / ivar(named:)）

路径形态：

```text
actors[1].name                      1 基，数组第 0 位是 nil 占位
items[3].description
system.terms.commands["fight"]      哈希用键，不用序号
maps[1].events[1].pages[0].list[1].parameters[0]
common_events[2].list[1].parameters[0]
troops[1].pages[1].list[1].parameters[0]
map_infos[2].name                   MapInfos 是哈希
```

## 4. 对象链接表（最容易错的地方）

- Marshal 用 @<index> 回指同一对象，索引按**先序**分配（容器先登记自己，再写内容）
- 占索引的类型：String / Array / Hash / Object / UserDef / UserMarshal / Struct / Regexp / **Bignum / Float / Class / Module**
- 不占：nil / true / false / Fixnum / Symbol（Symbol 另有符号表，重复出现写 ;<index>）
- 后果：数组里出现一个 Float，后面所有 @ 编号整体后移一位；写回时必须按同样规则登记，否则链接全指错
- 解析树里共享对象是**同一个 MarshalValue 实例**（引用类型）：改一处两处都变，写回自动恢复成 @ 链接（M-LINK-01..04）
- Table 是 u: 的自定义序列化：payload = 5×int32 小端 [dim, xsize, ysize, zsize, n] + n×int16 小端。它不是 object，别按 o:Table 找

## 5. 已知边界与未验证清单

- **VX Ace 没有真实工程样本**：只有合成样本，字段形状按 VX 推（差一个 @display_name）
- **两个真实工程的事件层都是空壳**：@events{} 为空、EventCommand 只有 code=0。事件文本路径只由合成样本覆盖；对真实样本只断言结构与往返
- Scripts.* 一律不解析不提取（zlib 压缩的 Ruby 源码，不是翻译目标），只保证能跳过且往返不变
- 真实样本里没有 Struct / UserMarshal / Regexp 的用例，这三类只有自造语料覆盖（24 个结构化样本）
- RGSS1/2 的简体中文：CP932 表达不了。要中文就整文件按 GB18030/UTF-8 处理，不要逐字段混编码
- 性能未压测：真实样本最大 194 KB；60 MB 级地图文件（VX 100x100x3 只是 30 KB 的 Table）尚未测过

## 6. 与 LCF 层的差异（不要试图统一）

| | LCF（RM2000/2003） | RGSS（XP/VX/VX Ace） |
|---|---|---|
| 路径 | actors[0].name（0 基，无占位） | actors[1].name（1 基，第 0 位是 nil） |
| 哈希 | 基本没有 | 大量使用：commands["fight"]、events[1] |
| 数组语义 | 数据库记录顺序 | Ruby 数组，nil 占位是真实结构 |
| 写回粒度 | 字段级 patch | 整棵树序列化后整文件替换 |

RGSS 的路径是 Ruby 数据结构的直接投影；统一成 LCF 风格会丢掉"第 0 位是 nil""事件按 id 索引"这些信息。

## 7. 测试与 fixture

- 用例：Tests/e2e/cases/contract/19_marshal.mjs（编译 Sources/Adapters/Marshal/*.swift + 19_marshal_probe.swift，产物落 mkdtemp）
- Level-1 外部真实样本：Fixtures/rmxp-real（OpenXP, MIT）、Fixtures/rmvx-real（rgssad-rs, Apache-2.0 OR MIT）
- Level-2 合成样本：Fixtures/rmxp|rmvx|rmvxace，重生成 ruby Scripts/gen_rgss_fixture.rb（幂等）
- 断言口径：解析 → 序列化**字节完全相同**；整数编码逐字节对照 ruby 的 Marshal.dump；畸形输入必须返回错误而不是崩
