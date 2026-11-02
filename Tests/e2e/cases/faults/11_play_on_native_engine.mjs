/*
 * F11 —— `--play <XP 目录>`：引擎只有原生运行时后端，必须在 launch 之前拒绝。
 *
 * 为什么这条必须有：早先 `--play` 是先 `launcher.launch(...)` 再按 transport 拒绝，
 * 症状是**游戏窗口闪一下**才报错。判据因此不是"退出码非 0"，而是：
 *   1) exit 3 + `error_code: wrong_play_mode`（脚本能按码分支）；
 *   2) **没有起过进程**：`<data>/logs/` 里没有 `mkxpz-*.log`（那个文件由
 *      ChildProcessLauncher 在 `Process.run()` 之前创建），会话日志里没有"启动 mkxp-z"；
 *   3) 没进页面链路：stdout 没有 `play: http=`。
 *
 * 不需要 Aqua：门禁在任何窗口/内核之前。
 */
import fs from 'node:fs';
import path from 'node:path';

import { REPO_ROOT } from '../../lib/app.mjs';
import { runCase } from '../../lib/tap.mjs';
import { assertNoCrash, casePaths, startApp } from '../_kernel_kit.mjs';

runCase('kernel-f11', async (tap) => {
  const paths = casePaths('mochibox-f11-');
  const gameDir = path.join(paths.dir, 'xp-game');
  fs.cpSync(path.join(REPO_ROOT, 'Fixtures/rmxp'), gameDir, { recursive: true });

  const started = Date.now();
  const app = startApp(paths, { gameDir, controlPath: null, duration: 5, timeoutMs: 30_000 });
  try {
    const exit = await app.waitForExit(20_000);
    const elapsed = Date.now() - started;

    tap.eq(exit, 3, 'F11 exit 3（启动前拒绝也是可诊断失败）');
    const rootLine = app.line(/^play: root=/);
    tap.ok(rootLine !== null && rootLine.includes('engine=rgss1'),
      'F11 引擎仍如实报 rgss1', rootLine);
    tap.eq(app.line(/^error_code: /), 'error_code: wrong_play_mode', 'F11 error_code: wrong_play_mode');
    tap.eq(app.line(/^play: environment=/), 'play: environment=wrong_play_mode',
      'F11 play: environment=wrong_play_mode');

    const failLine = app.line(/^play failed: /);
    tap.ok(failLine !== null && failLine.includes('--play-native'),
      'F11 失败文案点名正确命令', failLine);

    // 没起进程的硬证据：launch_log 为空。
    const logsDir = path.join(paths.dir, 'logs');
    const names = fs.existsSync(logsDir) ? fs.readdirSync(logsDir) : [];
    const launchLogs = names.filter((name) => name.startsWith('mkxpz-'));
    tap.eq(launchLogs.join(','), '', 'F11 launch_log 为空（没有 mkxpz-*.log）');

    const sessions = names.filter((name) => name.startsWith('session-'));
    tap.eq(sessions.length, 1, 'F11 会话日志恰好 1 份（证明 --play 真的跑过）', sessions.join(','));
    if (sessions.length === 1) {
      const text = fs.readFileSync(path.join(logsDir, sessions[0]), 'utf8');
      tap.ok(!text.includes('启动 mkxp-z'), 'F11 会话日志里没有"启动 mkxp-z"');
    }

    tap.ok(app.stdoutText.indexOf('play: http=') < 0, 'F11 没有进入页面链路（无 play: http=）');
    tap.ok(elapsed < 5000, 'F11 立即退出（远小于 --duration 5s）', 'elapsed=' + elapsed + 'ms');
    assertNoCrash(tap, app, 'F11 无崩溃标记');
  } catch (error) {
    tap.fatal('F11 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
