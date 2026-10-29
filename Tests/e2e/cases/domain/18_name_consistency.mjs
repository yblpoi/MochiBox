/*
 * D18 —— 名称一致性（术语违例可定位 + 名称先于引用取批）
 *
 * 要修的用户可见故障：怪物名在名称字段是「咬人水母」，而描述/台词里被模型译成
 * 「刺人水母」。两个根因各有一条可纯函数验证的判据：
 *  · 取批在 rank 交界处混批 → 名称要等回包才进术语表，同批的引用句拿不到它；
 *  · 违例只标不修 → 需要能指出「具体是哪一对术语被违背」，才能带强调重译。
 *
 * 断言：
 *  · Glossary.violations：命中/不命中/keepAsIs/单字术语按类别放行/多条按长度降序/空值；
 *  · FullTextWorkOrder.nextBatch：名称组先出、不跨 rank、整组 blocked 时推进、
 *    limit 截断停在组内、全部取完才返回空、limit=0 不动游标；
 *  · systemPrompt：强调段在术语表之后、输出约束之前，正常请求逐字节不变。
 *
 * 依据：Sources/Domain/GlossaryModels.swift（violations）、
 * Sources/Domain/FullTextModels.swift（FullTextWorkOrder）、
 * Sources/Infra/Translators.swift（systemPrompt emphasis）。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d18', (tap) => {
  const work = makeWork('mochibox-d18-');
  try {
    runProbeCase(tap, {
      name: 'domain_name_consistency_d18',
      probe: 'probe_fulltext.swift',
      sources: SRC.fulltext(),
      args: ['--only', 'D18', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
