/*
 * D1 —— 库持久化（P0-04）
 *
 * 断言：字段逐个往返（id/name/path/engine/addedAt）、顺序稳定、schemaVersion、
 * 文件缺失/截断/非法 JSON 三种坏输入都"以空库启动 + 原文件改名为 library.json.bak-<ts>"、
 * 备份内容 = 损坏前原始字节、游戏目录被移走后条目仍在、missing 可落盘且 isLaunchable=false。
 *
 * 依据：docs/prd.md P0-04 原文；Sources/Infra/Stores.swift:497-530（LibraryStore）。
 *
 * 不验（GAP-P0-04）：目录被移走后自动置 missing 由
 * SessionController.refreshMissingFlags()（Sources/Domain/SessionController.swift:838）实现，
 * 它是 private 且只有 AppState.init 会调用（:800），本层没有可注入的入口。
 * 这里只断言"标记本身可落盘 + 置灰后果"，不伪造自动标记。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d1', (tap) => {
  const work = makeWork('mochibox-d1-');
  try {
    runProbeCase(tap, {
      name: 'domain_store_d1',
      probe: 'probe_store.swift',
      sources: SRC.store(),
      args: ['--only', 'D1', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
