/*
 * F9 —— --control 缺参数（后面没有路径 / 下一个 token 是开关）。
 *
 * 参数错误必须 exit 2 并打印用法；不能把 --headless 之类当成 socket 路径 ——
 * 那会让"我以为开了控制通道"变成"悄悄没开"。
 */
import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME } from '../../lib/app.mjs';
import { casePaths, startApp } from '../_kernel_kit.mjs';

runCase('kernel-f9', async (tap) => {
  const paths = casePaths('mochibox-f9-');
  const app = startApp(paths, {
    gameDir: FIXTURE_GAME,
    controlPath: null,
    duration: 5,
    timeoutMs: 30_000,
    args: ['--control']
  });
  try {
    const exit = await app.waitForExit(15_000);
    tap.eq(exit, 2, 'F9 --control 缺参数 → exit 2');
    tap.ok(app.stderrText.includes('用法:'), 'F9 stderr 打印用法', app.stderrText.trim().split('\n')[0]);
    tap.ok(app.line(/^play: http=/) === null, 'F9 参数错误时不启动会话');
  } catch (error) {
    tap.fatal('F9 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
