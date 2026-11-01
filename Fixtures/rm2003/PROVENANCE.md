# 样本来源（RPG Maker 2003）

这里的文件**不是本项目编写的内容**，是第三方开源测试工程的原始数据，原样入库只为让
`Tests/e2e/cases/contract/18_lcf_extract.mjs` 能对着**真实**的 LCF 二进制跑断言
（合成样本覆盖不到真实的字段布局、编码混排、事件指令嵌套与控制码）。

## 上游

| 项 | 值 |
| --- | --- |
| 仓库 | https://github.com/EasyRPG/TestGame |
| commit | `4bbedb73492c80b79d8290e0b06ea86875b0bdc8`（master 于 2026-11-01 取） |
| 目录 | `TestGame-2003/` |
| 许可证 | GPL-3.0（上游仓库根 `COPYING`） |

## 文件

| 文件 | 大小 | sha256 |
| --- | --- | --- |
| `Map0001.lmu` | 8 KB | `7a18ef96def5666eb0b8e76ae271d01cb2d23706f51e8bbc9a5f1848e2ba5825` |
| `Map0002.lmu` | 12 KB | `4bbe4b2ab14b09a46738c1073e2148fb5c38ee2fba588e9c20d19f7b9c122ddb` |
| `Map0003.lmu` | 1 KB | `aee1ca3c3dd1b9c6c9ec44b42bd12fc3815c605d9cfbacf89e3984d57696abc1` |
| `RPG_RT.ini` | 94 B | `4876d7ee2381206aa234984797dd51f6caf7be90753ff2fb5a5f1aecc1a3a4b1` |
| `RPG_RT.ldb` | 407 KB | `086dadfeeac35cb72a40742a759da60ec5377b0f06ab332d45783200999bb7a5` |
| `RPG_RT.lmt` | 2 KB | `35ff18ceda8ce13a613ad7f9088a3a7bfa88a86505833c7e953fd07b996cc1e0` |

三类文件各自验什么：

- `RPG_RT.ldb` —— 数据库：反射字段路径、版本判定（`system.ldb_id`）、按路径写回、ldb_id 写回保护。
- `RPG_RT.lmt` —— 地图树：mapID 列表（EasyRPG 的 `mapNNNN.po` 编号来源）与地图名文本。
- `Map0001~0003.lmu` —— 地图：`events[N].pages[M].event_commands[K].string` 的对话。
  2003 的地图事件里同样有事件指令文本与地图名，可与 2000 的样本对照版本差异。

获取方式（逐文件直取，没有把 54MB 的上游仓库整个克隆进来）：

```bash
BASE="https://raw.githubusercontent.com/EasyRPG/TestGame/4bbedb73492c80b79d8290e0b06ea86875b0bdc8/TestGame-2003"
for f in RPG_RT.ldb RPG_RT.lmt RPG_RT.ini Map0001.lmu Map0002.lmu Map0003.lmu; do
  curl -fsSL -o "$f" "$BASE/$f"
done
```

## 约束

- **仅测试数据**：不参与任何编译产物，不会被拷进 `MochiBox.app`。
- **不改动内容**：文件保持上游字节原样；测试里的写回一律落到临时目录。
- **不含游戏素材**：只有数据表（文本 / 地图树 / 地图 / 运行配置），没有图像与音频
  （实测：ldb/lmt/lmu 里没有一张 PNG/BMP/OggS/RIFF，只有素材文件名）。
- GPL-3.0 全文见 `../rm2000/LICENSE-GPL-3.0.txt`（同源同一份 GPL-3.0，只存一份）。
