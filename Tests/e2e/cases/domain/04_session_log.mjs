/*
 * D4 —— 日志轮转（P0-19）
 *
 * 断言：文件名严格符合 session-yyyyMMdd-HHmmss.log（isSessionLogName 逐字符判定，
 * 全角数字必须拒绝）；首行 userAttestsOwnership=true；minLevel 过滤；
 * 轮转后份数 = K.logRetentionCount(50)、只删最旧超额部分、非会话文件不动、
 * 淘汰条数写进日志（deleted=6 / kept=50）。
 *
 * 依据：docs/prd.md P0-19 原文；Sources/Infra/Stores.swift:151（SessionLog）、
 * :258-279（rotateIfNeeded）；Sources/App/Constants.swift:logRetentionCount=50。
 *
 * PRD 偏差（GAP-P0-19）：PRD 写"保留 5 个 × 上限 2MB"，实现是"按份数保留 50 份"，
 * 代码注释（Constants.swift:logRetentionCount）明确说明这是有意替换：文件名带秒级时间戳，
 * 一次启动天然一份，无界增长的是份数。本层按源码常量断言，并单独断言"单份 >2MB 不触发滚动"
 * 把这个偏差钉成可复核的事实。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d4', (tap) => {
  const work = makeWork('mochibox-d4-');
  try {
    runProbeCase(tap, {
      name: 'domain_store_d4',
      probe: 'probe_store.swift',
      sources: SRC.store(),
      args: ['--only', 'D4', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
