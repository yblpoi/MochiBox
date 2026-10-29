/*
 * D19 —— 拆块深度自适应 + 空内容不拆块（最终验收回归）
 *
 * 断言：
 *   · maxBatch=200 + 「>8 条必失败」的后端 → 200 条**全部交付**，请求序列里出现 ≤8 条的叶子
 *     （写死 4 层只能拆到 12/13 条，整波 200 条会全丢）；单次请求不超过 maxBatch(200)
 *   · 空内容（finish_reason=length）+ 5 条 → **只发 1 次请求**（拆块会变成 9 次），
 *     0 条交付，错误码仍是 bad_response、原因里带 finish_reason
 *
 * 依据：Sources/Domain/TranslationPipeline.swift（splitDepth(forChunkSize:) / runSubchunk）；
 * Sources/Infra/Translators.swift（OpenAICompatibleProvider.emptyContentMessagePrefix）。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d19', (tap) => {
  const work = makeWork('mochibox-d19-');
  try {
    runProbeCase(tap, {
      name: 'domain_resilience_d19',
      probe: 'probe_resilience.swift',
      sources: SRC.pipeline(),
      args: ['--only', 'D19', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
