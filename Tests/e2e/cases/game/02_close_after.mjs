/*
 * G2 —— --close-after（真游戏，opt-in）。
 *
 * 判据不是"进程退出了"，而是：
 *   · play: close_after=5s closed=1 reason=user   ← 走的是用户关窗分支，不是 programmatic；
 *   · play: window_closed=1                        ← drain 循环确实收敛了；
 *   · exit 0                                       ← 关窗前已采集到文本。
 */
import { runCase } from '../../lib/tap.mjs';
import {
  assertNoCrash, casePaths, parseReportLine, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

runCase('kernel-g2', async (tap) => {
  const gameDir = process.env.MOCHI_E2E_GAME;
  if (!gameDir) {
    tap.ok(true, 'G2 --close-after # SKIP 未设置 MOCHI_E2E_GAME');
    return;
  }

  const paths = casePaths('mochibox-g2-');
  const provider = process.env.MOCHI_E2E_PROVIDER === 'openai' ? 'openai' : 'passthrough';
  const args = ['--provider', provider, '--close-after', '5'];
  if (provider === 'openai') {
    args.push('--endpoint', process.env.MOCHI_E2E_ENDPOINT || 'http://127.0.0.1:8787');
  }

  const app = startApp(paths, { gameDir, duration: 45, timeoutMs: 90_000, args });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'G2'); return; }

    const closeLine = await app.waitForLine(/^play: close_after=5s closed=1 reason=/, 30_000);
    tap.ok(closeLine.includes('reason=user'),
      'G2 --close-after 走用户关窗分支（reason=user，不是 programmatic）', closeLine);

    const windowClosed = await app.waitForLine(/^play: window_closed=1/, 30_000);
    tap.ok(windowClosed !== null, 'G2 stdout 出现 play: window_closed=1', windowClosed);

    const exit = await app.waitForExit(45_000);
    tap.eq(exit, 0, 'G2 关窗前已采集到文本 → exit 0');

    const report = parseReportLine(app);
    tap.ok(report !== null && report.captured > 0, 'G2 captured>0', report ? report.line : null);
    assertNoCrash(tap, app, 'G2 无崩溃标记');
  } catch (error) {
    tap.fatal('G2 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
