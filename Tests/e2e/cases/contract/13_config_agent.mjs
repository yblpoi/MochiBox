/*
 * 13_config_agent.mjs —— 配置下发对 Agent 的即时生效面：P0-14 翻译开关 + P0-15 字号缩放。
 *
 * 覆盖的是 PRD 里**能被自动判定**的那几半句：
 *
 *   P0-14「工具栏开关切换后立即下发给 Agent（`config.enabled`）；关闭时文本流继续采集
 *         （状态列显示 `已暂停`）但游戏画面显示原文；重新打开后此前已缓存的句子立即可用」
 *     → 采集不断（emitted 照常增）、替换停（replaced 不增、画的是原文）、
 *       重开后缓存句立即命中（不需要等下一轮翻译）。
 *
 *   P0-15「滑杆 80%–130%（步长 5%）…；下发 `config.fontScale`；Agent 对 `drawTextEx` 的字号
 *         做乘法（`this.contents.fontSize`）并在窗口 `refresh` 时生效；缩放后不出现文本
 *         绘制异常（Agent `errors` 计数为 0）；数值持久化」
 *     → 0.8 / 1.3 边界在**绘制层真正读到的字号**上生效、绘制后复原、errors 恒 0。
 *
 * 依据（期望值的唯一来源，不许"跑出来是多少就写多少"）：
 *   · docs/prd.md:149（P0-14 原文）、:150（P0-15 原文）；
 *   · Resources/agent_mvmz.js:71-72（enabled=true / fontScale=1.0 默认值）、
 *     :728-745（processText：`if (state.enabled)` 才查表，且**无论开关都 collect**）、
 *     :2092-2094 / :2134-2136（hook 内 `Math.max(1, Math.round(restore * state.fontScale))`）、
 *     :2357-2358（config 分支：enabled 取布尔、fontScale 仅要求 > 0）、
 *     :617-629（config 后 requestRepaint → 窗口 refresh 时重绘）。
 *
 * 不覆盖（见 docs/testing.md §8 矩阵与本文件末尾的 GAP 注释）：滑杆 UI、⌘+/⌘-、设置持久化、
 * 肉眼可见的字形/断行效果 —— 这些必须手工过。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

/** harness 的最小引擎里 `Bitmap` 的初始字号（Tests/e2e/lib/harness.mjs：`this.fontSize = 24`）。 */
const BASE_FONT = 24;

