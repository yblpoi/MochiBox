/*
 * D2 —— 设置持久化（P0-20）
 *
 * 断言：原子写后文件可完整解析且无 *.tmp-* 残留；字段缺失 / 类型非法 / 越界三类输入
 * 都回落默认值且不抛错（越界另记一条日志）；settings.json 损坏时用默认值；
 * 目录只读导致写失败时抛 io_error 且旧文件内容原样可读。
 *
 * 依据：docs/prd.md P0-20 原文；Sources/Infra/Stores.swift:94-100（FileIO.atomicWrite）、
 * :469-492（Settings.normalized）、:573（saveSettings 的 0o600）。
 *
 * 期望值来源：默认值取 Settings() 的声明默认（与 K.requestTimeoutSec / K.maxBatch 同值），
 * 越界上下限取 normalized() 里的字面量（1.3 / 120 / 100）。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d2', (tap) => {
  const work = makeWork('mochibox-d2-');
  try {
    runProbeCase(tap, {
      name: 'domain_store_d2',
      probe: 'probe_store.swift',
      sources: SRC.store(),
      args: ['--only', 'D2', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
