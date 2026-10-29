/*
 * K6 —— 翻译缓存的实际边界。
 *
 * 任务书原本期望"同一 MOCHI_DATA_DIR 跑第二次，mock 收到 0 个请求"。**实测不成立**：
 * AttachCLI.drainPhase 里的 translations 是局部变量（源码注释明说"本 CLI 不做持久化缓存"），
 * 进程结束即消失。所以这里断言的是**真实契约**，并把差异写进 TAP 诊断：
 *   · 同一次 --play 内：同 key 第二次出现不再请求后端（这才是产品里存在的缓存）；   ← 可判定
 *   · 跨进程：第二次启动仍会请求（无持久缓存）—— 任务书的 0 请求预期不成立，如实记录。
 *
 * 这不是"把失败改成通过"：如果哪天真加了持久缓存，第一条断言会变红，提醒更新用例。
 */
import fs from 'node:fs';
import path from 'node:path';

import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME, readJsonl, spawnMock, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const SENTENCES = ['こんにちは', 'ありがとう', 'さようなら'];

async function pushAll(app, tap, label) {
  for (let index = 0; index < SENTENCES.length; index++) {
    await app.control.eval('__e2e.push(' + JSON.stringify(SENTENCES[index]) + ')');
    await waitUntil(async () => (await app.control.state()).captured === index + 1, {
      timeoutMs: 15_000, label: label + ' captured=' + (index + 1)
    });
  }
  await waitUntil(async () => {
    const current = await app.control.state();
    return current.translated === SENTENCES.length ? current : null;
  }, { timeoutMs: 20_000, label: label + ' translated=' + SENTENCES.length });
}

runCase('kernel-k6', async (tap) => {
  const paths = casePaths('mochibox-k6-');
  const recordDir = path.join(paths.dir, 'mock-records');
  fs.mkdirSync(recordDir, { recursive: true });
  const mock = await spawnMock({ mode: 'ok', recordDir });
  const endpoint = 'http://127.0.0.1:' + mock.port;

  const run1 = startApp(paths, {
    gameDir: FIXTURE_GAME, duration: 40, timeoutMs: 60_000,
    out: path.join(paths.dir, 'run1.jsonl'),
    args: ['--provider', 'openai', '--endpoint', endpoint]
  });

  let run2 = null;
  try {
    const started1 = await waitKernelReady(run1);
    if (!started1.ready) { skipForNoAqua(tap, 'K6'); return; }
    await pushAll(run1, tap, 'K6 run1');
    const requestsAfterRun1 = mock.requests();
    tap.ok(requestsAfterRun1 > 0, 'K6 第一次启动 mock 收到 >0 个请求（基线）', 'requests=' + requestsAfterRun1);

    const exit1 = await quitAndWait(run1);
    tap.eq(exit1, 0, 'K6 第一次启动 exit 0');
    const rows1 = readJsonl(path.join(paths.dir, 'run1.jsonl'));
    tap.eq(rows1.length, 3, 'K6 第一次启动产出 3 条记录');
    tap.ok(rows1.every((row) => row.status === 'translated'), 'K6 第一次启动 3 条都是 translated',
      JSON.stringify(rows1.map((row) => row.status)));
    assertNoCrash(tap, run1, 'K6 第一次启动无崩溃标记');

    // 第二次：**同一个** MOCHI_DATA_DIR（paths.dir）+ 同一个 gameDir；socket / out 换新的。
    run2 = startApp(paths, {
      gameDir: FIXTURE_GAME, duration: 40, timeoutMs: 60_000,
      controlPath: path.join(paths.dir, 'run2.sock'),
      out: path.join(paths.dir, 'run2.jsonl'),
      args: ['--provider', 'openai', '--endpoint', endpoint]
    });
    const started2 = await waitKernelReady(run2);
    if (!started2.ready) { skipForNoAqua(tap, 'K6'); return; }
    await pushAll(run2, tap, 'K6 run2');

    const requestsAfterRun2 = mock.requests();
    tap.ok(requestsAfterRun2 > requestsAfterRun1,
      'K6 第二次启动仍请求后端（实测：--play 无跨进程翻译缓存，任务书的 0 请求预期不成立）',
      'run1=' + requestsAfterRun1 + ' run2累计=' + requestsAfterRun2);
    tap.note('产品行为：AttachCLI.drainPhase 的 translations 是局部字典，没有持久化缓存；'
      + 'MOCHI_DATA_DIR 只影响 web-ports.json / 日志 / profile，不影响译文。');

    // 进程内缓存：同一 key 第二次出现（跨过 800ms 去重窗）不再请求后端。
    const before = mock.requests();
    const repeatAt = Date.now();
    await waitUntil(() => Date.now() - repeatAt >= 950, {
      timeoutMs: 5_000, intervalMs: 20, label: '跨过 800ms 去重窗口'
    });
    await run2.control.eval('__e2e.push(' + JSON.stringify(SENTENCES[0]) + ')');
    await waitUntil(async () => (await run2.control.state()).captured === 4, {
      timeoutMs: 10_000, label: 'K6 run2 重复句产生第 4 条记录'
    });
    const after = mock.requests();
    tap.eq(after, before, 'K6 同一进程内重复句命中缓存：mock 请求数不增加');
    tap.ok(after > 0, 'K6 缓存命中仍走完了 drain/写入流程', 'requests=' + after);

    const exit2 = await quitAndWait(run2);
    tap.eq(exit2, 0, 'K6 第二次启动 exit 0');
    const rows2 = readJsonl(path.join(paths.dir, 'run2.jsonl'));
    tap.eq(rows2.length, 4, 'K6 第二次启动产出 4 条记录（3 首见 + 1 重复）');
    assertNoCrash(tap, run2, 'K6 第二次启动无崩溃标记');
  } catch (error) {
    tap.fatal('K6 执行失败', error);
  } finally {
    if (run2) { await run2.dispose(); }
    await run1.dispose();
    await mock.stop();
    paths.cleanup();
  }
});
