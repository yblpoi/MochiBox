/*
 * K13 —— 控制通道的大应答必须完整送达（不能停在 8192 字节）。
 *
 * 回归的缺陷：ControlServer 的 socket 是 O_NONBLOCK，旧实现在 write 返回
 * EAGAIN 时直接 return —— 内核发送缓冲（实测 8192 字节）之后的字节被静默丢掉，
 * 而且不补换行。驱动端于是永远等不到这一行，只能超时。
 *
 * 这里用 eval 直接构造超过 16KB 的单条应答：长度、内容、以及"下一条请求还能配对"
 * 三件事一起断言。最后一条尤其重要：帧没写完时下一行会粘在残帧后面，JSON.parse
 * 直接失败（驱动端报 bad_frame）。
 */
import { runCase } from '../../lib/tap.mjs';
import { FIXTURE_GAME } from '../../lib/app.mjs';
import {
  assertNoCrash, casePaths, quitAndWait, skipForNoAqua, startApp, waitKernelReady
} from '../_kernel_kit.mjs';

const BIG = 20000;
const MID = 12000;

runCase('kernel-k13', async (tap) => {
  const paths = casePaths('mochibox-k13-');
  const app = startApp(paths, { gameDir: FIXTURE_GAME, duration: 30, timeoutMs: 60_000 });
  try {
    const started = await waitKernelReady(app);
    if (!started.ready) { skipForNoAqua(tap, 'K13'); return; }

    const big = await app.control.eval("'x'.repeat(" + BIG + ")");
    tap.eq(typeof big, 'string', 'K13 大应答类型是 string');
    tap.eq(big.length, BIG, 'K13 20000 字符应答完整送达（旧实现会截在 8192）');
    tap.ok(/^x+$/.test(big), 'K13 大应答内容未被截断或替换');

    const mid = await app.control.eval("'y'.repeat(" + MID + ")");
    tap.eq(mid.length, MID, 'K13 12000 字符应答完整送达');

    // 帧完整性：上一行必须以 \n 收尾，否则这里会拼出非 JSON 行。
    const after = await app.control.eval('1+1');
    tap.eq(after, '2', 'K13 大应答之后的下一请求仍能正常配对（行有换行、连接未被污染）');

    const exit = await quitAndWait(app);
    tap.eq(exit, 0, 'K13 quit 后 exit 0');
    assertNoCrash(tap, app, 'K13 无崩溃标记');
  } catch (error) {
    tap.fatal('K13 执行失败', error);
  } finally {
    await app.dispose();
    paths.cleanup();
  }
});
