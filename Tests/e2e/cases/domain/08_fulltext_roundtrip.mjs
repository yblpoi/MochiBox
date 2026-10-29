/*
 * D8 —— 全文翻译导出 / 导入（AC-10.3 / AC-10.4）
 *
 * 断言：ManualTransFile.json 是 MTool 的纯 {原文: 译文} 对象（顶层键 = 原文、无外壳、
 * UTF-8 不转义、两次导出逐字节相同）；导出→导入往返映射逐条相等（diff 为空）；
 * 导入 4 对（2 条有效 + 1 条原文==译文 + 1 条空译文）后 accepted=2/untranslated=2，
 * 语料未译条数 3 → 1（严格下降）；冲突计数与"人工优先"；导出到游戏目录的文件名与 .bak；
 * fulltext/<gameHash>.json 0600、目录 0700、load 过滤空值、损坏文件隔离、缺失返回 nil。
 *
 * 依据：docs/prd.md §3.4 AC-10.3 / AC-10.4；Sources/Infra/FullTextStore.swift:150-250；
 * Sources/Domain/FullTextModels.swift:23-35（manualFileName = ManualTransFile.json）。
 *
 * 全部写在临时目录；**不碰** Fixtures/e2e_game（D9 要对它做前后哈希）。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d8', (tap) => {
  const work = makeWork('mochibox-d8-');
  try {
    runProbeCase(tap, {
      name: 'domain_fulltext_d8',
      probe: 'probe_fulltext.swift',
      sources: SRC.fulltext(),
      args: ['--only', 'D8', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
