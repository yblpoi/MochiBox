/*
 * K9 —— 关窗语义（控制通道 close op）。
 *
 * 关窗必须走"用户点红叉"那条产品路径（simulateUserClose → windowWillClose → reason=user），
 * 而不是另一套 closeWindow()。可判定的证据链：
 *   · stdout 出现 play: window_closed=1；
 *   · 进程 exit 0（先采集到 1 句，所以不是"0 句算失败"）；
 *   · socket 文件被删除（ControlServer.stop 在 drain 结束后 unlink）。
 */
import fs from 'node:fs';

import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, parseReportLine, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

runCase('kernel-k9', async (tap) => {
  const paths = casePaths('mochibox-k9-');
  const app = startApp(paths, { gameDir: FIXTURE_GAME, duration: 40, timeoutMs: 60_000 });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K9'); return; }

    await app.control.eval('__e2e.push("こんにちは")');
    const before = await waitUntil(async () => {
      const current = await app.control.state();
      return current.captured === 1 ? current : null;
    }, { timeoutMs: 10_000, label: 'captured=1' });
    tap.eq(before.captured, 1, 'K9 关窗前已采集 1 句（让退出码有资格为 0）');

    const closed = await app.control.call('close');
    tap.ok(closed.ok === true, 'K9 close op 返回 ok=true', JSON.stringify(closed));

    const closedLine = await app.waitForLine(/play: window_closed=1/, 15_000);
    tap.ok(closedLine !== null, 'K9 stdout 出现 play: window_closed=1', closedLine);

    const exit = await app.waitForExit(20_000);
    tap.eq(exit, 0, 'K9 关窗后 exit 0（不伪造成功，也不是失败）');
    tap.ok(!fs.existsSync(paths.socket), 'K9 退出后 socket 文件已删除', paths.socket);

    const report = parseReportLine(app);
    tap.ok(report !== null && report.captured === 1 && report.translated === 1 && report.skipped === 0,
      'K9 报告行 captured=1 translated=1 skipped=0', report ? report.line : null);

    const attachLine = app.line(/^attached: /);
    tap.ok(attachLine !== null, 'K9 关窗发生在 attach 成功之后（不是 attach 失败导致的退出）', attachLine);
    assertNoCrash(tap, app, 'K9 无崩溃标记');
  } catch (error) {
    tap.fatal('K9 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
