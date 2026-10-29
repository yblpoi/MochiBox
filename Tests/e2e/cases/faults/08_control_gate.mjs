/*
 * F8 —— 控制通道门禁：没有 MOCHI_E2E=1 时 --control 必须被拒绝。
 *
 * 这条门禁是安全边界：通道能跑任意 JS，产品会话里绝不能凭空多出这个本地入口。
 * 判据：exit 2 + error_code: control_requires_e2e + **没有** play: http=（说明在起窗口之前就被拦住）。
 */
import fs from 'node:fs';

import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME } from '../../lib/app.mjs';
import { casePaths, startApp } from '../_kernel_kit.mjs';

runCase('kernel-f8', async (tap) => {
  const paths = casePaths('mochibox-f8-');
  const app = startApp(paths, {
    gameDir: FIXTURE_GAME,
    duration: 5,
    timeoutMs: 30_000,
    e2e: false,
    env: { MOCHI_E2E: '0' }
  });
  try {
    const exit = await app.waitForExit(15_000);
    tap.eq(exit, 2, 'F8 未设 MOCHI_E2E 时 --control → exit 2');
    tap.eq(app.line(/^error_code: /), 'error_code: control_requires_e2e',
      'F8 error_code: control_requires_e2e');
    tap.ok(app.line(/^play: http=/) === null, 'F8 在起窗口之前就被拦住（没有 play: http=）');
    tap.ok(!fs.existsSync(paths.socket), 'F8 没有创建 socket 文件', paths.socket);
  } catch (error) {
    tap.fatal('F8 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
