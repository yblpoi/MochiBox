/*
 * K7 —— 作弊 RPC 端到端（eval → __mochibox.rpc → $game* → 应答）。
 *
 * 为什么要一次 evaluate 里 "调 rpc + drain"：Host 的 text pump 每 250ms 会 drain 整个 outbox，
 * rpcResult 会被它读走丢弃（它只认 text）。两次独立的 evaluate 之间存在窗口，断言会偶发拿不到
 * 应答。JS 是单线程的，同一个表达式内 rpc 后立刻 drain 是唯一无竞态的读法。
 *
 * 未知方法的错误码：产品实际是 rpc_unknown_method（不是笼统的 rpc_error）。
 * 这里断言真实值 —— 它必须稳定，驱动端才能区分"方法名拼错"和"Agent 内部异常"。
 */
import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const EXPRESSION = `(function () {
  function call(id, method, args) {
    window.__mochibox.rpc({ id: id, method: method, args: args });
    var out = JSON.parse(window.__mochibox.drain());
    for (var i = 0; i < out.length; i++) {
      var item = out[i];
      if (item.type === 'rpcResult' && item.payload && item.payload.id === id) { return item.payload; }
    }
    return null;
  }
  var gold = call('k7-gold', 'cheat.setGold', { value: 12345 });
  var sw = call('k7-switch', 'cheat.setSwitch', { id: 5, on: true });
  var va = call('k7-var', 'cheat.setVariable', { id: 3, value: 777 });
  var unknown = call('k7-unknown', 'cheat.nope', {});
  return JSON.stringify({
    gold: gold, sw: sw, va: va, unknown: unknown,
    partyGold: $gameParty.gold(),
    switch5: $gameSwitches.value(5),
    var3: $gameVariables.value(3)
  });
})()`;

runCase('kernel-k7', async (tap) => {
  const paths = casePaths('mochibox-k7-');
  const app = startApp(paths, { gameDir: FIXTURE_GAME, duration: 30, timeoutMs: 60_000 });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K7'); return; }

    const raw = await app.control.eval(EXPRESSION);
    const result = JSON.parse(raw);

    tap.eq(result.partyGold, 12345, 'K7 cheat.setGold 后 $gameParty.gold()===12345');
    tap.eq(result.switch5, true, 'K7 cheat.setSwitch 后 $gameSwitches.value(5)===true');
    tap.eq(result.var3, 777, 'K7 cheat.setVariable 后 $gameVariables.value(3)===777');

    tap.ok(result.gold && result.gold.ok === true, 'K7 setGold 的 rpcResult ok=true', JSON.stringify(result.gold));
    tap.eq(result.gold && result.gold.data ? result.gold.data.gold : null, 12345,
      'K7 setGold 回包 data.gold===12345');
    tap.eq(result.sw && result.sw.data ? result.sw.data.value : null, true,
      'K7 setSwitch 回包 data.value===true');
    tap.eq(result.va && result.va.data ? result.va.data.value : null, 777,
      'K7 setVariable 回包 data.value===777');

    tap.ok(result.unknown && result.unknown.ok === false,
      'K7 未知方法 ok=false', JSON.stringify(result.unknown));
    tap.eq(result.unknown && result.unknown.error ? result.unknown.error.code : null,
      'rpc_unknown_method', 'K7 未知方法错误码稳定为 rpc_unknown_method');
    tap.note('任务书写的 rpc_error 是兜底码；RPC 分发表对未知方法返回更具体的 rpc_unknown_method（agent_mvmz.js handleRpc）。');

    const pageEval = await app.control.eval('String($gameParty.gold()) + "|" + String($gameSwitches.value(5)) + "|" + String($gameVariables.value(3))');
    tap.eq(pageEval, '12345|true|777', 'K7 另一次 evaluate 读到的游戏状态一致（不是只在回包里成立）');

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K7 quit 后 exit 0');
    assertNoCrash(tap, app, 'K7 无崩溃标记');
  } catch (error) {
    tap.fatal('K7 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
