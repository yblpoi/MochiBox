/*
 * K4 —— 跳过规则（numeric / punctuation / whitespace）。
 *
 * 跳过是**功能**，不是异常：记录必须照常写进 --out，只是 status=skipped 且带 skipReason，
 * 并且绝不写 translated 字段（写了就是"假译文"）。同时 state.skipped 必须等于预期条数 ——
 * 少一条说明 Agent 把某句吞了，多一条说明去重/判定漂移。
 */
import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME, readJsonl, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, parseReportLine, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const CASES = [
  { text: '350', reason: 'numeric' },
  { text: '！？', reason: 'punctuation' },
  { text: '　', reason: 'whitespace' }
];

runCase('kernel-k4', async (tap) => {
  const paths = casePaths('mochibox-k4-');
  const app = startApp(paths, { gameDir: FIXTURE_GAME, duration: 30, timeoutMs: 60_000 });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K4'); return; }

    await app.control.eval('__e2e.pushMany(' + JSON.stringify(CASES.map((item) => item.text)) + ')');
    const state = await waitUntil(async () => {
      const current = await app.control.state();
      return (current.captured === 3 && current.skipped === 3) ? current : null;
    }, { timeoutMs: 20_000, label: 'captured=3 && skipped=3' });

    tap.eq(state.captured, 3, 'K4 state.captured===3（跳过句仍算采集）');
    tap.eq(state.skipped, 3, 'K4 state.skipped===3');
    tap.eq(state.translated, 0, 'K4 state.translated===0');

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K4 quit 后 exit 0');

    const rows = readJsonl(paths.out);
    tap.eq(rows.length, 3, 'K4 --out 恰好 3 条（跳过句不能在产物里消失）');
    for (const sample of CASES) {
      const row = rows.find((item) => item.original === sample.text);
      tap.ok(row !== undefined, 'K4 记录里存在 ' + JSON.stringify(sample.text), JSON.stringify(rows.map((item) => item.original)));
      if (!row) { continue; }
      tap.eq(row.status, 'skipped', 'K4 ' + JSON.stringify(sample.text) + ' status===skipped');
      tap.eq(row.skipReason, sample.reason, 'K4 ' + JSON.stringify(sample.text) + ' skipReason===' + sample.reason);
      tap.ok(!Object.prototype.hasOwnProperty.call(row, 'translated'),
        'K4 ' + JSON.stringify(sample.text) + ' 不写 translated 字段（避免假译文）',
        JSON.stringify(row));
    }

    const report = parseReportLine(app);
    tap.ok(report !== null && report.skipped === 3
      && report.reasons.numeric === 1 && report.reasons.punctuation === 1 && report.reasons.whitespace === 1,
      'K4 报告行 skipped=3 且三种 reason 各 1', report ? report.line : null);
    assertNoCrash(tap, app, 'K4 无崩溃标记');
  } catch (error) {
    tap.fatal('K4 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
