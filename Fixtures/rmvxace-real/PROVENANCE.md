# Fixtures/rmvxace-real 来源与许可

本目录是**第三方开源工程的真实 RPG Maker VX Ace（RGSS3）数据文件**，不是游戏素材，
只用于验证 Marshal 4.8 解析/写回在真实 Ace 数据上的行为，并补上"VX Ace 没有真实样本"的缺口。

- 来源仓库：https://github.com/caynine9/Jimicization-Project
- 快照 commit：`70b397b9339bc4b1e19483621ef4ac1d57e81b5f`（`main` 分支 HEAD，2023-03-16）
- 抓取日期：**2026-11-02**
- 抓取方式：`git clone --filter=blob:none --sparse --depth 1` 后
  `git sparse-checkout set PJSRH/Data`，再与仓库根 `LICENSE` 一起取回。
- 路径：`PJSRH/Data/*.rvdata2`、`PJSRH/Game.ini`、`PJSRH/Game.rvproj2`
- 许可：**CC0 1.0 Universal**（仓库根 `LICENSE`，全文见同目录 `LICENSE-CC0.txt`）。

## 许可核实的证据（2026-11-02）

1. 仓库根只有一份 `LICENSE`，内容为 CC0 1.0 Universal 全文（与本地
   `LICENSE-CC0.txt` 逐字节 `cmp` 一致）。
2. 默认分支 `main` 的根目录清单：`PJSRH/`、`LICENSE`、`README.md`，**没有**单独的
   `NOTICE` / 附加条款文件。
3. `PJSRH/Data/` 下只有 28 个数据文件，**没有**独立的 LICENSE / NOTICE / README。
4. `README.md` 没有"许可仅覆盖代码"之类的限定；仓库页面标注的许可证也是 CC0-1.0。
5. CC0 正文在 "Copyright and Related Rights" 里明确列出
   "the right of extraction, dissemination, use and reuse of data in a Work" 与
   "database rights"，即数据表本身也在弃权范围内，不存在"只覆盖代码"的问题。

结论：CC0-1.0 覆盖**整个仓库**（含 `PJSRH/Data` 下的数据文件），可以入库。

另有一条支持"剔除 Scripts.rvdata2"的事实：`README.md` 的 Resources 节自己列了第三方脚本
`Basic Quest System v1.1a by Vlue`。脚本集里混有非作者代码，正是不入库的理由之一。

## 工程来源

作者自建的 VX Ace 1.02 工程（`Game.rvproj2` 内容为 `RPGVXAce 1.02`），
**不是** Enterbrain 官方 Sample Game，也不含 RTP 素材（本目录只有数据表，没有
Graphics / Audio / Fonts）。

## 收录内容

`Data/` 下 27 个 `.rvdata2`（469,875 B）+ 根目录 2 个工程文件（186 B），
合计 **470,061 B（约 459 KiB）**：

