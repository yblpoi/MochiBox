/*
 * F5 —— endpoint 指向一个**没有监听**的回环端口。
 *
 * 与 401/429/500 的区别：请求根本没到后端（连接被拒绝），错误码必须是 network，
 * 而不是 auth/rate/bad_response。端口用 bind(0) 选出来再立刻释放 —— 保证"确实没人监听"，
 * 又不写死一个可能碰巧被别人占用的数字。
 */
import { runCase } from '../../lib/tap.mjs';
import { freeLoopbackPort } from '../../lib/app.mjs';
import { runTranslateFault } from './_failure_kit.mjs';

runCase('kernel-f5', async (tap) => {
  const port = await freeLoopbackPort();
  // 端口号进诊断行，不进断言名：断言名是两次运行必须逐字节一致的判据文本，
  // 而 bind(0) 选出的端口每次不同。
  tap.note('F5 endpoint=http://127.0.0.1:' + port + '（无监听）');
  await runTranslateFault(tap, {
    prefix: 'mochibox-f5-',
    endpoint: 'http://127.0.0.1:' + port,
    expectCode: 'network',
    name: 'F5 endpoint 无监听'
  });
});
