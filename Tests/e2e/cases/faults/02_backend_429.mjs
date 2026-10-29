/*
 * F2 HTTP 429 —— 后端以 429 失败时，产品必须"可诊断地失败"而不是崩溃。
 * 详细判据见 _failure_kit.mjs。
 */
import { runCase } from '../../lib/tap.mjs';
import { runTranslateFault } from './_failure_kit.mjs';

runCase('kernel-f2', async (tap) => {
  await runTranslateFault(tap, {
    prefix: 'mochibox-f2-',
    mode: '429',
    expectCode: 'rate_limited',
    name: 'F2 HTTP 429'
  });
});
