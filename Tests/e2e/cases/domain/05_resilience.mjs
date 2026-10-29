/*
 * D5 —— 韧性（P0-13）：合批 / 并发 / 窗口 / 重试 / 熔断 / 超时
 *
 * 断言（期望值全部可追溯）：
 *   · 常量 120ms / maxBatch 60 / 并发 4 / 15s / 退避 500·1000·2000 / 熔断 5 次 · 30s（K）
 *   · 50 条新译 → 1 次后端请求（50 ≤ maxBatch 60）；240 条 → 4 次（每块 ≤60、峰值并发 ≤4）
 *   · 单请求超时 = max(15s, 15s + 条数×250ms)，随条数单调
 *   · 单条请求实测等待 ≥110ms（合并窗口 120ms）
 *   · 可重试错误 1+3 次、不可重试 1 次、退避表为空只发 1 次（不无限重试）
 *   · 熔断器：4 次不打开、第 5 次打开、29s 不可试探、30s 半开、成功清除
 *   · circuit_open.retryable === false；管线级 5 个失败批次后熔断：熔断期零后端调用、
 *     结果 items 为空（不再把原文当译文）、队列不被消费（冷却后仍能翻译）
 *
 * 依据：docs/prd.md P0-13 原文；Sources/Infra/Translators.swift:395-497（ResiliencePolicy /
 * CircuitBreaker）；Sources/Domain/TranslationPipeline.swift:252-409（runWithRetries / drainOneBatch）。
 *
 * 时钟与延迟说明（哪一半不可测）：
 *   产品的重试退避用 Task.sleep、熔断用 Date()，**没有可注入的全局时钟**；
 *   但 CircuitBreaker 的 recordFailure(now:) / canAttempt(now:) 与
 *   ResiliencePolicy.retryDelaysMs 是可写参数 —— 所以"30s 后半开"用注入时刻验证、
 *   "0.5/1/2s 退避"用 [30,30,30] 的等长三档验证（并单独断言真实常量 = 500/1000/2000）。
 *   真实 3.5s 等待与真实 30s 墙钟不测（会把单 case 拖到 40s+ 且不增加判定力）。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d5', (tap) => {
  const work = makeWork('mochibox-d5-');
  try {
    runProbeCase(tap, {
      name: 'domain_resilience_d5',
      probe: 'probe_resilience.swift',
      sources: SRC.pipeline(),
      args: ['--only', 'D5', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
