/*
 * K2 —— Agent 注入。
 *
 * 四个 hook 必须**恰好**是这四条且顺序固定（install() 的 push 顺序就是契约，见
 * Resources/agent_mvmz.js 的 install()）；errors 必须为 0 —— 有错说明某次 hook 抛了异常，
 * 而 Agent 把异常吞进 state.errors，界面看不出来。
 *
 * 关于 "meta.agent_version"：产品目前**没有**这个字段（play: probe= 只有 installed/hooks/errors/...，
 * attached: 只打 hooks）。这里用控制通道读 window.__mochibox.version 与 Resources/agent_mvmz.js 的
 * var VERSION 对照 —— 这是当前唯一可判定的"版本一致"证据。
 */
import { runCase } from '../../lib/tap.mjs';
import { AGENT_VERSION, FIXTURE_GAME } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, quitAndWait, readProbeLine, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const EXPECTED_HOOKS = [
  'Window_Base.drawTextEx',
  'Window_Base.drawText',
  'Bitmap.drawText',
  'Window_Message.startMessage'
];

runCase('kernel-k2', async (tap) => {
  const paths = casePaths('mochibox-k2-');
  const app = startApp(paths, { gameDir: FIXTURE_GAME, duration: 30, timeoutMs: 60_000 });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K2'); return; }
    await app.control.connect();

    const attachedLine = app.line(/^attached: /);
    tap.ok(attachedLine !== null, 'K2 出现 attached 行', attachedLine);
    const hooksMatch = attachedLine ? /hooks=\[([^\]]*)\]/.exec(attachedLine) : null;
    const attachedHooks = hooksMatch && hooksMatch[1] ? hooksMatch[1].split(',') : [];
    tap.eq(attachedHooks, EXPECTED_HOOKS, 'K2 hello 上报的 hooks 恰好四条且顺序一致');

    const versionText = await app.control.eval('window.__mochibox ? String(window.__mochibox.version) : null');
    tap.eq(Number(versionText), AGENT_VERSION, 'K2 页面 Agent 版本 == Resources/agent_mvmz.js 的 VERSION');
    tap.note('产品没有 meta.agent_version 字段；版本一致性用 __mochibox.version 取证（AGENT_VERSION=' + AGENT_VERSION + '）');

    const probeText = await app.control.eval('window.__mochibox.probe()');
    const probe = JSON.parse(probeText);
    tap.eq(probe.installed, true, 'K2 probe.installed===true');
    tap.eq(probe.hooks, EXPECTED_HOOKS, 'K2 probe.hooks 恰好四条且顺序一致');
    tap.eq(probe.errors, 0, 'K2 probe.errors===0');

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K2 quit 后 exit 0');

    const finalProbe = readProbeLine(app);
    tap.ok(finalProbe !== null, 'K2 退出前打印了 play: probe=', app.tail(app.stdoutLines, 12));
    if (finalProbe) {
      tap.eq(finalProbe.installed, true, 'K2 退出时 probe.installed 仍为 true');
      tap.eq(finalProbe.hooks, EXPECTED_HOOKS, 'K2 退出时 probe.hooks 仍是四条（顺序一致）');
      tap.eq(finalProbe.errors, 0, 'K2 退出时 probe.errors 仍为 0');
    }
    assertNoCrash(tap, app, 'K2 无崩溃标记');
  } catch (error) {
    tap.fatal('K2 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
