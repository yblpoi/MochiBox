/*
 * F10 —— 静态服务端口被占用。
 *
 * 产品契约（Sources/Adapters/Launcher/WebPortAssignments.swift）：
 *   1) 候选端口由 webRoot 规范路径**确定性派生**（sha256("mochibox-web-v1|path") % 100 + 39310）；
 *   2) 候选被占 → 线性探测下一个空闲端口（必须绕开，不能报错）；
 *   3) 100 个全被占 → port_unavailable + 退出码 3。
 *
 * 两段都验：只验 (3) 会掩盖"能绕开却误报 busy"的回归，只验 (2) 会掩盖"绕不开也不报错"。
 */
import { runCase } from '../../lib/tap.mjs';
import {
  FIXTURE_GAME, WEB_PORT_HIGH, WEB_PORT_LOW, candidateWebPort, occupyPort, probePortFree, waitUntil
} from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, parseHttpLine, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

runCase('kernel-f10', async (tap) => {
  const paths = casePaths('mochibox-f10-');
  const candidate = candidateWebPort(FIXTURE_GAME);
  tap.ok(candidate >= WEB_PORT_LOW && candidate <= WEB_PORT_HIGH,
    'F10 派生端口落在 39310–39409（与实现同算法）', 'candidate=' + candidate);

  let holder = null;
  const all = [];
  /** 本 case 自己占过的端口：收尾后逐个复查，任何一个还能 listen 就说明没释放。 */
  const held = [];
  let firstApp = null;
  try {
    holder = await occupyPort(candidate);
    held.push(candidate);
    // 阳性对照：占住 = 现在别人绑不上（不是"我调用了一个函数"）。
    tap.eq(await probePortFree(candidate), false, 'F10 已占住候选端口 ' + candidate + '（此刻他人无法 bind）');

    firstApp = startApp(paths, { gameDir: FIXTURE_GAME, duration: 30, timeoutMs: 60_000 });
    const started = await waitKernelReady(firstApp);
    if (!started.ready) { skipForNoAqua(tap, 'F10'); return; }

    const http = parseHttpLine(firstApp.line(/^play: http=/));
    tap.ok(http !== null && http.port !== candidate,
      'F10 候选端口被占时自动绕开（play: http= 用的是另一个端口）',
      http ? 'candidate=' + candidate + ' actual=' + http.port : null);
    tap.ok(http !== null && http.port >= WEB_PORT_LOW && http.port <= WEB_PORT_HIGH,
      'F10 绕开后的端口仍在产品区间内', http ? http.port : null);

    await firstApp.control.eval('__e2e.push("こんにちは")');
    await waitUntil(async () => (await firstApp.control.state()).captured === 1, {
      timeoutMs: 10_000, label: 'captured=1'
    });
    tap.eq(await quitAndWait(firstApp), 0, 'F10 绕开端口后仍能正常采集并 exit 0');
    assertNoCrash(tap, firstApp, 'F10 第一段无崩溃标记');

    // 第二段：占满整个区间。
    let bound = 0;
    let alreadyBusy = 0;
    for (let port = WEB_PORT_LOW; port <= WEB_PORT_HIGH; port++) {
      if (port === candidate) { bound += 1; continue; }
      try {
        all.push(await occupyPort(port));
        held.push(port);
        bound += 1;
      } catch (error) {
        alreadyBusy += 1;
      }
    }
    tap.eq(bound + alreadyBusy, WEB_PORT_HIGH - WEB_PORT_LOW + 1,
      'F10 区间内 100 个端口全部不可用', 'bound=' + bound + ' alreadyBusy=' + alreadyBusy);

    const secondPaths = casePaths('mochibox-f10b-');
    const secondApp = startApp(secondPaths, {
      gameDir: FIXTURE_GAME, controlPath: null, duration: 5, timeoutMs: 60_000
    });
    try {
      const exit = await secondApp.waitForExit(20_000);
      tap.eq(exit, 3, 'F10 端口耗尽 → exit 3');
      tap.eq(secondApp.line(/^error_code: /), 'error_code: port_unavailable',
        'F10 端口耗尽 → error_code: port_unavailable');
      tap.eq(secondApp.line(/^play: environment=/), 'play: environment=port_unavailable',
        'F10 端口耗尽 → play: environment=port_unavailable');
      assertNoCrash(tap, secondApp, 'F10 第二段无崩溃标记');
    } finally {
      await secondApp.dispose();
      secondPaths.cleanup();
    }
  } catch (error) {
    tap.fatal('F10 执行失败', error);
  } finally {
    if (firstApp) { await firstApp.dispose(); }
    // 逆序关闭，且每一步都等 close 回调（occupyPort.close 内部先 destroy 已接受连接）。
    for (const item of all.slice().reverse()) { await item.close(); }
    if (holder) { await holder.close(); }

    // 端口泄漏的唯一可信判据：收尾之后**真的**还能重新监听。之前只"调用 close"，
    // 连接没断时回调不来，端口留到下一个 case —— 表现为偶发 EADDRINUSE 39330。
    const stillBusy = [];
    for (const port of held) {
      if (!await probePortFree(port)) { stillBusy.push(port); }
    }
    tap.eq(stillBusy, [], 'F10 收尾后 ' + held.length + ' 个自占端口全部可重新监听（无残留）');
    paths.cleanup();
  }
});
