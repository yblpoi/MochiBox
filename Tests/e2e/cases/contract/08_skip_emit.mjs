/*
 * 08_skip_emit.mjs —— 跳过判定的两个面 + 跳过句仍然上报（BUG-7 回归）。
 *
 * 合并说明（不重复计数）：
 *   · 面 A（能不能看见）与"跳过句仍 emit / 原文逐字节保留"是**同一条事实**。
 *     原 `Tests/qa/emit_contract_probe.mjs` 的 V4-11a..g 与 `skip_probe.mjs` 的
 *     可见性断言样本完全重合（350 / ！？ / 空格 / ３５０ / 350 空格 / ♪ / \\C[2]350），
 *     因此这里只保留**一条**断言，名字里同时标出两个 ID。
 *   · 面 B（判得对不对）单独计数：status / skipReason / state.skipped 增量。
 *
 * 契约（docs/prd.md P0-08 / P0-09）：
 *   跳过是功能，不是异常 —— 每个绘制字符串产生 **1 条 TextEvent**，
 *   跳过句额外带 status='skipped' + skipReason，原文 raw 逐字节保留。
 *   "是否真的没打后端"在页面侧不可观测，由 domain 层的 V4S-6b 断言，这里不假装验证。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

// id, 原文, 期望 status, 期望 skipReason, 原 emit 探针的编号（重合样本）
const CASES = [
  ['V4-1a', '今日は8月15日です', 'pending', null, null],
  ['V4-1b', '宝箱が3つある', 'pending', null, null],
  ['V4-1c', 'HPは100/100', 'pending', null, null],
  ['V4-1d', '10秒後', 'pending', null, null],
  ['V4-1e', '第2章', 'pending', null, null],
  ['V4-1f', '350G', 'pending', null, null],
  ['V4-2a', '350', 'skipped', 'numeric', 'V4-11a'],
  ['V4-2b', '！？', 'skipped', 'punctuation', 'V4-11b'],
  ['V4-2c', '   ', 'skipped', 'whitespace', 'V4-11c'],
  ['V4-2d', '３５０', 'skipped', 'numeric', 'V4-11d'],
  ['V4-2e', '350 ', 'skipped', 'numeric', 'V4-11e'],
  ['V4-3a', '\\C[2]350', 'skipped', 'numeric', 'V4-11g'],
  ['V4-3b', '\\C[2]10秒後', 'pending', null, null],
  ['V4-4a', 'こんにちは', 'pending', null, null],
  ['V4-5a', '３５０Ｇ', 'pending', null, null],
  ['V4-5b', 'ＯＫ', 'pending', null, null],
  ['V4-5c', '♪', 'skipped', 'punctuation', 'V4-11f'],
  ['V4-5d', '★', 'skipped', 'punctuation', null]
];

runCase('skip-emit', (tap) => {
  const h = createHarness();
  h.drainAll();

  for (const [id, raw, expectStatus, expectReason, emitId] of CASES) {
    // Agent 采集抑制窗口 800ms（滑动）：每条用例必须跨过窗口，否则同 key 会被去重。
    h.advance(900);
    h.drainAll();
    const before = h.state();
    h.draw(raw);
    const events = h.drainAll().filter((envelope) => envelope.type === 'text');
    const after = h.state();
    const event = events[0];
    const payload = (event && event.payload) || {};

    // ---- 面 A：能不能看见（P0-08 / P0-09） ----
    const visible = events.length === 1;
    const rawKept = payload.raw === raw;
    const emittedDelta = after.emitted - before.emitted;
    const emitIdTag = emitId ? ' / ' + emitId : '';
    tap.ok(visible && rawKept && emittedDelta === 1,
      '[' + id + emitIdTag + '] 面A 恰好 1 条 text、raw 逐字节保留、emitted +1',
      'events=' + events.length + ' rawKept=' + rawKept + ' emittedΔ=' + emittedDelta +
      ' payload=' + JSON.stringify(payload).slice(0, 200));

    // ---- 面 B：判得对不对（状态与理由） ----
    const statusOk = payload.status === expectStatus;
    const reasonOk = expectReason === null
      ? payload.skipReason === undefined
      : payload.skipReason === expectReason;
    const skippedDelta = after.skipped - before.skipped;
    const counterOk = skippedDelta === (expectStatus === 'skipped' ? 1 : 0);
    tap.ok(statusOk && reasonOk && counterOk,
      '[' + id + '] 面B status=' + expectStatus + (expectReason ? '/' + expectReason : '') + ' 且 skipped 计数正确',
      'status=' + JSON.stringify(payload.status) + ' reason=' + JSON.stringify(payload.skipReason) +
      ' skippedΔ=' + skippedDelta);
  }

  tap.note('agent.state=' + JSON.stringify(h.state()) + ' cases=' + CASES.length);
});
