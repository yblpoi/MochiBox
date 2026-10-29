/*
 * 07_dedupe_race.mjs —— 采集去重的身份 / 窗口回归（BUG-8 派生）。
 *
 * 契约（PRD P0-08 改后 + 架构 §6.3）：
 *   · 行身份 = `surface` + `raw`（不得用 mapKey / 剥码后的 text）
 *   · 去重窗口 = 800ms **滑动**窗口，被抑制时**续期**（不是按帧号、不是永久去重）
 *   · 持续可见（间隔 < 窗口）→ 1 条；间隔 > 窗口后再现 → 再来 1 条
 *
 * 迁移自 `Tests/qa/dedupe_race_probe.mjs`（A1–A7），期望值与边界取值一个都没动：
 * 窗内用 ≤400ms、窗外用 ≥1600ms（800ms 精确边界会因调度抖动随机红）。
 * 时钟由 harness 注入，用例显式步进 —— 同一命令跑两次结果完全一致。
 */
import { createHarness, createClock } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

const WINDOW = 800;
const INSIDE = 400;
const OUTSIDE = 1600;

runCase('dedupe', (tap) => {
  const clock = createClock(1_000_000);
  const h = createHarness({ clock });
  h.drainAll();

  const texts = () => h.drainAll().filter((envelope) => envelope.type === 'text');
  const reset = () => { h.advance(OUTSIDE); h.drainAll(); };

  // ---- A1：同帧两个不同 raw、同一个 mapKey ----
  reset();
  h.draw('350');
  h.draw('\\C[2]350');
  const a1 = texts().map((envelope) => envelope.payload.raw);
  tap.ok(a1.length === 2 && a1.includes('350') && a1.includes('\\C[2]350'),
    'A1 同帧 350 + \\C[2]350 各得 1 条（身份=surface+raw，不是 mapKey）',
    '条数=' + a1.length + ' raws=' + JSON.stringify(a1));

  // ---- A2：同帧同一 raw 连画 10 次 ----
  reset();
  for (let i = 0; i < 10; i++) { h.draw('こんにちは'); }
  tap.eq(texts().length, 1, 'A2 同帧同一 raw 连画 10 次只 emit 1 条（防重绘风暴）');

  // ---- A3：跨 1600ms 再画同一 raw ----
  reset();
  h.draw('おはよう');
  const first = texts().length;
  h.advance(OUTSIDE);
  h.draw('おはよう');
  const second = texts().length;
  tap.ok(first === 1 && second === 1, 'A3 间隔 1600ms 后再画同一 raw 新增 1 条（不是永久去重）',
    '第一次=' + first + ' 第二次=' + second);

  // ---- A4：8×400ms 连续重绘 ----
  reset();
  let total = 0;
  for (let i = 0; i < 8; i++) {
    h.draw('テスト');
    total += texts().length;
    h.advance(INSIDE);
  }
  tap.eq(total, 1, 'A4 持续可见（8×400ms）只 1 条（按滑动窗口抑制，不是按帧分桶）');

  // ---- A5：紧接着 +100ms 再画（续期判别） ----
  h.advance(100);
  h.draw('テスト');
  tap.eq(texts().length, 0,
    'A5 续期：8×400ms 后 +100ms 再画仍不新增（不续期的实现会多 1 条，距首次已 > 800ms）');

  // ---- A6：多身份交错 ----
  reset();
  const raws = [];
  const steps = [['あ', 0], ['い', 100], ['あ', 100], ['い', 100]];
  for (const [raw, delta] of steps) {
    h.advance(delta);
    h.draw(raw);
    raws.push(...texts().map((envelope) => envelope.payload.raw));
  }
  tap.ok(raws.length === 2 && raws.includes('あ') && raws.includes('い'),
    'A6 交错 A,B,A,B（100ms）得 2 条（抓"全局单一 lastSeen"）',
    '条数=' + raws.length + ' raws=' + JSON.stringify(raws));

  // ---- A7：同 raw、不同 surface ----
  reset();
  h.draw('こんにちは');
  const firstSurface = texts();
  h.advance(100);
  h.drawBitmap('こんにちは');
  const secondSurface = texts();
  const surfaces = [...firstSurface, ...secondSurface].map((envelope) => envelope.payload.surface);
  tap.ok(surfaces.length === 2 && new Set(surfaces).size === 2,
    'A7 同 raw 不同 surface 各得 1 条（身份=surface+raw 的组合）',
    '条数=' + surfaces.length + ' surfaces=' + JSON.stringify([...new Set(surfaces)]));

  // ---- 窗口语义的补充：窗内续期后仍然只在窗外重新上报 ----
  reset();
  h.draw('W');
  tap.eq(texts().length, 1, 'A8 窗口基准：首次绘制立即上报');
  h.advance(WINDOW - 100);
  h.draw('W');
  tap.eq(texts().length, 0, 'A9 距上次 < 800ms：抑制（且续期）');
  h.advance(WINDOW - 100);
  h.draw('W');
  tap.eq(texts().length, 0, 'A10 若未续期此刻已距首次 1400ms，会误报；续期后仍抑制');
  h.advance(OUTSIDE);
  h.draw('W');
  tap.eq(texts().length, 1, 'A11 真正离开窗口（> 800ms 无重绘）后再现，重新上报 1 条');

  tap.note('agent.state=' + JSON.stringify(h.state()) + ' window=' + WINDOW + 'ms inside=' + INSIDE + 'ms outside=' + OUTSIDE + 'ms');
});
