/*
 * 16_battle_log_translation.mjs —— 战斗日志译文的两处硬门禁。
 *
 * 缺陷 1（hook 面）：`NRP_WindowBattleLogLayout` 在 `Window_BattleLog.prototype` 上**自建**
 *   `drawTextEx`，方法查找先命中它，挂在 `Window_Base.prototype.drawTextEx` 上的包装永远
 *   不会被调用。日志文本于是逐字符落到 `Bitmap.drawText`，而那条路只采集、不改写。
 *   这里用 `'own'` / `'inherit'` 两种最小原型把"该包"与"不该包"钉死：
 *     · own：必须包装，且包装期间 Bitmap 层**不得**再采集一次（inDrawDepth 的约定）；
 *     · inherit：没有自有属性 = 原版 MV/MZ，直接跳过，原型上一个属性都不许多。
 *
 * 缺陷 2（`_ABL` 面）：`AddBattleLogEC` 在文本进入战斗日志前剥掉 `_ABL`，翻译表的 key
 *   却仍带它。回退命中后必须剥掉译文开头的 `_ABL`；正常命中路径一个字都不许动。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

const BASE_HOOKS = [
  'Window_Base.drawTextEx',
  'Window_Base.drawText',
  'Bitmap.drawText',
  'Window_Message.startMessage'
];

const RAW = 'ミューテは拘束から逃れようと力いっぱいもがいた！';
const ZH = '缪特从束缚中拼命挣扎！';
const ABL_KEY = '_ABL' + RAW;
const ABL_ZH = '_ABL' + ZH;

function deliver(h, payload) {
  h.inbox({ type: 'setTranslation', payload });
  h.drainAll();
}

function textEvents(h) {
  return h.drainAll().filter((envelope) => envelope && envelope.type === 'text');
}

runCase('battle-log', (tap) => {
  // BL1 —— 自有 drawTextEx：包装、替换、且 Bitmap 层不重复采集。
  {
    const h = createHarness({ capture: true, battleLog: 'own' });
    h.drainAll();
    tap.eq(h.probe().hooks, BASE_HOOKS.concat('Window_BattleLog.drawTextEx'),
      'BL1 自有 drawTextEx 时安装 hook 并写入 installedHooks');

    deliver(h, { key: RAW, translatedRaw: ZH, segments: [{ kind: 'text', value: ZH }] });
    h.advance(1000);
    tap.eq(h.drawBattleLog(RAW), ZH, 'BL1 战斗日志收到译文（替换 args[0]）');

    const events = textEvents(h);
    tap.eq(events.length, 1, 'BL1 一行只采集一次（包装内 inDrawDepth 抑制 Bitmap 重复采集）');
    tap.eq(events[0] && events[0].payload.surface, 'Window_BattleLog.drawTextEx',
      'BL1 采集面标为 Window_BattleLog.drawTextEx');
    tap.eq(events[0] && events[0].payload.raw, RAW, 'BL1 采集到的仍是原文');
  }

  // BL2 —— 重复 install 不叠 hook、不换 wrapper 引用。
  {
    const h = createHarness({ capture: true, battleLog: 'own' });
    const stable = h.run('(function () {' +
      ' var before = Window_BattleLog.prototype.drawTextEx;' +
      ' window.__mochibox.install(); window.__mochibox.install();' +
      ' return Window_BattleLog.prototype.drawTextEx === before;' +
      '})()');
    tap.eq(stable, true, 'BL2 连续 install() 不重复包装（wrapper 引用不变）');
    const hooks = h.probe().hooks;
    tap.eq(hooks.length, 5, 'BL2 重复 install() 后 hooks 仍是 5 条');
    tap.eq(new Set(hooks).size, hooks.length, 'BL2 hooks 无重复项');
  }

  // BL3 —— uninstall 还原原型（不能只置 installed=false）。
  {
    const h = createHarness({ capture: true, battleLog: 'own' });
    deliver(h, { key: RAW, translatedRaw: ZH, segments: [{ kind: 'text', value: ZH }] });
    h.run('window.__mochibox.uninstall()');
    tap.eq(h.probe().hooks, [], 'BL3 uninstall() 后 hooks 清空');
    tap.eq(h.run('!!Window_BattleLog.prototype.drawTextEx.__mochiboxHooked'), false,
      'BL3 uninstall() 后原型不再是包装函数');
    tap.eq(h.run("Object.prototype.hasOwnProperty.call(Window_BattleLog.prototype, 'drawTextEx')"), true,
      'BL3 自有属性仍在（还原为插件的原函数）');
    tap.eq(h.drawBattleLog(RAW), RAW, 'BL3 uninstall() 后战斗日志画回原文');
  }

  // BL4 —— 继承版本（原版 MV/MZ）：跳过、不改原型，翻译仍由 Window_Base 覆盖。
  {
    const h = createHarness({ capture: true, battleLog: 'inherit' });
    h.drainAll();
    tap.eq(h.probe().hooks, BASE_HOOKS, 'BL4 无自有 drawTextEx 时不多装 hook');
    tap.eq(h.run("Object.prototype.hasOwnProperty.call(Window_BattleLog.prototype, 'drawTextEx')"), false,
      'BL4 不在 Window_BattleLog.prototype 上凭空造属性');

    deliver(h, { key: RAW, translatedRaw: ZH, segments: [{ kind: 'text', value: ZH }] });
    h.advance(1000);
    tap.eq(h.drawBattleLog(RAW), ZH, 'BL4 继承路径仍由 Window_Base.drawTextEx 完成替换');
  }

  // ABL1 —— 回退命中 + 骨架重组：结果剥掉开头的 _ABL（战斗日志全链路）。
  {
    const h = createHarness({ capture: true, battleLog: 'own' });
    h.drainAll();
    deliver(h, { key: ABL_KEY, translatedRaw: ABL_ZH, segments: [{ kind: 'text', value: ABL_ZH }] });
    h.advance(1000);
    tap.eq(h.drawBattleLog(RAW), ZH, 'ABL1 无前缀的 raw 用 _ABL key 命中，译文不含 _ABL');
    tap.eq(h.probe().mergeFallback, 0, 'ABL1 骨架重组路径不计 mergeFallback');
  }

  // ABL2 —— 回退命中 + translatedRaw 直出（旧条目无 segments），同样要剥。
  {
    const h = createHarness({ capture: true });
    h.drainAll();
    deliver(h, { key: ABL_KEY, translatedRaw: ABL_ZH });
    h.advance(1000);
    tap.eq(h.draw(RAW), ZH, 'ABL2 translatedRaw 路径同样剥掉 _ABL');
    tap.eq(h.probe().mergeFallback, 1, 'ABL2 走的是 v0.2 兼容路径');
  }

  // ABL3 —— 剥完为空：按现有规则返回 null，画原文。
  {
    const h = createHarness({ capture: true });
    h.drainAll();
    deliver(h, {
      key: '_ABLこんにちは',
      translatedRaw: '_ABL',
      segments: [{ kind: 'text', value: '_ABL' }]
    });
    h.advance(1000);
    tap.eq(h.draw('こんにちは'), 'こんにちは', 'ABL3 剥完为空时画原文');
    const probe = h.probe();
    tap.eq([probe.replaced, probe.mergeFallback], [0, 0], 'ABL3 不算命中、不算降级');
  }

  // ABL4 —— 正常 key：不触发回退、不剥前缀。
  {
    const h = createHarness({ capture: true });
    h.drainAll();
    deliver(h, { key: 'こんにちは', translatedRaw: '你好', segments: [{ kind: 'text', value: '你好' }] });
    h.advance(1000);
    tap.eq(h.draw('こんにちは'), '你好', 'ABL4 正常 key 的译文原样输出');
    tap.eq(h.probe().mergeFallback, 0, 'ABL4 正常路径不计 mergeFallback');
  }

  // ABL5 —— `_ABL` 后紧跟控制码（真数据里共 195 处）：前缀独立成 text 段，
  // 必须先对齐段数，否则 mergeBySkeleton 判"段数不符"而整行画回日文。
  {
    const h = createHarness({ capture: true });
    h.drainAll();
    const raw = '\\c[23]粘液の効果で服が少し溶けてしまった…';
    const key = '_ABL\u001F粘液の効果で服が少し溶けてしまった…';
    const zh = '\\c[23]粘液的效果让衣服稍微溶解了…';
    deliver(h, {
      key,
      translatedRaw: '_ABL' + zh,
      segments: [
        { kind: 'text', value: '_ABL' },
        { kind: 'code', value: '\\c[23]' },
        { kind: 'text', value: '粘液的效果让衣服稍微溶解了…' }
      ]
    });
    h.advance(1000);
    tap.eq(h.draw(raw), zh, 'ABL5 _ABL 独立成段时仍能按本行骨架重组');
    tap.eq(h.probe().mergeFallback, 0, 'ABL5 对齐后不计 mergeFallback');
  }
});
