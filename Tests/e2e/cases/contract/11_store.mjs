/*
 * 11_store.mjs —— Store 层（行身份 / 扇出 / occurrences / 淘汰）的 Swift 探针入口。
 *
 * 被测源码：Sources/Domain/TextStreamStore.swift（+ Models / Segmenter / Constants）。
 * 断言正文在 `store_probe.swift`（25 条，S1–S9 / W1–W6 / R0–R3），本文件只负责：
 *   1) 用 swiftc 现编现跑（产物落 mkdtemp，退出即删）；
 *   2) 把子进程的 TAP 原样转出；编译失败转成一条 FATAL 失败。
 *
 * 为什么这层不能只靠 --attach 的 JSONL：那些行是 CLI 自己写的，每条事件一行，
 * 看不到合并、扇出、occurrences 与淘汰重算 —— 这些语义只存在于 TextStreamStore 里。
 */
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileProbe, runProbe, SOURCES } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';

const PROBE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'store_probe.swift');

runCase('store', (tap) => {
  let compiled = null;
  try {
    compiled = compileProbe({ name: 'store_probe', probeFile: PROBE, sources: SOURCES.store() });
  } catch (error) {
    tap.fatal('store_probe 编译失败', error);
    return;
  }
  try {
    const result = runProbe(compiled.bin);
    tap.absorbTap(result.stdout);
    if (result.stderr.trim() !== '') {
      for (const line of result.stderr.trimEnd().split('\n').slice(0, 10)) { tap.note('[store] stderr: ' + line); }
    }
    if (result.status !== 0) {
      // 断言失败时 Swift 自己已经打印了 not ok；这里只在"没有 TAP 输出却非 0"时补一条。
      if (!/^not ok /m.test(result.stdout)) {
        tap.fatal('store_probe 进程异常退出（exit=' + result.status + '）', new Error(result.stderr || '无输出'));
      }
    } else if (!/^1\.\.\d+$/m.test(result.stdout)) {
      tap.fatal('store_probe 没有打印 TAP 计划行（输出被截断？）', new Error(result.stdout.slice(0, 500)));
    }
  } finally {
    compiled.cleanup();
  }
});
