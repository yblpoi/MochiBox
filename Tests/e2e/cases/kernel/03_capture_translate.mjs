/*
 * K3 —— 采集与翻译（真实 HTTP 后端，不是 passthrough）。
 *
 * 判据是三层同时成立：
 *   1) 页面侧计数：state.captured===3 且 state.translated===3；
 *   2) 产物：--out 恰好 3 条，status=translated，translated === "译:" + original；
 *   3) 后端确实被调用过（mock 的 requests.jsonl 非空）。
 * 只满足 1 或只满足 2 都可能掩盖"没走真实后端"或"没写产物"。
 */
import fs from 'node:fs';
import path from 'node:path';

import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME, readJsonl, spawnMock, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, parseReportLine, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const SENTENCES = ['こんにちは', 'ありがとう', 'さようなら'];

runCase('kernel-k3', async (tap) => {
  const paths = casePaths('mochibox-k3-');
  const recordDir = path.join(paths.dir, 'mock-records');
  fs.mkdirSync(recordDir, { recursive: true });
  const mock = await spawnMock({ mode: 'ok', recordDir });
  const app = startApp(paths, {
    gameDir: FIXTURE_GAME,
    duration: 40,
    timeoutMs: 60_000,
    args: ['--provider', 'openai', '--endpoint', 'http://127.0.0.1:' + mock.port]
  });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K3'); return; }

    // 逐句推、逐句等：三条记录必须落在不同的采集时刻，ts 才有"递增"可言
    // （同一轮 evaluate 里连推三句，performance.now() 会给出同一个毫秒数）。
    for (let index = 0; index < SENTENCES.length; index++) {
      const pushed = await app.control.eval('__e2e.push(' + JSON.stringify(SENTENCES[index]) + ')');
      tap.eq(pushed, 'true', 'K3 第 ' + (index + 1) + ' 句 __e2e.push 返回 true');
      await waitUntil(async () => (await app.control.state()).captured === index + 1, {
        timeoutMs: 15_000, label: 'captured=' + (index + 1)
      });
    }

    const state = await waitUntil(async () => {
      const current = await app.control.state();
      return (current.captured === 3 && current.translated === 3) ? current : null;
    }, { timeoutMs: 20_000, label: 'captured=3 && translated=3' });
    tap.eq(state.captured, 3, 'K3 state.captured===3');
    tap.eq(state.translated, 3, 'K3 state.translated===3');
    tap.eq(state.skipped, 0, 'K3 state.skipped===0');

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K3 exit 0（非 passthrough 且 translated>0）');

    const rows = readJsonl(paths.out);
    tap.eq(rows.length, 3, 'K3 --out 恰好 3 条');
    tap.eq(rows.map((row) => row.original), SENTENCES, 'K3 记录顺序与推送顺序一致');

    const allTranslated = rows.every((row) => row.status === 'translated');
    tap.ok(allTranslated, 'K3 每条 status===translated', JSON.stringify(rows.map((row) => row.status)));

    const matches = rows.every((row) => row.translated === '译:' + row.original);
    tap.ok(matches, 'K3 每条 translated === "译:" + original',
      JSON.stringify(rows.map((row) => [row.original, row.translated])));

    const surfacesOk = rows.every((row) => typeof row.surface === 'string' && row.surface.length > 0);
    tap.ok(surfacesOk, 'K3 每条 surface 非空', JSON.stringify(rows.map((row) => row.surface)));

    const keysOk = rows.every((row) => typeof row.key === 'string' && row.key.length > 0
      && row.key === row.original);
    tap.ok(keysOk, 'K3 每条 key 非空且等于明文原文（无控制码时 key==raw）',
      JSON.stringify(rows.map((row) => row.key)));

    const timestamps = rows.map((row) => row.ts);
    const monotonic = timestamps.every((value, index) => index === 0 || value >= timestamps[index - 1]);
    tap.ok(monotonic && timestamps[timestamps.length - 1] > timestamps[0],
      'K3 ts 非递减且末条大于首条', JSON.stringify(timestamps));

    const report = parseReportLine(app);
    tap.ok(report !== null && report.captured === 3 && report.translated === 3 && report.skipped === 0,
      'K3 报告行 captured=3 translated=3 skipped=0', report ? report.line : null);

    tap.ok(mock.requests() > 0, 'K3 mock 后端至少收到 1 个请求（确实走了 HTTP）',
      'requests=' + mock.requests());

    // mock 的退出契约：SIGTERM 后打印 requests=<N>，且与落盘条数一致。
    const recorded = mock.requests();
    await mock.stop();
    const requestsLine = mock.stdoutLines.find((line) => line.startsWith('requests='));
    tap.eq(requestsLine, 'requests=' + recorded, 'K3 mock 退出时打印 requests=N（与 requests.jsonl 条数一致）');
    assertNoCrash(tap, app, 'K3 无崩溃标记');
  } catch (error) {
    tap.fatal('K3 执行失败', error);
  } finally {
    await app.dispose();
    await mock.stop();
    paths.cleanup();
  }
});
