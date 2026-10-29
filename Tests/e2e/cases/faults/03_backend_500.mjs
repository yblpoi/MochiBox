/*
 * F3 HTTP 500 —— 后端以 500 失败时，产品必须"可诊断地失败"而不是崩溃。
 * 详细判据见 _failure_kit.mjs。
 */
import { runCase } from '../../lib/tap.mjs';
import { runTranslateFault } from './_failure_kit.mjs';

runCase('kernel-f3', async (tap) => {
  await runTranslateFault(tap, {
    prefix: 'mochibox-f3-',
    mode: '500',
    expectCode: 'bad_response',
    name: 'F3 HTTP 500'
  });
});
