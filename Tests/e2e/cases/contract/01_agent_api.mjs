/*
 * 01_agent_api.mjs —— `window.__mochibox` 对外契约 + 注入幂等 / 卸载复原。
 *
 * 覆盖：版本与能力自述、probe() 字段完整性、信封协议版本、install() 二次调用不叠 hook、
 *      uninstall() 把四个 hook 全部复原、卸载后重装仍只 emit 一次、原函数抛异常不冒泡。
 *
 * 合并说明：原 `Tests/qa/idempotency_probe.mjs` 的 4 条断言（V8-IDEMPOTENT /
 * V8-NO-DOUBLE-EMIT / V8-UNINSTALL / V8-ERROR-SWALLOWED）全部落在本文件，未在别处重复计数。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

runCase('agent-api', (tap) => {
  const h = createHarness();
  const initial = h.drainAll();

  // ---- 握手信封 ----
  const hello = initial.find((envelope) => envelope && envelope.type === 'hello');
  tap.ok(!!hello, 'A-01 注入后向 outbox 推入 hello 信封', 'drain()=' + JSON.stringify(initial).slice(0, 300));
  if (hello) {
    const payload = hello.payload || {};
    tap.eq(hello.v, 1, 'A-02 hello 的信封协议版本 v=1（与脚本能力版本 VERSION 是两件事）');
    tap.eq([payload.agentVersion, payload.engineGuess, payload.caps],
      [3, 'mvmz', ['rpc', 'cheat', 'scan']], 'A-03 hello 自述 agentVersion/engineGuess/caps');
    tap.ok(Array.isArray(payload.hooks) && payload.hooks.length === 4 &&
      typeof payload.ua === 'string' && typeof payload.href === 'string',
      'A-04 hello.hooks 列出 4 个 hook，ua/href 均为字符串', JSON.stringify(payload));
  }

  // ---- 版本 / 能力 / 安装态 ----
  tap.ok(typeof h.version() === 'number' && h.version() >= 2,
    'A-05 __mochibox.version 是 ≥2 的数字', '__mochibox.version=' + h.version());
  tap.ok(typeof h.run('window.__mochibox.escapeTableVersion') === 'number' &&
    h.run('window.__mochibox.escapeTableVersion') >= 2,
    'A-06 __mochibox.escapeTableVersion 已暴露且 ≥2（Swift 侧靠它比对码表版本）');
  tap.eq(h.caps(), ['rpc', 'cheat', 'scan'], 'A-07 __mochibox.caps 逐项等于 rpc/cheat/scan');
  tap.eq(h.run('window.__mochibox.installed'), true, 'A-08 注入后 installed=true');

  const helloCountBefore = initial.filter((e) => e && e.type === 'hello').length;

  // ---- install() 二次调用 ----
  const refBefore = h.run('Window_Base.prototype.drawTextEx');
  h.run('window.__mochibox.install()');
  const refAfter = h.run('Window_Base.prototype.drawTextEx');
  tap.ok(refBefore === refAfter, 'A-09 V8-IDEMPOTENT：二次 install() 不替换 drawTextEx（引用不变）',
    'sameRef=' + (refBefore === refAfter));

  const probe = h.probe();
  tap.eq(probe.hooks.length, 4, 'A-10 二次 install() 后 hooks 仍为 4 条（不叠加）');
  tap.eq(new Set(probe.hooks).size, probe.hooks.length, 'A-11 hooks 无重复项', JSON.stringify(probe.hooks));
  tap.ok(['Window_Base.drawTextEx', 'Window_Base.drawText', 'Bitmap.drawText', 'Window_Message.startMessage']
    .every((name) => probe.hooks.includes(name)),
    'A-12 hooks 覆盖四个绘制面（drawTextEx/drawText/Bitmap.drawText/startMessage）', JSON.stringify(probe.hooks));

  const helloAdds = h.drainAll().filter((e) => e && e.type === 'hello').length;
  // install() 在第一行就 `if (installed) return true`：二次调用既不加 hook，也不重复握手。
  // （重新握手走 hello()，由宿主在重新 attach 时显式调用。）
  tap.eq(helloAdds, 0, 'A-13 二次 install() 不重复发 hello（重复握手由 hello() 单独负责）',
    'initialHello=' + helloCountBefore + ' addedHello=' + helloAdds);

  // ---- probe() 字段完整性 ----
  const requiredFields = {
    installed: 'boolean',
    hooks: 'object',
    errors: 'number',
    emitted: 'number',
    replaced: 'number',
    skipped: 'number',
    mergeFallback: 'number',
    mapSize: 'number',
    enabled: 'boolean',
    fontScale: 'number'
  };
  const missing = Object.entries(requiredFields)
    .filter(([key, type]) => typeof probe[key] !== type).map(([key, type]) => key + ':' + type);
  tap.eq(missing, [], 'A-14 probe() 的 10 个字段齐全且类型正确', JSON.stringify(probe));
  tap.eq([probe.errors, probe.mergeFallback], [0, 0],
    'A-15 干净注入后 errors=0、mergeFallback=0', JSON.stringify(probe));

  // ---- 一次绘制只 emit 一条 ----
  h.advance(100);
  h.draw('重複テスト');
  const texts = h.drainAll().filter((e) => e && e.type === 'text');
  tap.eq(texts.length, 1, 'A-16 V8-NO-DOUBLE-EMIT：一次绘制只 emit 1 条 text', 'emitted=' + texts.length);
  if (texts[0]) {
    tap.ok(texts[0].v === 1 && texts[0].type === 'text' && texts[0].payload &&
      typeof texts[0].payload.raw === 'string' && typeof texts[0].payload.ts === 'number' &&
      typeof texts[0].payload.surface === 'string',
      'A-17 text 信封带 v/type/payload.raw/ts/surface',
      JSON.stringify(texts[0]).slice(0, 300));
    tap.eq(h.probe().emitted, 1, 'A-18 probe().emitted 与实际 emit 数一致');
  }

  // ---- uninstall() 复原 ----
  const originals = h.run('JSON.stringify({' +
    'drawTextEx: !!window.__mochibox._orig.drawTextEx,' +
    'drawText: !!window.__mochibox._orig.drawText,' +
    'bitmapDrawText: !!window.__mochibox._orig.bitmapDrawText,' +
    'startMessage: !!window.__mochibox._orig.startMessage})');
  tap.eq(JSON.parse(originals), { drawTextEx: true, drawText: true, bitmapDrawText: true, startMessage: true },
    'A-19 _orig 保存了四个原始函数引用');

  h.run('window.__mochibox.uninstall()');
  tap.eq(h.run('Window_Base.prototype.drawTextEx === window.__mochibox._orig.drawTextEx'), true,
    'A-20 V8-UNINSTALL：uninstall() 复原 Window_Base.drawTextEx');
  const restored = h.run('JSON.stringify({' +
    'drawText: Window_Base.prototype.drawText === window.__mochibox._orig.drawText,' +
    'bitmapDrawText: Bitmap.prototype.drawText === window.__mochibox._orig.bitmapDrawText,' +
    'startMessage: Window_Message.prototype.startMessage === window.__mochibox._orig.startMessage})');
  tap.eq(JSON.parse(restored), { drawText: true, bitmapDrawText: true, startMessage: true },
    'A-21 uninstall() 同样复原 drawText / Bitmap.drawText / startMessage');
  tap.eq([h.run('window.__mochibox.installed'), h.probe().hooks.length], [false, 0],
    'A-22 uninstall() 后 installed=false、hooks 清空');

  // ---- 卸载后重装 ----
  h.run('window.__mochibox.install()');
  h.drainAll();
  h.advance(900);
  h.draw('再注入テスト');
  const afterReinstall = h.drainAll().filter((e) => e && e.type === 'text');
  tap.eq([h.run('window.__mochibox.installed'), afterReinstall.length], [true, 1],
    'A-23 卸载后重新 install() 生效，且一次绘制仍只 emit 1 条');

  // ---- 原函数抛异常不冒泡（独立沙箱：引擎侧抛错） ----
  const broken = createHarness({ throwing: true });
  broken.drainAll();
  let threw = false;
  try {
    broken.run('new Window_Base().drawText("x", 0, 0); new Window_Base().drawTextEx("y", 0, 0);');
  } catch (error) {
    threw = true;
  }
  const brokenState = broken.state();
  tap.ok(threw === false && brokenState.errors >= 1,
    'A-24 V8-ERROR-SWALLOWED：原函数抛异常不冒泡给游戏，且 state.errors 计数',
    'threw=' + threw + ' errors=' + brokenState.errors);
});
