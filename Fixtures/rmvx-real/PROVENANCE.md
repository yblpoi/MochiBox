# Fixtures/rmvx-real 来源与许可

本目录是**第三方开源工程的真实 RPG Maker VX 数据文件**（不是游戏素材），只用于验证
Marshal 解析/写回在真实数据上的行为。

- 来源仓库：https://github.com/nathaniel-daniel/rgssad-rs
- 提交：9cbd8a7e69143c157e87da3cff14b6ffad300c88
- 路径：rgssad/test_data/RPGMakerVXTestGame/Data/*.rvdata（该文件走 Git LFS，
  实际字节从 media.githubusercontent.com 的 LFS 端点取得）
- 许可：Apache-2.0 或 MIT 双许可（见同目录 LICENSE-APACHE.txt / LICENSE-MIT.txt）
- 收录内容：Actors / Animations / Armors / Classes / CommonEvents / Enemies / Items /
  MapInfos / Map001 / Skills / States / System / Troops / Weapons 共 14 个文件
- **未收录**：Scripts.rvdata（108 KB 的 Ruby 源码压缩包，不是翻译目标，解析器另有合成样本覆盖）
- 未做任何字节修改：原样拷入，用于"解析 -> 序列化 -> 字节完全相同"的往返验证

该测试工程里的文本（角色名、用语表等）随上面的双许可分发，不包含任何商业游戏的素材。

注：VX Ace（RGSS3）没有找到许可清晰的可再分发样本，只用 Scripts/gen_rgss_fixture.rb
合成的 Fixtures/rmvxace 覆盖。

## 覆盖层级：Level-1（只证结构与往返）

**这两个测试工程的事件层是空壳**，实测：
- @events{} 是空 Hash（Map001 里 0 个事件）
- 全工程 RPG::EventCommand 只有 code=0 终止符，101/401/102 文本 0 条

所以本目录只承担 Level-1 断言：Marshal 4.8 头、RPG::System / RPG::Map / Table 结构能解析、
解析→序列化字节完全相同、事件层如实为 0。
**不要**用它断言"能提取对话"——对话/选项路径由合成样本 Fixtures/rmxp|rmvx|rmvxace 覆盖（Level-2）。
数据库层（Actors/Items/Skills 的 name/description/messageN）与用语表在这份样本里是真文本，
可以用来断言这些路径。
