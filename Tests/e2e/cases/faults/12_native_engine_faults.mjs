/*
 * F12 —— 原生运行时的**启动前**校验：缺 Game.ini / Library 与引擎不符。
 *
 * 这两条都是"命令本身没错，是这一款游戏的数据有问题"，因此：
 *   · 必须是 exit 3 + `error_code:`（与其它启动失败同一个脚本化口径）；
 *   · 必须在 `Process.run()` 之前发生 —— `mkxpz-*.log` 一个都不能有：
 *     mkxp-z 缺 Game.ini 只会黑屏，拉起来再报错对用户没有任何价值。
 *
 * 两条都用 `--play-native`：`--play` 现在会在模式门就拒绝原生后端（F11），
 * 走不到这两条校验。
 */
import fs from 'node:fs';
import path from 'node:path';

import { REPO_ROOT } from '../../lib/app.mjs';
import { runCase } from '../../lib/tap.mjs';
import { assertNoCrash, casePaths, startApp } from '../_kernel_kit.mjs';

function launchLogs(paths) {
  const logsDir = path.join(paths.dir, 'logs');
  const names = fs.existsSync(logsDir) ? fs.readdirSync(logsDir) : [];
  return names.filter((name) => name.startsWith('mkxpz-'));
}

runCase('kernel-f12', async (tap) => {
  // ── (a) 缺 Game.ini ──────────────────────────────────────────────────────
  const missingPaths = casePaths('mochibox-f12a-');
  const missingDir = path.join(missingPaths.dir, 'xp-no-ini');
  fs.cpSync(path.join(REPO_ROOT, 'Fixtures/rmxp'), missingDir, { recursive: true });
  fs.rmSync(path.join(missingDir, 'Game.ini'));

  const missingApp = startApp(missingPaths, {
    // --out 只属于 --play（--play-native 没有信封），带了会被参数校验判成
    // conflicting_arguments（exit 2）—— 那样测的就不是启动校验了。
    gameDir: missingDir, controlPath: null, out: null, duration: 5, timeoutMs: 30_000, playNative: true
  });
  try {
    const exit = await missingApp.waitForExit(20_000);
    tap.eq(exit, 3, 'F12a 缺 Game.ini → exit 3');
    const rootLine = missingApp.line(/^play: root=/);
    tap.ok(rootLine !== null && rootLine.includes('engine=rgss1'),
      'F12a 引擎仍识别为 rgss1（Data/*.rxdata 是证据）', rootLine);
    tap.eq(missingApp.line(/^error_code: /), 'error_code: game_ini_missing',
      'F12a error_code: game_ini_missing');
    tap.eq(missingApp.line(/^play: environment=/), 'play: environment=game_ini_missing',
      'F12a play: environment=game_ini_missing');
    const failLine = missingApp.line(/^play failed: /);
    tap.ok(failLine !== null && failLine.includes('Game.ini'), 'F12a 失败文案点名 Game.ini', failLine);
    tap.eq(launchLogs(missingPaths).join(','), '', 'F12a launch_log 为空（校验在起进程之前）');
    tap.ok(missingApp.stdoutText.indexOf('play: backend=') < 0, 'F12a 没有拉起后端（无 play: backend=）');
    assertNoCrash(tap, missingApp, 'F12a 无崩溃标记');
  } catch (error) {
    tap.fatal('F12a 执行失败', error);
  } finally {
    await missingApp.dispose();
    missingPaths.cleanup();
  }

  // ── (b) Library 与引擎不符 ───────────────────────────────────────────────
  // VX 的数据（Data/*.rvdata）配 XP 的 Library=RGSS104E.dll：
  // 检测按 rgss2 赢（优先级高于 Game.ini 给出的 rgss1），校验必须拒绝。
  const mismatchPaths = casePaths('mochibox-f12b-');
  const mismatchDir = path.join(mismatchPaths.dir, 'vx-fake-xp');
  fs.cpSync(path.join(REPO_ROOT, 'Fixtures/rmvx'), mismatchDir, { recursive: true });
  fs.writeFileSync(
    path.join(mismatchDir, 'Game.ini'),
    ['[Game]', 'RTP=RPGVX', 'Library=RGSS104E.dll', 'Scripts=Data/Scripts.rvdata', ''].join('\n')
  );

  const mismatchApp = startApp(mismatchPaths, {
    gameDir: mismatchDir, controlPath: null, out: null, duration: 5, timeoutMs: 30_000, playNative: true
  });
  try {
    const exit = await mismatchApp.waitForExit(20_000);
    tap.eq(exit, 3, 'F12b Library 不符 → exit 3');
    const rootLine = mismatchApp.line(/^play: root=/);
    tap.ok(rootLine !== null && rootLine.includes('engine=rgss2'),
      'F12b 检测结果仍是 rgss2（Data/*.rvdata）', rootLine);
    tap.eq(mismatchApp.line(/^error_code: /), 'error_code: runtime_version_mismatch',
      'F12b error_code: runtime_version_mismatch');
    tap.eq(mismatchApp.line(/^play: environment=/), 'play: environment=runtime_version_mismatch',
      'F12b play: environment=runtime_version_mismatch');
    const failLine = mismatchApp.line(/^play failed: /);
    tap.ok(failLine !== null && failLine.includes('RGSS104E.dll'),
      'F12b 失败文案带 Library 原值', failLine);
    tap.eq(launchLogs(mismatchPaths).join(','), '', 'F12b launch_log 为空（校验在起进程之前）');
    assertNoCrash(tap, mismatchApp, 'F12b 无崩溃标记');
  } catch (error) {
    tap.fatal('F12b 执行失败', error);
  } finally {
    await mismatchApp.dispose();
    mismatchPaths.cleanup();
  }
});
