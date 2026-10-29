/*
 * D7 —— 缓存容量与命中率（P0-10）
 *
 * 断言：默认上限 100000；超限按 lastUsed（写入时刻，命中即刷新）淘汰、内存只留
 * maxEntries；淘汰条数写进日志（evicted=1）；磁盘 jsonl 仍追加 4 行（淘汰不重写文件）；
 * 重启后按同一规则重新裁到上限（同一 key 多条记录时以最新一条的写入时刻为起点）；
 * 命中率各分支 0%/20%/50%/75%/100% 与分母为 0 时的 0% 全部正确；缓存文件 0600。
 *
 * 依据：docs/prd.md P0-10 原文；Sources/Infra/Stores.swift:660-760（TranslationCache）、
 * Sources/App/Constants.swift:maxCacheEntries=100000；
 * Sources/Domain/Models/StoreModels.swift:CacheStats.hitRate = hits/(hits+stores)。
 *
 * 说明：淘汰排序用 entry.lastUsed —— put() 写入时等于 ts，get() 命中即刷新到当前时刻，
 * 因此是真正的 LRU 而不是 FIFO。落盘记录不带 lastUsed，重启后以同一 key 最新一条记录
 * 的写入时刻为起点（D21 的合并规则）。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d7', (tap) => {
  const work = makeWork('mochibox-d7-');
  try {
    runProbeCase(tap, {
      name: 'domain_store_d7',
      probe: 'probe_store.swift',
      sources: SRC.store(),
      args: ['--only', 'D7', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
