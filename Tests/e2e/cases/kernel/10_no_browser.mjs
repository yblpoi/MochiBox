/*
 * K10 —— 无浏览器（内置 WKWebView 路径根本不碰 BrowserResolver）。
 *
 * 两条独立证据：
 *   1) 会话进行中，**被测进程的子孙**里没有 Chrome / Chromium / Chrome for Testing；
 *   2) 把 MOCHI_BROWSER_PATH 指到一个不存在的路径，仍然能跑通 —— 如果走了 BrowserResolver，
 *      这一行环境变量会让它直接 browser_not_found（exit 3）。
 *
 * 判据只覆盖 MochiBox 的父子子树（app.mjs: chromeProcesses(rootPid)）：全机 pgrep 快照
 * 会把宿主机上任何 argv 恰好带 "Google Chrome" 的短命进程算成泄漏（终验时误伤过一次），
 * 也会把用户本来开着的 Chrome 拉进来。用户进程与采样器都不在子树里，天然不计入。
 */
import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME, chromeProcesses, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, parseHttpLine, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

runCase('kernel-k10', async (tap) => {
  const paths = casePaths('mochibox-k10-');
  const app = startApp(paths, {
    gameDir: FIXTURE_GAME,
    duration: 30,
    timeoutMs: 60_000,
    env: { MOCHI_BROWSER_PATH: '/nonexistent/definitely-not-a-browser' }
  });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K10'); return; }

    const http = parseHttpLine(app.line(/^play: http=/));
    tap.ok(http !== null && http.kernel === 'embedded', 'K10 MOCHI_BROWSER_PATH 无效时仍走 kernel=embedded',
      app.line(/^play: http=/));
    tap.ok(!app.stdoutText.includes('browser_not_found'), 'K10 没有出现 browser_not_found（未走 BrowserResolver）');

    // 内核就绪即取一次：WKWebView 已建好；如果走了外部浏览器，它到这时一定已经起来了。
    const atReady = chromeProcesses(app.pid);
    tap.eq(atReady.length, 0, 'K10 内核就绪时被测进程没有 Chrome/Chromium 子孙',
      JSON.stringify(atReady));

    await app.control.eval('__e2e.push("こんにちは")');
    await waitUntil(async () => (await app.control.state()).captured === 1, {
      timeoutMs: 10_000, label: 'captured=1'
    });
    tap.ok(true, 'K10 无有效浏览器路径时仍完成采集');

    // 采集期间再取一次：真拉起了浏览器，这一步之后它还在跑。
    const duringRun = chromeProcesses(app.pid);
    tap.eq(duringRun.length, 0, 'K10 采集期间被测进程没有 Chrome/Chromium 子孙',
      JSON.stringify(duringRun));

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K10 exit 0');

    // 退出后子树已随进程消失，这一次只作诊断；"整机无残留"不归本用例判定（见文件头）。
    tap.note('K10 退出后 chromeProcesses(pid=' + app.pid + ')='
      + JSON.stringify(chromeProcesses(app.pid)) + '（pid 已退出，子树不存在）');
    assertNoCrash(tap, app, 'K10 无崩溃标记');
  } catch (error) {
    tap.fatal('K10 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
