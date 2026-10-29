/*
 * F1 HTTP 401 —— 后端以 401 失败时，产品必须"可诊断地失败"而不是崩溃。
 * 详细判据见 _failure_kit.mjs。
 */
import { runCase } from '../../lib/tap.mjs';
import { runTranslateFault } from './_failure_kit.mjs';

runCase('kernel-f1', async (tap) => {
  await runTranslateFault(tap, {
    prefix: 'mochibox-f1-',
    mode: '401',
    expectCode: 'auth_failed',
    name: 'F1 HTTP 401'
  });
});
