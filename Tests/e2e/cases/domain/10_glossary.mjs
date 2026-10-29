/*
 * D10 —— 术语表（模型 / 匹配 / profile / 质量 / 存储 / 缓存键）
 *
 * 断言重点（每条都能单独失败）：
 *  · 种子与 keepAsIs：レベル→等级、HP 保留、LV 回显输入原文不被改写；
 *  · 匹配：最长优先、全半角归一、ASCII 词边界、单字术语按类别放行；
 *  · profile：与术语顺序无关、类别敏感、other 与 dialogue 归一、空束稳定；
 *  · 质量：占位符 / 残留假名 / 相同译文 / 术语未遵循 / 长度异常；
 *  · 存储：0600 文件、回读、墓碑、导出→导入保留 keepAsIs、损坏隔离；
 *  · 缓存键：无 profile 时与旧公式逐字节相同、合成单段与原始多段等价。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d10', (tap) => {
  const work = makeWork('mochibox-d10-');
  try {
    runProbeCase(tap, {
      name: 'domain_glossary_d10',
      probe: 'probe_glossary.swift',
      sources: SRC.glossary(),
      args: ['--only', 'all', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
