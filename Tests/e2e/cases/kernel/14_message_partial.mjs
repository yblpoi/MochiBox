/*
 * K14 —— 一页多行里只有部分行有译文时，逐行降级，而不是整页退回日文。
 *
 * 背景：`Window_Message.startMessage` 的 wrapper 原来要求"每一行都命中译文"
 * 才整条写回。一页里只要有一行是纯标点占位（`？？？`/`……`，按 skip 规则
 * 本来就不送翻、永远查不到），整页就一个字都不换，玩家看到的就是日文。
 *
 * 判据落在 `$gameMessage._texts`，**不看 drawLog**：绘制期的 `drawTextEx`
 * 自己也会查表替换，用画出来的文本断言分不清"是 startMessage 换的还是绘制期
 * 换的"——那会让本用例在实现回退时仍然绿。
 *
 * **不验** Host 侧对 `start_message_*` 信封的分流：`--play` 这条路径由
 * `AttachCLI` 自己消费信封，它**不处理 `type=="error"`**（全部静默丢弃），
 * 所以日志里根本不会有这条诊断。分流的入口 `SessionController.handleEnvelope`
 * 是 private，且只有真实 adapter attach 才能触达，本层无法构造。
 * 那块由 contract 层的 `15_agent_diag.mjs`（AD-1…AD-5）覆盖 —— 判定与节流抽成
 * `AgentDiagGate` 后可直接断言，不需要 GUI。
 */

import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME, spawnMock, waitUntil } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

// 第 1 行是纯标点占位：skip 规则挡在翻译之前，所以它永远没有译文。
const MIXED = ['？？？', 'こんにちは'];
const PUNCT_ONLY = ['？？？', '……'];

runCase('kernel-k14', async (tap) => {
  const paths = casePaths('mochibox-k14-');
  const mock = await spawnMock({ mode: 'ok' });
  const app = startApp(paths, {
    gameDir: FIXTURE_GAME,
    duration: 60,
    timeoutMs: 90_000,
    args: ['--provider', 'openai', '--endpoint', 'http://127.0.0.1:' + mock.port]
  });

  const evalJson = async (expression) => JSON.parse(await app.control.eval(expression));
  const pageTexts = async () => evalJson('JSON.stringify($gameMessage._texts)');

  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K14'); return; }

    // 首推这一页：译文还没回来，此时整页都未命中（等价于缓存冷启动的第一帧）。
    await app.control.eval('__e2e.pushMany(' + JSON.stringify(MIXED) + ')');
    const captured = await waitUntil(async () => {
      const state = await app.control.state();
      return state.captured >= 1 ? state : null;
    }, { timeoutMs: 20_000, label: 'captured>=1' });
    tap.ok(captured.captured >= 1, 'K14 混排页里可译的那一行已被采集', 'captured=' + captured.captured);

    // 等译文回到 Agent 的 Map，再推同一页：这一帧才是"有译文 + 有未命中"混排。
    await waitUntil(async () => {
      const state = await app.control.state();
      return state.translated >= 1 ? state : null;
    }, { timeoutMs: 20_000, label: 'translated>=1' });

    await app.control.eval('__e2e.pushMany(' + JSON.stringify(MIXED) + ')');
    const mixed = await pageTexts();
    tap.eq(mixed[0], MIXED[0], 'K14 没有译文的那一行保持原文（不被清空、不被替换）');
    tap.eq(mixed[1], '译:' + MIXED[1], 'K14 同一页里有译文的行照常替换（不再被邻行拖回日文）');
    tap.eq(mixed.length, MIXED.length, 'K14 数组长度不变（下标没有错位）');

    // 关闭翻译：逐行降级后映射里只记"真被替换的下标"，还原必须逐字回到原文。
    const offJson = JSON.stringify({ type: 'config', payload: { enabled: false } });
    await app.control.eval('__mochibox.inbox(' + JSON.stringify(offJson) + ')');
    tap.eq(await pageTexts(), MIXED, 'K14 关闭翻译后逐字还原本页原文（只回滚被替换的那一行）');

    // 重新开启再推一次：还原不得把替换能力一起废掉。
    const onJson = JSON.stringify({ type: 'config', payload: { enabled: true } });
    await app.control.eval('__mochibox.inbox(' + JSON.stringify(onJson) + ')');
    await app.control.eval('__e2e.pushMany(' + JSON.stringify(MIXED) + ')');
    const again = await pageTexts();
    tap.eq(again[1], '译:' + MIXED[1], 'K14 重新开启后仍能替换（还原没有废掉 hook）');
    tap.eq(again[0], MIXED[0], 'K14 重新开启后未命中的行仍是原文');

    // 阴性对照：整页都没有可译行 → anyText 守卫要让它一行都不动。
    await app.control.eval('__e2e.pushMany(' + JSON.stringify(PUNCT_ONLY) + ')');
    tap.eq(await pageTexts(), PUNCT_ONLY, 'K14 整页纯标点时一行都不改（anyText 守卫仍生效）');

    const probe = await evalJson('__mochibox.probe()');
    tap.eq(probe.errors, 0, 'K14 全程 probe.errors===0（逐行降级不产生异常）');
    tap.eq(probe.enabled, true, 'K14 结束时翻译仍是开启态（本用例没有把它关掉）');

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K14 quit 后 exit 0');
    assertNoCrash(tap, app, 'K14 无崩溃标记');
  } catch (error) {
    tap.fatal('K14 执行失败', error);
  } finally {
    await app.dispose();
    await mock.stop();
    paths.cleanup();
  }
});
