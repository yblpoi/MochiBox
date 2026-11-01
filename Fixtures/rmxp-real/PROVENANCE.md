# Fixtures/rmxp-real 来源与许可

本目录是**第三方开源工程的真实 RPG Maker XP 数据文件**（不是游戏素材），只用于验证
Marshal 解析/写回在真实数据上的行为。

- 来源仓库：https://github.com/aphadeon/OpenXP （OpenXP，一个开源的 RPG Maker XP 运行时/编辑器）
- 提交：7be0b4ac90c0064e37e7c2da396d2f90037fa172
- 路径：Runtime/TestProject/Data/*.rxdata
- 许可：MIT（见同目录 LICENSE-OpenXP.txt，版权归 aphadeon & Glitchfinder）
- 收录内容：Actors / Animations / Armors / Classes / CommonEvents / Enemies / Items /
  MapInfos / Map001 / Skills / States / System / Tilesets / Troops / Weapons 共 15 个文件
- **未收录**：Scripts.rxdata（109 KB 的 Ruby 源码压缩包，不是翻译目标，解析器另有合成样本覆盖）
- 未做任何字节修改：原样拷入，用于"解析 -> 序列化 -> 字节完全相同"的往返验证

这些文件里的文本（角色名、物品名、用语表等）是该测试工程自带的占位内容，
版权随上面的 MIT 许可，不包含任何商业游戏的素材。

## 覆盖层级：Level-1（只证结构与往返）

**这两个测试工程的事件层是空壳**，实测：
- @events{} 是空 Hash（Map001 里 0 个事件）
- 全工程 RPG::EventCommand 只有 code=0 终止符，101/401/102 文本 0 条

所以本目录只承担 Level-1 断言：Marshal 4.8 头、RPG::System / RPG::Map / Table 结构能解析、
解析→序列化字节完全相同、事件层如实为 0。
**不要**用它断言"能提取对话"——对话/选项路径由合成样本 Fixtures/rmxp|rmvx|rmvxace 覆盖（Level-2）。
数据库层（Actors/Items/Skills 的 name/description/messageN）与用语表在这份样本里是真文本，
可以用来断言这些路径。

## Game.ini

同目录的 Game.ini 来自同一仓库路径（Runtime/TestProject/Game.ini），内容是
Library=RGSS104E.dll。EngineDetector 的 needle 是 "Library=RGSS1"，子串命中，
所以这份样本可直接当 XP 识别正例，**不需要改检测代码**。
