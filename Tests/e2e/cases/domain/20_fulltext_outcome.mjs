/*
 * D20 —— 全文翻译一轮结束的收尾判定（失败原因必须可见）
 *
 * 断言（纯函数 FullTextOutcome.summary）：
 *   · 0 新增 + 有失败 → phase=failed，error 文案含「本轮没有任何新增译文，失败 N 条」与第一条失败原因
 *   · 有新增 + 有失败 → phase 仍是 done，notice 含新增/失败数与原因，不置 lastError
 *   · 全成功 → done，notice / error 都为空（不打扰用户）
 *   · 失败但没有 message → 仍给出可读原因
 *
 * 依据：Sources/Domain/FullTextModels.swift（FullTextOutcome）；
 * Sources/Domain/FullTextController.swift（translate() 收尾 / handlePipelineResult）。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d20', (tap) => {
  const work = makeWork('mochibox-d20-');
  try {
    runProbeCase(tap, {
      name: 'domain_fulltext_d20',
      probe: 'probe_fulltext.swift',
      sources: SRC.fulltext(),
      args: ['--only', 'D20', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
