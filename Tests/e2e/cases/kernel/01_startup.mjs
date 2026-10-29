/*
 * K1 —— 启动与识别（内置内核）。
 *
 * 判定 engine=mz / kernel=embedded / content=816x624 / window_id 正整数 / title=E2E Fixture。
 * 这五项分别来自三条互不相同的代码路径（EngineDetector / GameScreenMetrics / NSWindow），
 * 任何一项漂移都意味着 E2E 后面所有用例的前提变了。
 */
import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, parseHttpLine, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

runCase('kernel-k1', async (tap) => {
  const paths = casePaths('mochibox-k1-');
  const app = startApp(paths, { gameDir: FIXTURE_GAME, duration: 30, timeoutMs: 60_000 });
  try {
    const rootLine = await app.waitForLine(/^play: root=/, 20_000);
    tap.ok(rootLine.includes(' engine=mz '), 'K1 engine=mz', rootLine);

    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K1'); return; }

    const httpLine = await app.waitForLine(/^play: http=/, 10_000);
    const http = parseHttpLine(httpLine);
    tap.ok(http !== null, 'K1 play: http= 行可解析', httpLine);
    if (!http) { return; }
    tap.eq(http.kernel, 'embedded', 'K1 kernel=embedded');
    tap.eq(http.width + 'x' + http.height, '816x624', 'K1 content=816x624（与 System.json 一致）');
    tap.ok(http.port >= 39310 && http.port <= 39409, 'K1 静态服务端口落在产品区间 39310–39409', httpLine);
    tap.ok(http.page.endsWith('/index.html'), 'K1 page 指向 index.html', http.page);

    const windowLine = await app.waitForLine(/^play: window_id=\d+ title=/, 10_000);
    const windowMatch = /^play: window_id=(\d+) title=(.*)$/.exec(windowLine);
    tap.ok(windowMatch !== null && Number(windowMatch[1]) > 0, 'K1 window_id 是正整数', windowLine);
    tap.eq(windowMatch ? windowMatch[2] : null, 'E2E Fixture', 'K1 title 来自 System.json gameTitle');

    const sceneLine = await app.waitForLine(/^play: scene=Scene_Map /, 20_000);
    tap.ok(sceneLine.includes('video=none/true/null'), 'K1 场景探针走到 Scene_Map（不是 none / Scene_Boot）', sceneLine);

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K1 quit 后 exit 0');
    assertNoCrash(tap, app, 'K1 无崩溃标记');
  } catch (error) {
    tap.fatal('K1 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
