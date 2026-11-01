# rmvx 测试样本来源

本目录下的 Data/*.rvdata、Game.ini、Game.rvproj 全部由
Scripts/gen_rgss_fixture.rb 用系统 ruby（2.6.10）合成，
**不含任何第三方游戏素材或文本**，可随仓库分发（与仓库同许可）。

- 引擎：RPG Maker VX（RGSS2）
- 编码：字符串为 ASCII-8BIT（无 :E ivar），字节按 Windows-31J(CP932) 编码；生成时已自检文件内不含 :E 符号
- 术语字段形状：RPG::System::Terms，@terms 为 33 个扁平字符串 ivar
- 覆盖层级：**Level-2**（文本路径与编码/边界断言）。事件指令含 101/401 对话、102/402/404 选项、405 滚动文本；
  边界含空串、超长串（超过 255 字节，走多字节长度分支）、反斜杠 C 着色控制序列、换行。
- 文本内容：占位用的原创日文/中文短句
- 重新生成：ruby Scripts/gen_rgss_fixture.rb（幂等，重复运行字节完全相同）