| 文件 | 字节 | sha256 |
| --- | ---: | --- |
| Actors.rvdata2 | 2388 | 058b96143e3f242ca893d10a5fc683869f093e617d1cb090a5e59f3f654a9e1c |
| Animations.rvdata2 | 218370 | 3744cffbc25e0eb290d6c2dded069e989e2e8d628edf6b03f9dcab59501744ad |
| Armors.rvdata2 | 10555 | 8169d47f0a0efc733daedd6749fc43d853977bb935dc52725e6895b65325fda5 |
| Classes.rvdata2 | 21046 | c5eb921b252b08e81670fcbdf7346d8b7cca297f6d93464b575c75d4b496fa74 |
| CommonEvents.rvdata2 | 552 | 5c21b4d871a51814cb98169a49b44c38c68c8645c83d89ece6568c3a8456cbdc |
| Enemies.rvdata2 | 11144 | 7b35ac0b0e97a2fa4d7abae5912ee5be7cfebef16a01511c97d734fa04946534 |
| Items.rvdata2 | 3331 | 688726d1aeedee514b9a2d8126dd62ef682829fe4f9d64a38bf24c6c56a41ef6 |
| Map001.rvdata2 | 6563 | 2cb594319000537eed64b48a22c88bb2d0a10cab546ba14f8d8b25bda05e00cc |
| Map002.rvdata2 | 6807 | 1310c64df3ea78cc0d7ad411f12b7ade819eb65bfada0b681f6e4c6e6edcc7c5 |
| Map003.rvdata2 | 7533 | 4890732f536230d40bc6191f37ea3fc0735e0445595e746c26b6b8f2e1de0092 |
| Map004.rvdata2 | 7569 | aba919dc1f5992363095d102c2c8272b9b62b72da9de6a155ce4a15b765084e2 |
| Map005.rvdata2 | 3747 | 4dfec3739d58dedf3664a0c18413f995e811ed2381ae8e30a70ede8f2adbe493 |
| Map006.rvdata2 | 9566 | 1cad0e8f4f59dbdbb2e4bf7f662798a43ddbf47ddac5736d6c67627ecaef59ac |
| Map007.rvdata2 | 4771 | 70ee8e4b00b4f3631feab59077f5e64ba486ee1d5ae54d6b8318199413c1bb13 |
| Map008.rvdata2 | 6493 | 333e0e2c24682e1384cce8871a02aa8c5af90371a322685328ce336034fa09e7 |
| Map009.rvdata2 | 4383 | 298ce2ce304742946d0a99b1bcd4b04450a1c6e9e5a9994f549832abcd856ad8 |
| Map010.rvdata2 | 4379 | 610749bdc39af1bc471a3465d45c3aed050cee539cf1fa049e84cf76aa8ea162 |
| Map011.rvdata2 | 4537 | 0559c2e6a47fdd9288b10c6dac4704c50da766d0a790fd4c8a919e9572330de9 |
| Map012.rvdata2 | 9819 | 16f0c5b0f95a4747fe69a41cccf120953b3db5aa168b547a49fc3ef2ff374118 |
| Map013.rvdata2 | 2245 | 55696ef571f0e57b1d4f177786d540651832d0a892eaa23d0acd70744b4a67c4 |
| MapInfos.rvdata2 | 663 | d4062cda545cd4b97c91c0e97be1b1b17e76aa9830ec9077bed34eb3c9ec5a7f |
| Skills.rvdata2 | 30425 | 2e21a26662e664c4ac2e2adee701172da7f91c9aa40e443dd82d9d5e30c802f2 |
| States.rvdata2 | 4961 | 8f88505af04df808d53993537e3b9be4380bdabce79917fa29ceafd3df83feb9 |
| System.rvdata2 | 4389 | f25455524a0c12d16d6b1d3bfbaee15bae2a4cb3cacd9d32ba53c10cda76f6c7 |
| Tilesets.rvdata2 | 66326 | 268d3cf09bae9d20dea91b239ce1c9587dfcf45497560cf277235e567918f44b |
| Troops.rvdata2 | 4959 | e4e23a3efc793b469eb3cd6042a7944ec43890f5a8ebc9610da1a96020525a26 |
| Weapons.rvdata2 | 12354 | 5202e83cc20c0b4367f4da2a87d3692db8e38a3d227a442c1af81db29fd0ea08 |
| Game.ini | 173 | f29221f942edb5645e176680dcfcdcd0fc47e88491ddd303da3357dc143bdf70 |
| Game.rvproj2 | 13 | 4076754b3396c079b1b1978acf564a980c5d3ef445f6a92af009e302c1d656a2 |

- **未收录**：`Scripts.rvdata2`（143,430 B 的 Ruby 源码压缩包，含第三方脚本；
  不是翻译目标；上游 README 也自述引用了 Vlue 的 Quest System）。
- 也未收录 `Game.exe` / `System/RGSS301.dll` / `Graphics` / `Audio` / `Save01.rvdata2`——
  **本目录没有任何媒体素材**，图片与音频一个都没有。
- **字节原样**：2026-11-02 对稀疏克隆的同一 commit 逐文件 `cmp`，上表 29 个文件全部一致；
  未做任何字节修改。用途就是"解析 -> 序列化 -> 字节完全相同"的往返验证。

## 覆盖层级：Level-2（有真对话，但仍是测试工程）

与 XP / VX 两份真实样本不同，**这份工程的事件层不是空壳**：

- 13 张地图共 236 条事件指令文本（101/401 对话为主），是印尼语的原创剧情文本
- `@events` 非空（Map001 有 1 个事件）
- 数据库层 / 用语表都是真文本：全工程 1463 条文本条目

因此本目录可以同时承担 Level-1（结构 + 往返）与部分 Level-2（真实对话路径）断言。
但**不要**拿它当"覆盖所有事件指令类型"用：它只用到 101/401 这一类。

## 实测到的 RGSS3 形状与浮点怪癖（本样本的价值之一）

`System.rvdata2` 的 `@terms` 是**容器形态**：`@basic`(8) / `@params`(8) /
`@etypes`(5) / `@commands`(24) 四个数组；本样本没有 `@messages`。
首元素实测值：`basic[0]="Level"`、`params[0]="MaxHP"`、`etypes[0]="Senjata"`、
`commands[0]="Lawan"`。

`Map001.rvdata2` 的 `RPG::Map` 有 24 个 ivar（VX 是 18，XP 是 11）：
在 VX 的 18 个之外多 `@display_name` / `@specify_battleback` / `@battleback1_name` /
`@battleback2_name` / `@note`，并保留 `@tileset_id`。

`Armors / Classes / Enemies / States / Weapons / Skills` 里的 `Float` 不是标准 MRI 写法：
`f` 后面声明的长度比 `%0.17g` 文本多 3 字节，正文形如
`"0.80000000000000004" + 00 99 9a`。MRI 的 `Marshal` 用 `strtod` 解析浮点文本，
遇到 NUL 就停，所以真 Ruby 能正常读（已实测：用 `Marshal.load` + 桩类把 28 个文件全部加载成功）。

这 6 个文件当初让 `Sources/Adapters/Marshal` 直接报 `badNumber`。修复方式是按同样口径取
"能解析的前缀"，同时保留整段原始字节用于写回，做到字节级往返。**合成样本复现不出这个问题**——
这正是真实样本存在的理由。