runCase('config-agent', (tap) => {
  // =====================================================================
  // P0-14 翻译开关
  // =====================================================================
  const h = createHarness({ capture: true });
  h.drainAll();
  // 预置缓存：key = 剥码后的正文（agent_mvmz.js:244-248 mapKeyOfSegments）。
  h.inbox({ type: 'setTranslation', payload: { key: 'こんにちは', translatedRaw: '你好' } });
  h.drainAll();

  const fresh = h.probe();
  tap.eq([fresh.enabled, fresh.fontScale], [true, 1],
    'P0-14 默认 enabled=true、fontScale=1.0（agent_mvmz.js:71-72）', JSON.stringify(fresh));

  // 基线阳性对照：没有它，"关闭后画原文"可能只是"从来没翻译成功过"。
  h.advance(1000);
  tap.eq(h.draw('こんにちは'), '你好', 'P0-14 基线：开启时画面显示译文（缓存命中）');
  const beforeOff = h.probe();
  tap.eq([beforeOff.emitted, beforeOff.replaced], [1, 1],
    'P0-14 基线：一次绘制 emit 1 条、替换 1 次', JSON.stringify(beforeOff));

  // ---- 关闭 ----
  h.inbox({ type: 'config', payload: { enabled: false } });
  h.drainAll();
  const off = h.probe();
  tap.eq(off.enabled, false, 'P0-14 config.enabled=false 立即生效（probe().enabled=false）');

  h.advance(1000);
  tap.eq(h.draw('こんにちは'), 'こんにちは',
    'P0-14 关闭后游戏画面显示原文（已缓存的句子也不替换）');
  const afterOff = h.probe();
  tap.eq(afterOff.emitted - off.emitted, 1,
    'P0-14 关闭时文本流继续采集（emitted 照常 +1，对应 UI 的"已暂停"而非"已停止"）',
    'emitted ' + off.emitted + '→' + afterOff.emitted);
  tap.eq([afterOff.replaced, afterOff.errors], [off.replaced, 0],
    'P0-14 关闭时不执行译文替换（replaced 不增、errors=0）',
    'replaced ' + off.replaced + '→' + afterOff.replaced);
  tap.eq(h.lastFontSize(), BASE_FONT,
    'P0-14 关闭时页面绘制参数未被改写（contents.fontSize 仍为原始 24）',
    'fontSize=' + h.lastFontSize());

  // 关闭期间的新句子也要采集（不只是"旧句不替换"）。
  h.advance(1000);
  tap.eq(h.draw('おはよう'), 'おはよう', 'P0-14 关闭期间的新句子同样画原文');
  tap.eq(h.probe().emitted - afterOff.emitted, 1,
    'P0-14 关闭期间的新句子仍进入采集队列（emitted 再 +1）');

  // ---- 重新打开 ----
  h.inbox({ type: 'config', payload: { enabled: true } });
  h.drainAll();
  tap.eq(h.probe().enabled, true, 'P0-14 config.enabled=true 立即生效');
  h.advance(1000);
  tap.eq(h.draw('こんにちは'), '你好',
    'P0-14 重新打开后此前已缓存的句子立即可用（不需要等新一轮翻译）');
  const afterOn = h.probe();
  tap.eq(afterOn.replaced, afterOff.replaced + 1,
    'P0-14 重新打开后替换恢复（replaced +1）', 'replaced=' + afterOn.replaced);
  tap.eq(afterOn.errors, 0, 'P0-14 全程 errors=0（开关切换不产生异常路径）');

  // =====================================================================
  // P0-15 字号缩放
  // =====================================================================
  const g = createHarness({ capture: true });
  g.drainAll();
  // 固定一个窗口实例：既要量"绘制时"的字号，也要量"绘制后"是否复原。
  g.run('window.__e2eWin = new Window_Base()');

  tap.eq(g.run('window.__e2eWin.contents.fontSize'), BASE_FONT,
    'P0-15 前置：窗口初始字号 24（harness 引擎常量，即缩放基准）');

  // 0.8（滑杆下限，PRD P0-15「80%–130%」）
  g.inbox({ type: 'config', payload: { fontScale: 0.8 } });
  g.drainAll();
  tap.eq(g.state().fontScale, 0.8, 'P0-15 config.fontScale=0.8 下发生效（state.fontScale=0.8）');
  g.resetCalls();
  g.run('window.__e2eWin.drawTextEx("テスト", 0, 0)');
  // 期望值来自 agent_mvmz.js:2093-2094：Math.max(1, Math.round(24 * 0.8)) = 19
  tap.eq(g.lastFontSize(), 19,
    'P0-15 0.8 倍在绘制层生效：24 × 0.8 = 19.2 → round → 19',
    '绘制层 fontSize=' + g.lastFontSize());
  tap.eq(g.run('window.__e2eWin.contents.fontSize'), BASE_FONT,
    'P0-15 绘制结束后字号复原为 24（hook 的 finally，不影响下一行）');

  // 1.3（滑杆上限）
  g.inbox({ type: 'config', payload: { fontScale: 1.3 } });
  g.drainAll();
  tap.eq(g.state().fontScale, 1.3, 'P0-15 config.fontScale=1.3 下发生效（state.fontScale=1.3）');
  g.resetCalls();
  g.advance(1000);
  g.run('window.__e2eWin.drawTextEx("テスト", 0, 0)');
  // 24 × 1.3 = 31.2 → round → 31
  tap.eq(g.lastFontSize(), 31, 'P0-15 1.3 倍在绘制层生效：24 × 1.3 = 31.2 → round → 31',
    '绘制层 fontSize=' + g.lastFontSize());
  tap.eq(g.run('window.__e2eWin.contents.fontSize'), BASE_FONT, 'P0-15 1.3 倍绘制后同样复原为 24');

  // 1.0（默认值：`state.fontScale !== 1` 分支不进入，字号原样传给引擎）
  g.inbox({ type: 'config', payload: { fontScale: 1.0 } });
  g.drainAll();
  g.resetCalls();
  g.advance(1000);
  g.draw('テスト');
  tap.eq([g.state().fontScale, g.lastFontSize()], [1, BASE_FONT],
    'P0-15 fontScale=1.0 时不缩放（分支不进入，绘制层仍是 24）',
    JSON.stringify(g.state()));

  // 非法值：agent_mvmz.js:2358 只接受 > 0 的数字，0/负数必须被忽略（保持上一次生效值）。
  g.inbox({ type: 'config', payload: { fontScale: 0 } });
  g.drainAll();
  tap.eq(g.state().fontScale, 1, 'P0-15 fontScale=0 被忽略（agent_mvmz.js:2358 要求 > 0），生效值不变');

  // 越界（> 1.3）：Agent 侧**不夹取**，原样采用；夹取在 Swift 设置层
  // （Stores.swift:452-457 越界回落 1.3，domain D2 已断言 9.0 → 1.3）。
  // 这里只断"越界值不会把 Agent 打崩"这条可观测面，夹取本身见 GAP-P0-15。
  g.inbox({ type: 'config', payload: { fontScale: 9.0 } });
  g.drainAll();
  g.resetCalls();
  g.advance(1000);
  tap.eq(g.draw('テスト'), 'テスト', 'P0-15 越界 fontScale=9.0 下仍能正常绘制（不抛异常、不改写文本）');
  tap.eq([g.probe().errors, g.lastFontSize() !== null], [0, true],
    'P0-15 越界值下 errors=0 且绘制真的到达引擎（字号由上游夹取，见 GAP-P0-15）',
    'errors=' + g.probe().errors + ' fontSize=' + g.lastFontSize());

  tap.eq(g.probe().errors, 0, 'P0-15 全程 errors=0（PRD「缩放后不出现文本绘制异常」的可观测面）');

  // =====================================================================
  // 游戏字体（v0.7）：config.gameFontFamily → 绘制字体链
  // =====================================================================
  // 这里发的是 Host 的**完整** config（新字段 + 全部旧字段）：Agent 只接受
  // 一次收全的配置，任何旧字段丢失都会让缩放/开关悄悄失效。
  // payload 本身的构造（HostCommand.config）由 SelfTest E 组 host_command_config_font_family 钉住。
  const f = createHarness({ capture: true });
  f.drainAll();
  const autoFont = String(f.run('new Bitmap()._makeFontNameText()'));
  tap.ok(autoFont.indexOf('PingFang SC') >= 0,
    '字体 默认链含 PingFang SC（空 gameFontFamily = 自动）', autoFont);
  tap.ok(autoFont.indexOf('24px ') === 0, '字体 字号仍由 _makeFontNameText 自己拼', autoFont);

  f.inbox({
    type: 'config',
    payload: {
      enabled: false,
      fontScale: 1.1,
      srcLang: 'ja',
      tgtLang: 'zh-Hans',
      maxMapSize: 5000,
      gameFontFamily: 'Unifont Smooth'
    }
  });
  const fontState = f.probe();
  tap.eq([fontState.enabled, fontState.fontScale, fontState.fontFamily],
    [false, 1.1, 'Unifont Smooth'],
    '字体 config.gameFontFamily 即时生效，且 enabled / fontScale 旧字段不变',
    JSON.stringify(fontState));

  const chosen = String(f.run('new Bitmap()._makeFontNameText()'));
  tap.ok(chosen.indexOf('24px "Unifont Smooth",') === 0,
    '字体 用户族名带引号排在最前', chosen);
  tap.ok(chosen.indexOf('PingFang SC') > 0, '字体 默认链仍兜底', chosen);
  tap.ok(chosen.indexOf('x') > 0, '字体 游戏自己的 fontFace 未丢失', chosen);

  f.advance(1000);
  tap.eq(f.draw('テスト'), 'テスト', '字体 enabled=false 时仍画原文（旧字段行为不变）');
  tap.eq(f.probe().errors, 0, '字体 注入全程 errors=0');

  const italic = String(f.run('var b = new Bitmap(); b.fontItalic = true; b._makeFontNameText()'));
  tap.ok(italic.indexOf('italic 24px ') === 0, '字体 斜体前缀由 Agent 自己拼', italic);

  // =====================================================================
  // 数据回写两级开关（v0.8）：config.dataPatchEnabled / config.dataPatchNames
  // =====================================================================
  // 期望值来源：Resources/agent_mvmz.js 的 state 默认值（dataPatchEnabled/dataPatchNames
  // 均为 true）与 config 分支「字段缺失时保持当前值」。行为面（不写/还原/防抖）在
  // 17_data_patch_translation.mjs 里钉死，这里只管下发与向后兼容。
  const d = createHarness({ capture: true });
  d.drainAll();
  tap.eq([d.probe().dataPatchEnabled, d.probe().dataPatchNames], [true, true],
    '数据开关 默认 dataPatchEnabled=true / dataPatchNames=true', JSON.stringify(d.probe()));

  // Host 的完整 config（连同新字段一起下发）。
  d.inbox({
    type: 'config',
    payload: {
      enabled: true,
      fontScale: 1.0,
      srcLang: 'ja',
      tgtLang: 'zh-Hans',
      maxMapSize: 5000,
      gameFontFamily: '',
      dataPatchEnabled: false,
      dataPatchNames: false
    }
  });
  d.drainAll();
  tap.eq([d.probe().dataPatchEnabled, d.probe().dataPatchNames], [false, false],
    '数据开关 config 两个新字段即时生效', JSON.stringify(d.probe()));

  // 旧 Host（不认这两个字段）：payload 里没有键 → 保持当前值 true，不能因此关掉回写。
  const e = createHarness({ capture: true });
  e.drainAll();
  e.inbox({
    type: 'config',
    payload: { enabled: true, fontScale: 1.0, srcLang: 'ja', tgtLang: 'zh-Hans', maxMapSize: 5000 }
  });
  e.drainAll();
  tap.eq([e.probe().dataPatchEnabled, e.probe().dataPatchNames], [true, true],
    '数据开关 旧 Host 缺字段 → Agent 按默认 true 处理（向后兼容）', JSON.stringify(e.probe()));

  // 已经下发过的值不能被后续「缺字段」的 config 重置回去（每次重连都会重发整份配置）。
  e.inbox({ type: 'config', payload: { dataPatchEnabled: false } });
  e.inbox({ type: 'config', payload: { enabled: true } });
  e.drainAll();
  tap.eq([e.probe().dataPatchEnabled, e.probe().dataPatchNames], [false, true],
    '数据开关 后续缺字段的 config 不清掉已下发的值', JSON.stringify(e.probe()));
  tap.eq(e.probe().errors, 0, '数据开关 全程 errors=0');
});
