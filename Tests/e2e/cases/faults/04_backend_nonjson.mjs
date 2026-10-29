/*
 * F4 200 + 非 JSON —— 后端以 nonjson 失败时，产品必须"可诊断地失败"而不是崩溃。
 * 详细判据见 _failure_kit.mjs。
 */
import { runCase } from '../../lib/tap.mjs';
import { runTranslateFault } from './_failure_kit.mjs';

runCase('kernel-f4', async (tap) => {
  await runTranslateFault(tap, {
    prefix: 'mochibox-f4-',
    mode: 'nonjson',
    expectCode: 'bad_response',
    name: 'F4 200 + 非 JSON'
  });
});
