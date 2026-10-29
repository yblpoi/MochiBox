/*
 * 10_skip_parity.mjs —— V4-14：跳过判据**双端 parity**（架构 §7.7「双端一致」）。
 *
 * 同一批 12 个样例（含 v0.7 的三条中文/日文反例），分别问两端的实现"要不要跳过"，逐值比对：
 *   Swift 侧：SkipRules.skipReason(for: text, enabled: true, minLength:)  ← skip_parity.swift
 *   Agent 侧：真实 Resources/agent_mvmz.js 的 collect() → payload.skipReason
 *
 * 判定对象一律是 **text**（剥码后的段内容），不是 raw —— `\\C[2]350` 必须先剥码再判，
 * 否则两端会得出不同结论（这正是本探针要抓的）。
 *
 * 编译：swiftc 现编现跑，产物落在 mkdtemp 目录，退出时删除。
 */
import { createHarness } from '../../lib/harness.mjs';
import { compileProbe, runProbe, SOURCES } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const PROBE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'skip_parity.swift');

const SAMPLES = [
  ['350', true],
  ['！？', true],
  ['! !', true],
  ['\u3000', true],       // 全角空格：纯空白
  ['10秒後', false],
  ['\\C[2]350', true],   // 剥码后是纯数字
  // 与 "! !" 成对：numeric 只认**整串**数字，不剥内部空白；punctuation 才移除折叠码位。
  ['3 5 0', false],
  // 大小写不敏感：小写 `\\c[3]` 剥掉后也是纯数字，必须与 `\\C[2]350` 同判。
  ['\\c[3]350', true],
  // 纯图标码：mapKey 退回原串，含字母，既非纯数字也非纯标点 → 必须翻译。
  ['\\i[17]', false],
  // 已是中文（v0.7）：无假名 + 汉字 ≥8 + ≥2 个不同虚词 → 跳过，不再送翻译。
  // 长度刻意 ≥8 汉字：JS 侧没有 minLength，太短会掩盖 tooShort 的双端差异。
  ['这是一段已经完全翻译好的中文对白，不需要再翻译。', true],
  ['游戏设置里可以调整音量和画面亮度，您看这样合适吗？', true],
  // 反例：含假名，且虚词只有「的」一个 → 不能按中文跳过（否则日文汉字句整句漏译）。
  ['我々は目的を了解した', false]
];

runCase('skip-parity', (tap) => {
  let compiled = null;
  try {
    compiled = compileProbe({ name: 'skip_parity', probeFile: PROBE, sources: SOURCES.domain() });
    const swiftRun = runProbe(compiled.bin);
    if (swiftRun.status !== 0) {
      tap.fatal('Swift 探针运行失败（exit=' + swiftRun.status + '）', new Error(swiftRun.stderr || swiftRun.stdout));
    }

    const rows = swiftRun.stdout.trim().split('\n').filter((line) => line.startsWith('SWIFT|'))
      .map((line) => {
        const parts = line.split('|');
        return { index: Number(parts[1]), reason: parts[2] === 'nil' ? null : parts[2] };
      });
    tap.eq(rows.length, SAMPLES.length, 'S-00 Swift 侧打印了全部 ' + SAMPLES.length + ' 个样例',
      '实际 ' + rows.length + ' 行');

    const h = createHarness();
    h.drainAll();

    SAMPLES.forEach(([raw, expectSkip], index) => {
      h.advance(900); // 跨过 800ms 采集抑制窗口
      h.drainAll();
      h.draw(raw);
      const event = h.drainAll().filter((envelope) => envelope.type === 'text')[0];
      const agentReason = event && event.payload ? (event.payload.skipReason ?? null) : null;
      const swiftReason = rows.find((row) => row.index === index)?.reason ?? null;

      const agentSkip = agentReason !== null;
      const swiftSkip = swiftReason !== null;
      const same = agentSkip === swiftSkip;
      const expectOk = agentSkip === expectSkip;
      tap.ok(same && expectOk,
        'S-' + String(index + 1).padStart(2, '0') + ' ' + JSON.stringify(raw) +
        ' 期望=' + (expectSkip ? 'skip' : 'translate') + '，两端一致',
        'swift=' + (swiftReason ?? 'nil') + ' agent=' + (agentReason ?? 'nil') +
        (same ? '' : '（两端不一致）') + (expectOk ? '' : '（Agent 与期望不符）'));
    });
  } catch (error) {
    tap.fatal('skip_parity 编译/执行失败', error);
  } finally {
    if (compiled) { compiled.cleanup(); }
  }
});
