/*
 * 21_retry_after.mjs —— 429 的 Retry-After：解析、上限、实际退避
 *
 * 产品链路：HTTPPoster 取响应头 → RetryAfter.parse（秒数 / HTTP-date / 截断）
 * → mapStatus 把值放进 MochiBoxError → TranslationPipeline.runWithRetries 用它替代固定退避。
 *
 * 断言（探针 retry_after_probe.swift）：
 *   RA-1  整数秒 1 / 2 / 0
 *   RA-2  60s 截到 10s（K.retryAfterCapMs）
 *   RA-3  HTTP-date（IMF-fixdate / RFC 850）→ 相对毫秒
 *   RA-4  过期日期 → 0
 *   RA-5  非法 / 空 / nil → nil（回落固定表）
 *   RA-6  429 携带 retryAfterMs；无头时为 nil；仍可重试
 *   RA-7  401 仍是 authFailed / 不可重试
 *   RA-8  带 Retry-After: 1 的 429 → 第二次调用 ~1s 后（不是 500ms）
 *   RA-9  对照组：无头 429 → ~500ms（固定退避没被改掉）
 *
 * 零网络：桩 provider 直接抛 MochiBoxError，只有 Task.sleep 的真实时钟。
 * 总耗时 ~1.6s（500ms 对照 + 1000ms 服务端指示）。
 */
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileProbe, runProbe, SOURCES, ROOT } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';

const PROBE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'retry_after_probe.swift');

runCase('retry-after', (tap) => {
  let compiled = null;
  try {
    // qa 档已包含 TranslationPipeline + Stores + Translators —— 探针要的就是这条重试链路。
    const sources = SOURCES.qa();
    tap.ok(sources.some((file) => file.endsWith('Translators.swift')),
      '源码清单包含 Translators.swift', '实际文件数: ' + sources.length);
    compiled = compileProbe({ name: 'retry_after_probe', probeFile: PROBE, sources });
    const result = runProbe(compiled.bin, [], { timeout: 60_000 });
    if (result.stderr.trim()) {
      tap.note('探针 stderr:\n' + result.stderr.trim().split('\n').slice(0, 12).join('\n'));
    }
    tap.absorbTap(result.stdout);
    tap.eq(result.status, 0, '探针退出码为 0（全部断言通过）');
  } catch (error) {
    tap.fatal('Retry-After 探针执行失败', error);
  } finally {
    if (compiled) { compiled.cleanup(); }
  }
});
