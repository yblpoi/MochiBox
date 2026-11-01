# Fixtures

测试用的数据与替身。三类东西，来历完全不同，别混：

| 目录 | 来历 | 许可证 |
| --- | --- | --- |
| `mv_stub/`、`e2e_game/`、`mock_*.mjs` | 本项目自己写的合成替身（测试页、假后端） | AGPL-3.0（同本仓库） |
| `rmxp/`、`rmvx/`、`rmvxace/` | 本项目合成的最小工程（`Scripts/gen_rgss_fixture.rb` 生成） | AGPL-3.0（同本仓库） |
| `rm2000/`、`rm2003/` | 第三方开源测试工程 EasyRPG/TestGame 的**原始数据** | GPL-3.0，见各目录 `PROVENANCE.md` |
| `rmxp-real/`、`rmvx-real/`、`rmvxace-real/` | 第三方开源工程的**真实数据文件**（OpenXP / rgssad-rs / Jimicization-Project） | MIT / Apache-2.0 或 MIT / CC0-1.0，见各目录 `PROVENANCE.md` |

## 第三方数据说明（RPG Maker 2000 / 2003）

`rm2000/` 与 `rm2003/` 里的 `RPG_RT.ldb` / `RPG_RT.lmt` / `RPG_RT.ini` / `Map0001~0003.lmu` 直接取自
[EasyRPG/TestGame](https://github.com/EasyRPG/TestGame)（commit
`4bbedb73492c80b79d8290e0b06ea86875b0bdc8`），字节原样、未做任何修改。

- **仅测试数据**：不参与编译，不会进入 `MochiBox.app`；只有
  `Tests/e2e/cases/contract/18_lcf_extract.mjs` 读它们。
- **GPL-3.0**：与上游仓库一致，全文见 `rm2000/LICENSE-GPL-3.0.txt`。上游是测试
  工程而不是游戏，这两个目录里只有数据表（文本 / 地图树 / 地图 / 运行配置），没有图像与音频。
- 每个目录的 `PROVENANCE.md` 记了逐文件 sha256 与可复现的下载命令。

## 第三方数据说明（RPG Maker XP / VX）

| 目录 | 上游 | 许可证 | 收录 |
| --- | --- | --- | --- |
| `rmxp-real/` | [aphadeon/OpenXP](https://github.com/aphadeon/OpenXP) | MIT（`LICENSE-OpenXP.txt`） | `Data/*.rxdata` 15 个 |
| `rmvx-real/` | [nathaniel-daniel/rgssad-rs](https://github.com/nathaniel-daniel/rgssad-rs) | MIT **或** Apache-2.0（上游双许可，可任选其一；两份全文都在本目录） | `Data/*.rvdata` 14 个 |
| `rmvxace-real/` | [caynine9/Jimicization-Project](https://github.com/caynine9/Jimicization-Project) | CC0-1.0（`LICENSE-CC0.txt`） | `Data/*.rvdata2` 27 个 + `Game.ini` / `Game.rvproj2` |

commit 与逐文件 sha256 **只在各目录的 `PROVENANCE.md` 维护**，这里不复制——同一份事实存两处，
上游一改 commit 就会有一处先过期。

- **`Scripts.rxdata` / `Scripts.rvdata` 一律不入库**。两条理由：① 它们是 Ruby 源码压缩包
  （XP 109 KB、VX 108 KB），不是翻译目标；② XP 的默认脚本是 Enterbrain 的内容，上游仓库的
  MIT 覆盖不到它，放进来就是在 AGPL 仓库里再分发第三方商业脚本。解析器对 `Scripts` 的覆盖
  用 `rmxp/`、`rmvx/` 里的合成占位（63 B / 63 B）；要跑真实默认脚本时，在 `/tmp` 现组目录
  喂给运行时，不落地到仓库。
- **只有数据表，没有素材**：两个上游目录都只含 `Data` 下的表文件，不含 Graphics / Audio。
  VX 那份走 Git LFS，实际字节从 `media.githubusercontent.com` 的 LFS 端点取得。
- **字节原样**：未做任何修改，用于「解析 → 序列化 → 字节完全相同」的往返验证。
- **VX Ace（RGSS3）有真实样本了**：`rmvxace-real/` 取自 CC0-1.0 的
  [caynine9/Jimicization-Project](https://github.com/caynine9/Jimicization-Project)，是作者自建的
  1.02 工程（非 Enterbrain Sample Game）。它的事件层非空（236 条 101/401 对话文本），
  所以同时承担 Level-1 与部分 Level-2。合成工程 `rmvxace/` 继续保留，覆盖它没用到的事件类型。
- 逐文件 sha256 与下载命令见各自 `PROVENANCE.md`。
