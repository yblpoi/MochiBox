/*
 * K12 —— 消息窗**真的画了什么**（H2：内核层对"消息窗不绘制"零反应）。
 *
 * 为什么需要这一条：
 *   K3/K5/K6 的判据是 Agent 上报的 TextEvent 与 --out 产物，采集发生在
 *   `Window_Message.startMessage` 的 wrapper 里（读 `$gameMessage._texts`）。
 *   把夹具的 `this._texts` 打空（= 消息窗一行都不画）后重跑 kernel 层，
 *   11 个 case / 130 条断言仍然全绿 —— 因为没有任何断言读"实际绘制"。
 *
 * 本用例把绘制面变成判据：
 *   1) 推 3 句 → 等 captured=3 && translated=3 → `__e2e.render()` 让消息窗真的画一次；
 *   2) drawLog 里最后 3 条绘制的文本 === "译:" + 原文（openai 模式）；
 *   3) 绘制次数 ≥ 采集数（每句至少画一次，不是"上报了就算"）；
 *   4) 绘制时的 `contents.fontSize` === round(基准字号 × config.fontScale)；
 *   5) 阴性对照：config.enabled=false 后重推同样 3 句，画的是原文而不是译文。
 *
 * `__e2e.render()` 走的是被 Agent hook 的 Window_Base.drawTextEx（真实绘制面），
 * 不是直接往 canvas 涂像素；fontSize 因此在 wrapper 内层取值（fontScale 已生效）。
 * 它会让"已画出的译文"再被采集一次（真实游戏重绘同一页也是这个行为），
 * 所以本用例的判据只用 render 之前的 captured，不断言事后计数。
 */
import fs from 'node:fs';
import path from 'node:path';

import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME, spawnMock, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const SENTENCES = ['こんにちは', 'ありがとう', 'さようなら'];
const FONT_SCALE = 1.25;

runCase('kernel-k12', async (tap) => {
  const paths = casePaths('mochibox-k12-');
  const recordDir = path.join(paths.dir, 'mock-records');
  fs.mkdirSync(recordDir, { recursive: true });
  const mock = await spawnMock({ mode: 'ok', recordDir });
  const app = startApp(paths, {
    gameDir: FIXTURE_GAME,
    duration: 60,
    timeoutMs: 90_000,
    args: ['--provider', 'openai', '--endpoint', 'http://127.0.0.1:' + mock.port]
  });

  /** 页面侧 JSON 求值（ControlServer 把对象/数组文本化成 JSON）。 */
  const evalJson = async (expression) => JSON.parse(await app.control.eval(expression));
  const drawCount = async () => Number(await app.control.eval('__e2e.drawCount()'));

  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K12'); return; }

    const baseFont = Number(await app.control.eval('__e2e.messageFontSize()'));
    tap.eq(baseFont, 28, 'K12 夹具消息窗基准字号 = 28（fontScale 期望值的基数）');
    tap.eq(await drawCount(), 0, 'K12 推句之前消息窗一次都没画过（drawLog 不会被启动绘制污染）');

    const configJson = JSON.stringify({ type: 'config', payload: { fontScale: FONT_SCALE } });
    await app.control.eval('__mochibox.inbox(' + JSON.stringify(configJson) + ')');
    const scaled = await evalJson('JSON.stringify(__mochibox.state)');
    tap.eq(scaled.fontScale, FONT_SCALE, 'K12 config.fontScale 已下发到页面（state.fontScale 生效）');

    // 一次推 3 句 = 一页消息（真实消息窗画的是一页多行，不是逐句单行）。
    const pushed = await app.control.eval('__e2e.pushMany(' + JSON.stringify(SENTENCES) + ')');
    tap.eq(pushed, 'true', 'K12 pushMany 一页 3 句返回 true');
    await waitUntil(async () => (await app.control.state()).captured === 3, {
      timeoutMs: 15_000, label: 'captured=3'
    });

    // 采集是绘制的前提：先确认 3 句都被 Agent 采集并拿到译文，再让消息窗画。
    const captured = await waitUntil(async () => {
      const state = await app.control.state();
      return (state.captured === 3 && state.translated === 3) ? state : null;
    }, { timeoutMs: 20_000, label: 'captured=3 && translated=3' });
    tap.eq(captured.captured, 3, 'K12 采集数 = 3（绘制判据的分母）');

    const drawnBefore = await drawCount();
    const rendered = Number(await app.control.eval('__e2e.render()'));
    tap.eq(rendered, SENTENCES.length, 'K12 render() 返回本次画出的行数 = 3');

    const drawnAfter = await drawCount();
    tap.ok(drawnAfter - drawnBefore >= captured.captured,
      'K12 绘制次数 ≥ 采集数（每句至少画一次）',
      'draws=' + (drawnAfter - drawnBefore) + ' captured=' + captured.captured);

    const log = await evalJson('JSON.stringify(__e2e.drawLog())');
    const round = log.slice(-SENTENCES.length);
    tap.eq(round.map((entry) => entry.text), SENTENCES.map((text) => '译:' + text),
      'K12 drawLog 最后 3 条绘制的文本 = "译:" + 原文（画的是译文，不是只采集到）');

    const expectedFont = Math.round(baseFont * FONT_SCALE);
    const sizes = round.map((entry) => entry.fontSize);
    tap.ok(round.length === SENTENCES.length && sizes.every((size) => size === expectedFont),
      'K12 绘制字号 = round(基准 ' + baseFont + ' × fontScale ' + FONT_SCALE + ') = ' + expectedFont,
      JSON.stringify(sizes));

    // 阴性对照：关闭翻译后，同样 3 句必须画原文。只验"画了译文"会放过"永远画译文"的实现。
    const offJson = JSON.stringify({ type: 'config', payload: { enabled: false } });
    await app.control.eval('__mochibox.inbox(' + JSON.stringify(offJson) + ')');
    const disabled = await evalJson('JSON.stringify(__mochibox.state)');
    tap.eq(disabled.enabled, false, 'K12 阴性对照前置：config.enabled=false 已生效');

    await app.control.eval('__e2e.pushMany(' + JSON.stringify(SENTENCES) + ')');
    await app.control.eval('__e2e.render()');
    const offLog = await evalJson('JSON.stringify(__e2e.drawLog())');
    const offRound = offLog.slice(-SENTENCES.length);
    tap.eq(offRound.map((entry) => entry.text), SENTENCES,
      'K12 enabled=false 时画的是原文（阴性对照）');
    tap.ok(offRound.every((entry) => !entry.text.startsWith('译:')),
      'K12 enabled=false 时绘制文本里没有 "译:" 前缀',
      JSON.stringify(offRound.map((entry) => entry.text)));

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K12 exit 0（采集与翻译都发生过）');
    tap.ok(mock.requests() > 0, 'K12 mock 后端确实收到过请求（译文来自真实 HTTP）',
      'requests=' + mock.requests());
    assertNoCrash(tap, app, 'K12 无崩溃标记');
  } catch (error) {
    tap.fatal('K12 执行失败', error);
  } finally {
    await app.dispose();
    await mock.stop();
    paths.cleanup();
  }
});
