/*
 * D9 —— 运行不改游戏目录（AC-10.5）
 *
 * 判据（不是"进程没报错"）：
 *   1) 起会话前对 Fixtures/e2e_game 做全目录哈希（逐文件 sha256 + 文件集合 + 汇总摘要）；
 *   2) 真跑一次内置内核会话（--play + --close-after 5，走用户关窗分支）；
 *   3) 会话结束后重新哈希，文件集合与每个文件的 sha256 必须完全相同 —— 新增/删除/修改任一都失败；
 *   4) 游戏目录里不得出现 ManualTransFile.json（导出是显式动作，未点就不该有）。
 *
 * 依据：docs/prd.md AC-10.5 原文（"未导出时游戏目录文件哈希与操作前一致"）；
 * Sources/Infra/FullTextStore.swift:8-10（"为什么不用游戏目录：默认不污染游戏目录"）。
 *
 * 桌面依赖：本层只有这一条需要 Aqua（WKWebView 建窗）。无桌面时打 SKIP，不算失败。
 */
import fs from 'node:fs';
import path from 'node:path';

import { runCase } from '../../lib/tap.mjs';
import { BIN, FIXTURE_GAME, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, parseReportLine, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';
import { diffTree, hashTree } from './_domain_kit.mjs';

runCase('domain-d9', async (tap) => {
  // 环境缺口（与 no_aqua 同级）：没有二进制就没有"真会话"，打 SKIP 而不是伪造断言。
  if (!fs.existsSync(BIN)) {
    tap.ok(true, 'D9 真会话 # SKIP 产品二进制不存在（先跑 bash Scripts/build.sh）');
    return;
  }

  const paths = casePaths('mochibox-d9-');
  const before = hashTree(FIXTURE_GAME);
  tap.ok(before.files.length > 0, 'D9 fixture 目录非空（哈希有可比对象）', '文件数=' + before.files.length);

  let skipped = false;
  const app = startApp(paths, {
    gameDir: FIXTURE_GAME,
    duration: 45,
    timeoutMs: 90_000,
    args: ['--close-after', '5']
  });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) {
      skipForNoAqua(tap, 'D9');
      skipped = true;
    } else {
      // 阳性对照：真采一句 + 真回绘，让这次运行走完"采集 → 翻译 → 下发"全链路，
      // 否则 captured=0 时产品以 1 退出（AttachCLI.swift:569），"目录没变"就成了"什么都没跑"。
      await app.control.eval('__e2e.push("こんにちは")');
      const captured = await waitUntil(async () => {
        const state = await app.control.state();
        return state.captured === 1 ? state : null;
      }, { timeoutMs: 10_000, label: 'captured=1' });
      tap.eq(captured.captured, 1, 'D9 会话内已采集 1 句（AC-10.5 的前置：链路真的跑过）');

      // 关窗收尾的**语义契约**是"到点 → 窗口真的关了 → 进程退出"，不是某一句话一定打印。
      // --close-after 的 detached Task 与主循环退出竞争：进程先退出就会吞掉
      // `closed=1 reason=user` 那一行（实测 stdout 只剩 fired=1 + window_closed=1）。
      // 因此以"进程退出"为同步点，再断言两条**各自独立**的关窗证据至少出现一条；
      // "是否打印 reason=user"降级为诊断，不作为判据。
      const exit = await app.waitForExit(45_000);
      const firedLine = app.line(/^play: close_after=5s fired=1/);
      const closedSignalLine = app.line(/^play: window_closed=1$/);
      const reasonLine = app.line(/^play: close_after=5s closed=\d+ reason=/);
      tap.ok(firedLine !== null || closedSignalLine !== null,
        'D9 关窗收尾确实发生（close_after fired=1 或 window_closed=1 至少其一）',
        'fired=' + JSON.stringify(firedLine) + ' window_closed=' + JSON.stringify(closedSignalLine));
      tap.eq(exit, 0, 'D9 会话正常退出（exit 0）');
      tap.note('D9 关窗诊断：reasonLine='
        + (reasonLine === null ? '(未打印；detached Task 与主循环退出竞争会吞掉该行)' : reasonLine));

      // 阳性对照：这次运行真的建了会话（否则"目录没变"可能只是什么都没跑）。
      const logsDir = path.join(paths.dir, 'logs');
      const logs = fs.existsSync(logsDir) ? fs.readdirSync(logsDir).filter((n) => n.startsWith('session-')) : [];
      tap.ok(logs.length >= 1, 'D9 本次会话在 MOCHI_DATA_DIR 写了 session 日志（证明真的跑过）', logs.join(','));

      const report = parseReportLine(app);
      tap.ok(report !== null, 'D9 输出 captured/translated 报告行', report ? report.line : null);
      assertNoCrash(tap, app, 'D9 无崩溃标记');
    }
  } catch (error) {
    tap.fatal('D9 执行失败', error);
  } finally {
    await app.dispose();
  }

  if (skipped) {
    paths.cleanup();
    return;
  }

  const after = hashTree(FIXTURE_GAME);
  const diff = diffTree(before, after);
  tap.eq(after.files.length, before.files.length, 'D9 运行后文件数量不变');
  tap.eq(after.digest, before.digest, 'D9 全目录汇总摘要与运行前一致');
  tap.eq(diff.added.join(','), '', 'D9 没有新增文件');
  tap.eq(diff.removed.join(','), '', 'D9 没有删除文件');
  tap.eq(diff.modified.join(','), '', 'D9 没有文件内容被修改');
  tap.ok(!fs.existsSync(path.join(FIXTURE_GAME, 'ManualTransFile.json')),
    'D9 未点导出时游戏目录没有 ManualTransFile.json');
  paths.cleanup();
});
