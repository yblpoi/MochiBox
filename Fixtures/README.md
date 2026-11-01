# Fixtures

测试用的数据与替身。两类东西，来历完全不同，别混：

| 目录 | 来历 | 许可证 |
| --- | --- | --- |
| `mv_stub/`、`e2e_game/`、`mock_*.mjs` | 本项目自己写的合成替身（测试页、假后端） | AGPL-3.0（同本仓库） |
| `rm2000/`、`rm2003/` | 第三方开源测试工程 EasyRPG/TestGame 的**原始数据** | GPL-3.0，见各目录 `PROVENANCE.md` |

## 第三方数据说明（RPG Maker 2000 / 2003）

`rm2000/` 与 `rm2003/` 里的 `RPG_RT.ldb` / `RPG_RT.lmt` / `RPG_RT.ini` 直接取自
[EasyRPG/TestGame](https://github.com/EasyRPG/TestGame)（commit
`4bbedb73492c80b79d8290e0b06ea86875b0bdc8`），字节原样、未做任何修改。

- **仅测试数据**：不参与编译，不会进入 `MochiBox.app`；只有
  `Tests/e2e/cases/contract/18_lcf_extract.mjs` 读它们。
- **GPL-3.0**：与上游仓库一致，全文见 `rm2000/LICENSE-GPL-3.0.txt`。上游是测试
  工程而不是游戏，这两个目录里只有数据表（文本 / 地图树 / 运行配置），没有图像与音频。
- 每个目录的 `PROVENANCE.md` 记了逐文件 sha256 与可复现的下载命令。
