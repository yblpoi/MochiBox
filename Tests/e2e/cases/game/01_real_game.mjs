/*
 * G1 —— 真游戏冒烟（opt-in，默认 SKIP）。
 *
 * 只有设置 MOCHI_E2E_GAME（游戏目录）才跑。45s 内必须：engine ∈ {mv, mz}、captured>0、
 * translated>0、窗口标题非空、exit 0。这五条一起看才能排除"窗口开了但一句没采到"的假成功。
 *
 * 可选环境变量：
 *   MOCHI_E2E_PROVIDER=openai + MOCHI_E2E_ENDPOINT=<url>   用真实/自定义后端（默认 passthrough）
 */
import { runCase } from '../../lib/tap.mjs';
import { AGENT_PATH } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, parseReportLine, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

runCase('kernel-g1', async (tap) => {
  const gameDir = process.env.MOCHI_E2E_GAME;
  if (!gameDir) {
    tap.ok(true, 'G1 真游戏冒烟 # SKIP 未设置 MOCHI_E2E_GAME');
    return;
  }

  const paths = casePaths('mochibox-g1-');
  const provider = process.env.MOCHI_E2E_PROVIDER === 'openai' ? 'openai' : 'passthrough';
  const args = ['--provider', provider];
  if (provider === 'openai') {
    args.push('--endpoint', process.env.MOCHI_E2E_ENDPOINT || 'http://127.0.0.1:8787');
  }
  tap.note('G1 gameDir=' + gameDir + ' provider=' + provider + ' agent=' + AGENT_PATH);

  const app = startApp(paths, {
    gameDir, duration: 45, timeoutMs: 90_000, args
  });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'G1'); return; }

    const exit = await app.waitForExit(75_000);
    tap.eq(exit, 0, 'G1 exit 0');

    const rootLine = app.line(/^play: root=/);
    const engine = rootLine ? /engine=([a-z0-9]+)/.exec(rootLine) : null;
    tap.ok(engine !== null && (engine[1] === 'mv' || engine[1] === 'mz'),
      'G1 engine 是 mv 或 mz', rootLine);

    const windowLine = app.line(/^play: window_id=/);
    const title = windowLine ? /title=(.*)$/.exec(windowLine) : null;
    tap.ok(title !== null && title[1].trim().length > 0, 'G1 窗口标题非空', windowLine);

    const report = parseReportLine(app);
    tap.ok(report !== null && report.captured > 0, 'G1 captured>0', report ? report.line : null);
    tap.ok(report !== null && report.translated > 0, 'G1 translated>0', report ? report.line : null);
    assertNoCrash(tap, app, 'G1 无崩溃标记');
  } catch (error) {
    tap.fatal('G1 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
