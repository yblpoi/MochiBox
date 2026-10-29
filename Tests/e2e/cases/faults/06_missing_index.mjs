/*
 * F6 —— engine 是 mz，但目录里没有 index.html。
 *
 * 这是用户最常见的目录错误（只拷了 js/ 与 data/，漏了入口页），必须给 web_root_missing +
 * 退出码 3，而不是"跑起来但 captured=0"。断言走的是产品契约（environmentCodes → 3），
 * 不是"只要非 0 就行"。
 */
import fs from 'node:fs';
import path from 'node:path';

import { runCase } from '../../lib/tap.mjs';
import {
  assertNoCrash, casePaths, noAqua, skipForNoAqua, startApp
} from '../_kernel_kit.mjs';

runCase('kernel-f6', async (tap) => {
  const paths = casePaths('mochibox-f6-');
  const gameDir = path.join(paths.dir, 'game-no-index');
  fs.mkdirSync(path.join(gameDir, 'js'), { recursive: true });
  fs.writeFileSync(path.join(gameDir, 'js', 'rmmz_core.js'), '// empty shell for engine detection\n');
  fs.mkdirSync(path.join(gameDir, 'data'), { recursive: true });
  fs.writeFileSync(path.join(gameDir, 'data', 'System.json'), JSON.stringify({ gameTitle: 'no-index' }));

  const app = startApp(paths, {
    gameDir, controlPath: null, duration: 5, timeoutMs: 60_000
  });
  try {
    const exit = await app.waitForExit(20_000);
    // 无 Aqua 时产品在更早的入口就 exit 3（kernel_no_desktop_session），这条用例无意义 → SKIP。
    if (noAqua(app)) { skipForNoAqua(tap, 'F6'); return; }
    tap.eq(exit, 3, 'F6 exit 3（环境缺口）');

    const rootLine = app.line(/^play: root=/);
    tap.ok(rootLine !== null && rootLine.includes('engine=mz'), 'F6 engine 仍识别为 mz', rootLine);

    const codeLine = app.line(/^error_code: /);
    tap.eq(codeLine, 'error_code: web_root_missing', 'F6 error_code: web_root_missing');

    const envLine = app.line(/^play: environment=/);
    tap.eq(envLine, 'play: environment=web_root_missing', 'F6 play: environment=web_root_missing');

    const failLine = app.line(/^play failed: /);
    tap.ok(failLine !== null && failLine.includes('index.html'),
      'F6 失败文案明确提到缺 index.html', failLine);
    assertNoCrash(tap, app, 'F6 无崩溃标记');
  } catch (error) {
    tap.fatal('F6 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
