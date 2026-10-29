/*
 * F7 —— 空目录：识别不出引擎。
 *
 * 与 F6 的区别是"连引擎都不是"：必须 launcher_no_executable + 退出码 3，
 * 而不是 web_root_missing（后者会让用户去找 index.html，实际他拿错了目录）。
 */
import fs from 'node:fs';
import path from 'node:path';

import { runCase } from '../../lib/tap.mjs';
import { assertNoCrash, casePaths, noAqua, skipForNoAqua, startApp } from '../_kernel_kit.mjs';

runCase('kernel-f7', async (tap) => {
  const paths = casePaths('mochibox-f7-');
  const gameDir = path.join(paths.dir, 'empty-game');
  fs.mkdirSync(gameDir, { recursive: true });

  const app = startApp(paths, {
    gameDir, controlPath: null, duration: 5, timeoutMs: 60_000
  });
  try {
    const exit = await app.waitForExit(20_000);
    if (noAqua(app)) { skipForNoAqua(tap, 'F7'); return; }
    tap.eq(exit, 3, 'F7 exit 3（环境缺口）');

    const rootLine = app.line(/^play: root=/);
    tap.ok(rootLine !== null && rootLine.includes('engine=unknown'), 'F7 engine=unknown', rootLine);

    const codeLine = app.line(/^error_code: /);
    tap.eq(codeLine, 'error_code: launcher_no_executable', 'F7 error_code: launcher_no_executable');
    tap.eq(app.line(/^play: environment=/), 'play: environment=launcher_no_executable',
      'F7 play: environment=launcher_no_executable');

    const failLine = app.line(/^play failed: /);
    tap.ok(failLine !== null && failLine.includes('找不到可执行文件'), 'F7 失败文案说明找不到可执行文件', failLine);
    assertNoCrash(tap, app, 'F7 无崩溃标记');
  } catch (error) {
    tap.fatal('F7 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
