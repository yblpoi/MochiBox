# RGSS 文本通道：menu / help 面真机截图（2026-11-02）

对象：`/tmp/vx-run`（RPG Maker VX 测试工程，标题 `VX Test`）
运行时：`build/MochiBox.app`（HEAD `d09b978`），mkxp-z
后端：`Fixtures/mock_translate_server.mjs --mode ok`（对每条原文返回 `"译:" + 原文`）
数据目录：`/tmp/rgss-surfaces-evidence/data3`（冷缓存，首遍必然 MISS）

## 每张图对应的面

| 文件 | 面 | 画面 | hook 日志 | OCR |
|---|---|---|---|---|
| `menu.png` | menu | VX 主菜单，六项命令 | `hooked menu: Window_Command#draw_item`；seq=4..9 `(pending)` → seq=10..15 `译:...` | `译：Item` / `Skill` / `Equip` / `Status` / `Save` / `Game End` |
| `help.png` | help | 道具页，底部说明栏 | `hooked help: Window_Help#set_text`；seq=16 `(pending)` → seq=17 `译:...` | `译：Restores 500 HP of one character.` |
| `menu-crop-3x.png` | menu | 菜单左栏放大 3 倍 | 同上 | 用于确认 `译：Status` / `译：Save` |
| `help-crop-4x.png` | help | 底部说明栏放大 4 倍 | 同上 | 用于确认 `译：Restores ...` |

两张原图来自**同一个 `--play-native` 进程**，先后关系见 `driver.txt`：

```text
[23:43:44.790] MAP
[23:43:45.792] MENU1      # 第一次菜单：六项全部 PENDING，显示原文
[23:43:49.793] MENU2      # 第二次菜单：整窗重绘，六项全部命中 -> 译:...
[23:44:01.795] GAIN item=1
[23:44:01.795] ITEM1      # 第一次进道具页
[23:44:04.797] ITEM2      # 第二次进道具页：帮助栏命中 -> 译:...
```

menu 图在 `MENU2` 之后截取，help 图在 `ITEM2` 之后截取。首遍都显示原文，
第二遍命中**同一进程内**的宿主缓存后显示中文；不是重启后的缓存命中。

VX 主菜单本身没有帮助窗（`Scene_Menu` 只建 `Window_Command` / `Window_Gold` /
`Window_MenuStatus`）。VX 的帮助栏在 `Scene_Item`：`Window_Item#update_help` 调
`Window_Help#set_text(item.description)`。所以 help 图是「菜单 → 道具」页，不是主菜单底部。

## 完整日志

- `hook.txt` —— `Resources/rgss/mochi_rgss_hook.rb` 的日志（`/tmp/mochi-rgss.log`）
- `bridge.txt` —— `RGSSBridge` 的日志（`/tmp/mochi-rgss-bridge.log`）
- `driver.txt` —— 测试夹具的阶段时间戳（`/tmp/vx-surfaces-driver.log`）
- `mock-requests.txt` —— mock 后端收到的完整请求（JSON Lines 原文）
- `ocr.txt` —— 两张大图的原始 OCR 输出

关键行（原文照录）：

```text
[2026-11-02 23:43:16] hooked menu: Window_Command#draw_item (trigger=tracepoint:Window_Command)
[2026-11-02 23:43:16] hooked help: Window_Help#set_text (trigger=tracepoint:Window_Help)
[2026-11-02 23:43:46] PENDING (display original) "Item"
...
[2026-11-02 23:43:49] RESP seq=10 "译:Item"
[2026-11-02 23:43:49] RESP seq=15 "译:Game End"
[2026-11-02 23:44:01] PENDING (display original) "Restores 500 HP of one character."
[2026-11-02 23:44:03] RESP seq=17 "译:Restores 500 HP of one character."
```

## 没补到的面

- **choice**：VX 的选项并入 message（hook 日志写明
  `choice on RGSS2 has no separate entry; it rides message`），但 `/tmp/vx-run` 的
  `Map001` 事件表是空的（`@events = {}`），没有 102「显示选项」事件，因此没有
  真机选择画面。要补这一面，需要一个带 102 指令的地图事件。
- **battle**：工程里没有战斗事件，`Data/Troops.rvdata` 的敌群成员为空，也没有战斗图，
  进不了真正的战斗画面。hook 的 battle 面仍只有假类断言。

## 复现

1. 起 mock 后端（固定端口，便于 CLI 传参）：

```bash
node Fixtures/mock_translate_server.mjs --port 64805 --mode ok \
  --record /tmp/rgss-surfaces-evidence/mock
```

2. 把测试夹具写进 `/tmp/vx-run/mkxp.json`（`GameLauncher` 会把产品 hook 排在最后）：

```json
{"preloadScript":["/tmp/vx-surfaces-driver.rb"],"debugMode":false}
```

3. 启动会话：

```bash
MOCHI_DATA_DIR=/tmp/rgss-surfaces-evidence/data3 \
  ./build/MochiBox.app/Contents/MacOS/MochiBox \
  --play-native /tmp/vx-run --provider openai \
  --endpoint http://127.0.0.1:64805 --api-key test --duration 60
```

4. 标题画面按一次 `space` 进入 New Game。夹具在 `Scene_Map` 后自动打开菜单、
   重开菜单、进道具页、重开道具页；按 `driver.txt` 的时间点截窗口：

```bash
/tmp/shotpid/shotpid <mkxp-z pid> menu.png
/tmp/shotpid/shotpid <mkxp-z pid> help.png
```

夹具源码（不属于产品代码）：

```ruby
Thread.new do
  600.times do
    break if defined?($scene) && $scene && $scene.class.name == 'Scene_Map'
    sleep 0.1
  end
  sleep 1.0
  $scene = Scene_Menu.new          # MENU1
  sleep 4.0
  $scene = Scene_Menu.new          # MENU2
  sleep 12.0
  $game_party.gain_item($data_items[1], 1)
  $scene = Scene_Item.new          # ITEM1
  sleep 3.0
  $scene = Scene_Item.new          # ITEM2
  sleep 20.0
end
```

直接用键盘开菜单在后台启动时不可靠（进程拿不到焦点），所以夹具用 `$scene =` 切换场景；
渲染路径仍是 VX 默认脚本的 `Scene_Menu` / `Scene_Item` / `Window_Command` / `Window_Help`，
没有用假类。
