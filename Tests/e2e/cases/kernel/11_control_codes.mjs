/*
 * K11 —— 控制码与多段文本。
 *
 * 这一条防的是"译文串色/串人名"：\C[2] 是颜色、\N[1] 是角色名插入码。
 * 判据不是"看起来像"，而是 **key / 分段数 / 回填后的精确字符串**：
 *   · key 只由 text 段用 U+001F 连接（控制码不参与）；
 *   · 回填时 code 段必须原样留在原位（颜色码还在颜色码的位置，名字码还在名字码的位置）；
 *   · 同一句推两次（跨 800ms），key 与 translated 必须逐字节一致。
 */
import fs from 'node:fs';
import path from 'node:path';

import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME, readJsonl, spawnMock, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const RAW = '\\C[2]勇者\\C[0]よ、\\N[1]だ';
const EXPECTED_KEY = '勇者\u001fよ、\u001fだ';
const EXPECTED_TRANSLATED = '\\C[2]译:勇者\\C[0]よ、\\N[1]だ';

const SEGMENT_PROBE = 'JSON.stringify((function () {'
  + ' var raw = ' + JSON.stringify(RAW) + ';'
  + ' var segments = __mochibox.splitSegments(raw);'
  + ' var text = 0; var code = 0;'
  + ' for (var i = 0; i < segments.length; i++) {'
  + '   if (segments[i].kind === "text") { text++; } else { code++; }'
  + ' }'
  + ' return { key: __mochibox.mapKeyOf(raw), segments: segments, textCount: text, codeCount: code,'
  + '   probe: JSON.parse(__mochibox.probe()) };'
  + '})())';

runCase('kernel-k11', async (tap) => {
  const paths = casePaths('mochibox-k11-');
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
    if (!started.ready) { skipForNoAqua(tap, 'K11'); return; }

    await app.control.eval('__e2e.push(' + JSON.stringify(RAW) + ')');
    await waitUntil(async () => {
      const current = await app.control.state();
      return current.captured === 1 && current.translated === 1 ? current : null;
    }, { timeoutMs: 20_000, label: 'captured=1 && translated=1' });

    const probe = JSON.parse(await app.control.eval(SEGMENT_PROBE));
    tap.eq(probe.key, EXPECTED_KEY, 'K11 key 只由 text 段组成（控制码被剥掉）');
    tap.eq(probe.textCount, 3, 'K11 text 段数===3');
    tap.eq(probe.codeCount, 3, 'K11 code 段数===3（\\C[2] / \\C[0] / \\N[1]）');
    tap.eq(probe.segments.length, 6, 'K11 segments 总数===6（3 text + 3 code）');

    // 同一句再推一次：跨过去重窗口，且此时已有译文 → lookup 命中、replaced 递增。
    const repeatAt = Date.now();
    await waitUntil(() => Date.now() - repeatAt >= 950, {
      timeoutMs: 5_000, intervalMs: 20, label: '跨过 800ms 去重窗口'
    });
    await app.control.eval('__e2e.push(' + JSON.stringify(RAW) + ')');
    const state2 = await waitUntil(async () => {
      const current = await app.control.state();
      return current.captured === 2 ? current : null;
    }, { timeoutMs: 20_000, label: 'captured=2' });
    tap.eq(state2.captured, 2, 'K11 第二次推送产生第 2 条记录');
    const probe2 = JSON.parse(await app.control.eval('__mochibox.probe()'));
    tap.ok(probe2.replaced >= 1, 'K11 第二次绘制命中译文（probe.replaced>=1）', JSON.stringify(probe2));

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K11 quit 后 exit 0');

    const rows = readJsonl(paths.out);
    tap.eq(rows.length, 2, 'K11 --out 恰好 2 条');
    tap.ok(rows.every((row) => row.original === RAW), 'K11 两条 original 都是带控制码的原串',
      JSON.stringify(rows.map((row) => row.original)));
    tap.ok(rows.every((row) => row.key === EXPECTED_KEY), 'K11 两条 key 稳定且等于期望值',
      JSON.stringify(rows.map((row) => row.key)));
    tap.ok(rows.every((row) => row.translated === EXPECTED_TRANSLATED),
      'K11 译文把文字回填进 text 段、控制码原样留在原位',
      JSON.stringify(rows.map((row) => row.translated)));
    if (rows.length > 0) {
      const translated = rows[0].translated || '';
      tap.ok(translated.indexOf('\\C[2]') === 0, 'K11 颜色码 \\C[2] 仍在行首', translated);
      tap.ok(translated.indexOf('\\N[1]') === translated.length - '\\N[1]だ'.length,
        'K11 名字码 \\N[1] 仍紧邻它原本修饰的「だ」', translated);
    }
    assertNoCrash(tap, app, 'K11 无崩溃标记');
  } catch (error) {
    tap.fatal('K11 执行失败', error);
  } finally {
    await app.dispose();
    await mock.stop();
    paths.cleanup();
  }
});
