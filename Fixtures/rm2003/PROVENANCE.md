# 样本来源（RPG Maker 2003）

这里的文件**不是本项目编写的内容**，是第三方开源测试工程的原始数据，原样入库只为让
`Tests/e2e/cases/contract/18_lcf_extract.mjs` 能对着**真实**的 LCF 二进制跑断言
（合成样本覆盖不到真实的字段布局、编码混排与事件指令嵌套）。

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
| `RPG_RT.ldb` | 407 KB | `086dadfeeac35cb72a40742a759da60ec5377b0f06ab332d45783200999bb7a5` |
| `RPG_RT.lmt` | 2 KB | `35ff18ceda8ce13a613ad7f9088a3a7bfa88a86505833c7e953fd07b996cc1e0` |
| `RPG_RT.ini` | 94 B | `4876d7ee2381206aa234984797dd51f6caf7be90753ff2fb5a5f1aecc1a3a4b1` |

获取方式（逐文件直取，没有把 54MB 的上游仓库整个克隆进来）：

```bash
curl -fsSL -o RPG_RT.ldb "https://raw.githubusercontent.com/EasyRPG/TestGame/4bbedb73492c80b79d8290e0b06ea86875b0bdc8/TestGame-2003/RPG_RT.ldb"
```

## 约束

- **仅测试数据**：不参与任何编译产物，不会被拷进 `MochiBox.app`。
- **不改动内容**：文件保持上游字节原样；测试里的写回一律落到临时目录。
- **不再分发游戏素材**：这三个文件是数据表（文本 / 地图树 / 运行配置），不含图像与音频。
- GPL-3.0 全文见 `../rm2000/LICENSE-GPL-3.0.txt`（两个版本同源同一份 GPL-3.0，只存一份）。
