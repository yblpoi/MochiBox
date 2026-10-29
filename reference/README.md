# reference/ — 逆向与实测素材（不入库）

本目录存放**只在本机使用**的大体积素材：它们是分析的输入与实测的对象，
不是产品代码的一部分，因此被 `.gitignore` 排除，仅本文件入库。

| 路径 | 内容 | 体积 | 用途 |
|------|------|------|------|
| `apk/` | `mtool_v55_24.apk`、`mtool_mkxpz_v65_1.apk`、`mtool_renpy_v59_1.apk`、`mtool_easyrpg_v10000_1.apk`、`winlator_v3.1.71_1.apk` | 约 2.3 GB | 逆向对象（Android 发行版）与运行环境参照 |
| `pc/MTool.zip` | MTool PC 版 | 151 MB | 逆向对象（桌面版，注入方式的主要参照） |
| `extracted/apk/` | `AndroidManifest.xml`、`classes.dex`、`lib/` | 约 8 MB | 上述 APK 的解包产物 |
| `extracted/pc/` | `MTool/`、`runtime/` | 约 226 MB | `MTool.zip` 的解包产物（含 JS runtime） |
| `test-games/<示例作品>/` | RPG Maker **MV 1.6.1** 作品（`www/js/rpg_core.js`） | 846 MB | 真机链路的实测样本（启动先播 OP，播完才进标题） |

## 约定

- **不要**把这里的文件移回仓库根目录；根目录只留代码、文档与构建脚本。
- **CLI 不解析作品名**：`--play` 只接受文件系统路径，必须传**绝对路径**（或含 `index.html` 的作品根），
  写 `--play RJxxxxxx` / `--play <示例作品>` 都会直接失败。
- 两个测试入口用环境变量覆盖默认值：`MT_E2E_GAME=/abs/path`（`Tests/e2e/play_e2e.sh`）、
  `MT_AC8_GAME=/abs/path`（`Scripts/ac8_capture.sh`）。两者的默认值仍指向已不存在的 `RJxxxxxx`，**必须显式设置**。
- 解包产物是可再生的：`extracted/` 删掉后可按需重新解包，不必备份。
- 结论与证据写在 `docs/re-findings.md`，不要写在本目录。
- 新增大文件前先确认它是否属于「输入素材」；属于就放这里，不要进 Git。
