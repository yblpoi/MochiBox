/*
 * K5 —— 800ms 滑动去重（PRD P0-08）。
 *
 * 两个方向都要验，缺一个就会放过反例：
 *   · 窗内：同一 surface + 同一 raw 连画两次 → 只产生 1 条；
 *   · 窗外：等 >800ms 再画同一句 → 必须产生第 2 条（否则"玩家反复看到同一句"永远不计数）。
 *
 * 去重签名是 surface + raw（不是 mapKey）。这里用同一 surface / 同一原文，符合被测语义。
 * 等待不是固定 sleep：先等 state 真的变成 1，再用 waitUntil 跨过 800ms 窗口。
 */
import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME, readJsonl, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const LINE = 'こんにちは';

runCase('kernel-k5', async (tap) => {
  const paths = casePaths('mochibox-k5-');
  const app = startApp(paths, { gameDir: FIXTURE_GAME, duration: 35, timeoutMs: 60_000 });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K5'); return; }

    const startedAt = Date.now();
    // 同一次 evaluate 里连推两次：间隔远小于 800ms。
    await app.control.eval('(__e2e.push(' + JSON.stringify(LINE) + '), __e2e.push(' + JSON.stringify(LINE) + '), true)');
    await waitUntil(async () => (await app.control.state()).captured === 1, {
      timeoutMs: 10_000, label: '窗内两次只采集 1 条'
    });
    const afterWindowHit = await app.control.state();
    tap.eq(afterWindowHit.captured, 1, 'K5 800ms 内重复推送只产生 1 条');

    // 跨过 800ms 窗口（用 deadline 而不是固定 sleep）。
    await waitUntil(() => Date.now() - startedAt >= 950, {
      timeoutMs: 5_000, intervalMs: 20, label: '跨过 800ms 去重窗口'
    });
    await app.control.eval('__e2e.push(' + JSON.stringify(LINE) + ')');
    await waitUntil(async () => (await app.control.state()).captured === 2, {
      timeoutMs: 10_000, label: '窗外再推产生第 2 条'
    });

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K5 quit 后 exit 0');

    const rows = readJsonl(paths.out);
    tap.eq(rows.length, 2, 'K5 --out 恰好 2 条（1 条窗内 + 1 条窗外）');
    tap.ok(rows.every((row) => row.original === LINE && row.key === LINE),
      'K5 两条记录的 original/key 都是同一句', JSON.stringify(rows));
    if (rows.length === 2) {
      tap.ok(rows[1].ts - rows[0].ts >= 800,
        'K5 两条记录的 ts 间隔 >= 800ms（证明确实跨过了窗口）',
        'delta=' + (rows[1].ts - rows[0].ts));
    }
    assertNoCrash(tap, app, 'K5 无崩溃标记');
  } catch (error) {
    tap.fatal('K5 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
