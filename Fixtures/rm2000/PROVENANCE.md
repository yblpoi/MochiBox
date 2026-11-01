# 样本来源（RPG Maker 2000）

这里的文件**不是本项目编写的内容**，是第三方开源测试工程的原始数据，原样入库只为让
`Tests/e2e/cases/contract/18_lcf_extract.mjs` 能对着**真实**的 LCF 二进制跑断言
（合成样本覆盖不到真实的字段布局、编码混排、事件指令嵌套与控制码）。

## 上游

| 项 | 值 |
| --- | --- |
| 仓库 | https://github.com/EasyRPG/TestGame |
| commit | `4bbedb73492c80b79d8290e0b06ea86875b0bdc8`（master 于 2026-11-01 取） |
| 目录 | `TestGame-2000/` |
| 许可证 | GPL-3.0（上游仓库根 `COPYING`） |

## 文件

| 文件 | 大小 | sha256 |
| --- | --- | --- |
| `Map0001.lmu` | 8 KB | `087ce023e23d831df0c0e60e4b8a3bd8e507c2e3809e17e564fcae7b4b9a8a0d` |
| `Map0002.lmu` | 9 KB | `d7409be2742484dd67f5027fee2a41649d18e40e73f977c61a175bc557e9e4af` |
| `Map0003.lmu` | 3 KB | `1988801dfcd833b7b7bb86bcb550ba7e60d2d2152679b184b7fca05c7b310840` |
| `RPG_RT.ini` | 94 B | `fc24367b13002e4dd9398322ded08f4db2a10257396b476d3d77ad4fe9719fff` |
| `RPG_RT.ldb` | 205 KB | `9728e783c05540badd7d2939916e02b789d4079bd9f85759d9dbe67fda1ee123` |
| `RPG_RT.lmt` | 6 KB | `72329f51dbb1bc667c07fbcba5358e5717e6eca6be9ec50f2f235d2bce0a8c64` |

三类文件各自验什么：

- `RPG_RT.ldb` —— 数据库：反射字段路径、版本判定（`system.ldb_id`）、按路径写回、ldb_id 写回保护。
- `RPG_RT.lmt` —— 地图树：mapID 列表（EasyRPG 的 `mapNNNN.po` 编号来源）与地图名文本。
- `Map0001~0003.lmu` —— 地图：`events[N].pages[M].event_commands[K].string` 的对话。
  其中 Map0001 含 176 条带 `\s[1]`…`\s[7]` 换字号控制码的测试消息，是「控制码不得被剥掉」的现成回归样本。

获取方式（逐文件直取，没有把 54MB 的上游仓库整个克隆进来）：

```bash
BASE="https://raw.githubusercontent.com/EasyRPG/TestGame/4bbedb73492c80b79d8290e0b06ea86875b0bdc8/TestGame-2000"
for f in RPG_RT.ldb RPG_RT.lmt RPG_RT.ini Map0001.lmu Map0002.lmu Map0003.lmu; do
  curl -fsSL -o "$f" "$BASE/$f"
done
```

## 约束

- **仅测试数据**：不参与任何编译产物，不会被拷进 `MochiBox.app`。
- **不改动内容**：文件保持上游字节原样；测试里的写回一律落到临时目录。
- **不含游戏素材**：只有数据表（文本 / 地图树 / 地图 / 运行配置），没有图像与音频
  （实测：ldb/lmt/lmu 里没有一张 PNG/BMP/OggS/RIFF，只有素材文件名）。
- GPL-3.0 全文见 `LICENSE-GPL-3.0.txt`（本目录）。
