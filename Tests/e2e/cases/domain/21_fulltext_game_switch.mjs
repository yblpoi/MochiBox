/*
 * D21 —— 全文语料按游戏隔离（跨游戏串流 + 译文文件被写脏）
 *
 * 背景：`FullTextController` 在 App 进程里只有一个实例，跨游戏复用。修复前换游戏时
 * attach() 不清语料、detach() 刻意保留、loadPersisted() 把新游戏的译文合并进旧语料、
 * pushAll() 推的是整个 corpus。真机日志那次：7468（上一作）+ 5328（本作）- 178（同 key）
 * = 12618 条下发，57.8% 是别的游戏；同一次 loadPersisted 里的 saveNow() 还把上一作的
 * 条目写进了本作的 fulltext/<gameHash>.json。
 *
 * 断言（25 条，见 probe_crossgame.swift）：
 *   ① A 首次会话：载入 7468、下发 7468；A 的术语可见、删除墓碑（HP）生效；
 *   ② 同一 gameHash 重连（detach → attach → loadPersisted → pushAll）：语料保留、整体重放 7468，
 *      且人工译文（origin=.manual）没被覆盖 —— 这条专门钉住"不要顺手改掉 detach 的保留语料"；
 *   ③ 换到 B：attach 当场 corpus=0 / translated=0 / gameHash 切换 → loadPersisted 后 5328
 *      → pushAll 下发 5328，且没有一条 A 的译文；
 *   ④ saveNow() 写回的 B 文件 = 5328 条、不含 A 的 key；A 的文件条目数与字节 sha 全程不变；
 *   ⑤ 术语表按游戏隔离：A 的术语与删除墓碑都进不了 B，HP 回到内置种子；
 *   ⑥ 换 store 时还活着的旧翻译任务（停在批里的非结构化 Task）：把 translator 挂住，
 *      在挂起期间 detach + attach 到另一款游戏再放行 —— D 的译文文件必须一字不动
 *      （没有 attach 代次守卫时，这一路会把 D 的文件写成 0 条）。
 *
 * 所有译文文件都由探针在临时目录里现写（不读真实用户的 fulltext），可重复。
 *
 * 依据：Sources/Domain/FullTextController.swift（attach / detach / loadPersisted / pushAll）；
 *       Sources/Domain/SessionController.swift:306（stop）→ :472（先 saveNow 再 detach，
 *       这是"换游戏清内存不会丢旧数据"的依据）。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d21', (tap) => {
  const work = makeWork('mochibox-d21-');
  try {
    runProbeCase(tap, {
      name: 'domain_crossgame_d21',
      probe: 'probe_crossgame.swift',
      sources: SRC.controller(),
      args: ['--only', 'D21', '--work', work.dir]
    });
  } finally {
    work.cleanup();
  }
});
