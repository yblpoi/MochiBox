/*
 * K8 —— install 幂等 与 uninstall 复原。
 *
 * 两个容易"看起来对、其实错"的点：
 *   1) install() 重复调用**不能**叠 hook（每次重注入都会 install，叠一层就多一次采集/替换）；
 *   2) uninstall() 必须把原型上的函数还原成**原始引用**，而不只是把 installed 置 false。
 *      这里比对 __e2e.originals（夹具在 Agent 注入前记下的引用），四个 hook 面逐一验。
 */
import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const HOOKS = [
  'Window_Base.drawTextEx',
  'Window_Base.drawText',
  'Bitmap.drawText',
  'Window_Message.startMessage'
];

const INSTALL_TWICE = `(function () {
  __mochibox.install();
  __mochibox.install();
  return __mochibox.probe();
})()`;

const UNINSTALL_AND_COMPARE = `(function () {
  __mochibox.uninstall();
  var probe = JSON.parse(__mochibox.probe());
  return JSON.stringify({
    installed: probe.installed,
    hooks: probe.hooks,
    errors: probe.errors,
    sameStartMessage: Window_Message.prototype.startMessage === __e2e.originals.startMessage,
    sameDrawTextEx: Window_Base.prototype.drawTextEx === __e2e.originals.drawTextEx,
    sameDrawText: Window_Base.prototype.drawText === __e2e.originals.drawText,
    sameBitmapDrawText: Bitmap.prototype.drawText === __e2e.originals.bitmapDrawText
  });
})()`;

runCase('kernel-k8', async (tap) => {
  const paths = casePaths('mochibox-k8-');
  const app = startApp(paths, { gameDir: FIXTURE_GAME, duration: 30, timeoutMs: 60_000 });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K8'); return; }

    const installed = JSON.parse(await app.control.eval(INSTALL_TWICE));
    tap.eq(installed.installed, true, 'K8 连续两次 install() 后 installed===true');
    tap.eq(installed.hooks, HOOKS, 'K8 连续两次 install() 后 hooks 仍是四条（没有叠 hook）');
    tap.eq(installed.errors, 0, 'K8 连续两次 install() 后 errors===0');

    const afterUninstall = JSON.parse(await app.control.eval(UNINSTALL_AND_COMPARE));
    tap.eq(afterUninstall.installed, false, 'K8 uninstall() 后 probe.installed===false');
    tap.eq(afterUninstall.hooks, [], 'K8 uninstall() 后 probe.hooks===[]');
    tap.eq(afterUninstall.errors, 0, 'K8 uninstall() 后 errors===0');
    tap.eq(afterUninstall.sameStartMessage, true, 'K8 uninstall() 复原 Window_Message.prototype.startMessage（同一引用）');
    tap.eq(afterUninstall.sameDrawTextEx, true, 'K8 uninstall() 复原 Window_Base.prototype.drawTextEx（同一引用）');
    tap.eq(afterUninstall.sameDrawText, true, 'K8 uninstall() 复原 Window_Base.prototype.drawText（同一引用）');
    tap.eq(afterUninstall.sameBitmapDrawText, true, 'K8 uninstall() 复原 Bitmap.prototype.drawText（同一引用）');

    // 恢复会话（不影响断言，但让后续收尾走正常路径）。
    const reinstalled = JSON.parse(await app.control.eval('(__mochibox.install(), __mochibox.probe())'));
    tap.eq(reinstalled.installed, true, 'K8 再次 install() 仍能装回四条 hook');

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K8 quit 后 exit 0');
    assertNoCrash(tap, app, 'K8 无崩溃标记');
  } catch (error) {
    tap.fatal('K8 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
