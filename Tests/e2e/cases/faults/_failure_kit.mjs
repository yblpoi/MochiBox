/*
 * _failure_kit.mjs —— F1–F5（翻译后端故障）的共享执行器。
 *
 * 文件名下划线开头：run.mjs 不会把它当 case 跑。
 *
 * 判定"失败是**可诊断的失败**"，四条同时成立：
 *   1) 进程没有被信号杀死、没有 fatal error（不崩）；
 *   2) 退出码 1（captured>0 但 translated==0 → report() 的语义）；
 *   3) stdout 有 translate failed: MochiBoxError(<期望码>)；
 *   4) 报告行 captured=1 translated=0。
 * 只看"退出码非 0"会把 attach 失败、参数错误也当成后端故障 —— 那就不是在测后端了。
 */
import fs from 'node:fs';
import path from 'node:path';

import { FIXTURE_GAME, spawnMock, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, parseReportLine, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

export async function runTranslateFault(tap, options) {
  const paths = casePaths(options.prefix);
  let mock = null;
  let endpoint = options.endpoint;
  if (options.mode) {
    const recordDir = path.join(paths.dir, 'mock-records');
    fs.mkdirSync(recordDir, { recursive: true });
    mock = await spawnMock({ mode: options.mode, recordDir });
    endpoint = 'http://127.0.0.1:' + mock.port;
  }

  const app = startApp(paths, {
    gameDir: FIXTURE_GAME,
    duration: 8,
    timeoutMs: 60_000,
    args: ['--provider', 'openai', '--endpoint', endpoint]
  });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, options.name); return; }

    await app.control.eval('__e2e.push("こんにちは")');
    await waitUntil(async () => (await app.control.state()).captured === 1, {
      timeoutMs: 10_000, label: options.name + ' captured=1'
    });

    const failLine = await app.waitForLine(/^translate failed: /, 20_000);
    tap.ok(failLine.includes(options.expectCode),
      options.name + ' stdout 出现 translate failed: ' + options.expectCode, failLine);

    const exit = await app.waitForExit(30_000);
    tap.eq(exit, 1, options.name + ' exit 1（后端失败不能以 0 冒充成功）');

    const report = parseReportLine(app);
    tap.ok(report !== null && report.captured === 1 && report.translated === 0,
      options.name + ' 报告行 captured=1 translated=0', report ? report.line : null);

    if (mock) {
      tap.ok(mock.requests() > 0, options.name + ' mock 收到了请求（失败发生在后端而不是更早）',
        'requests=' + mock.requests());
    }
    assertNoCrash(tap, app, options.name + ' 无崩溃标记（无 fatal error / 无信号）');
  } catch (error) {
    tap.fatal(options.name + ' 执行失败', error);
  } finally {
    await app.dispose();
    if (mock) { await mock.stop(); }
    paths.cleanup();
  }
}
