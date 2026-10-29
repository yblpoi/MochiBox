/*
 * 06_segment_escape.mjs —— 分句（splitSegments / mapKeyOf）与转义/跳过判据（skipReasonOf）。
 *
 * 依据：`Resources/agent_mvmz.js` 的 splitSegments（BRACKET_CODES / SINGLE_CODES）、
 *      mapKeyOfSegments（text 段以 U+001F 连接，全 code 段退回原串）、skipReasonOf
 *      （NFKC + 折叠 5 个空白 + 锚定纯数字 + \p{P}\p{S}）。
 *
 * 三条不变式：
 *   1) **逐字节可回拼**：分句只切不改，join(segments) 必须与原文完全相同（否则画到屏幕上的
 *      文本会变、缓存键会漂）；
 *   2) **码值原样**：`\c[3]` 不得被上转成 `\C[3]`（大小写是画面语义）；
 *   3) **判定对象是 key**：跳过判据吃的是剥码后的 mapKey，不是 raw。
 *
 * 句长上界：Agent 的采集没有长度上限（扫描侧另有 2000 上限），超长句必须原样上报 ——
 * 这里用 6000 字验证"不会被截断成半句"。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

const ROUND_TRIP_SAMPLES = [
  '\\C[2]こんにちは',
  '\\N[1]は元気',
  '\\c[3]こんにちは',
  '{勇者|ゆうしゃ}が来た',
  '{漢字|かんじ}\\C[2]',
  '\\FS[30]大きい',
  '\\PX[10]\\PY[20]',
  '\\i[17]',
  '\\C[2]',
  '\\C[2',
  '\\{',
  '\\\\',
  'あ\\C[2]い',
  'こんにちは\\N[1]',
  'あ\nい'
];

const SKIP_SAMPLES = [
  ['350', 'numeric'],
  ['３５０', 'numeric'],
  ['350 ', 'numeric'],
  ['！？', 'punctuation'],
  ['! ?', 'punctuation'],
  ['♪', 'punctuation'],
  ['★', 'punctuation'],
  ['   ', 'whitespace'],
  ['\u3000', 'whitespace'],
  ['3 5 0', null],
  ['350G', null],
  ['３５０Ｇ', null],
  ['ＯＫ', null],
  ['10秒後', null],
  ['\\C[2]350', 'numeric']
];

runCase('segment', (tap) => {
  const h = createHarness();
  h.drainAll();
  const json = (value) => JSON.stringify(value);
  const segmentsOf = (raw) => JSON.parse(h.run('JSON.stringify(window.__mochibox.splitSegments(' + json(raw) + '))'));
  const keyOf = (raw) => h.run('window.__mochibox.mapKeyOf(' + json(raw) + ')');
  const reasonOf = (raw) => {
    const value = h.run('JSON.stringify(window.__mochibox.skipReasonOf(' + json(raw) + '))');
    return value === 'null' || value === undefined ? null : JSON.parse(value);
  };

  let seq = 0;
  const id = () => 'SEG-' + String(++seq).padStart(2, '0');

  // ---- 不变式 1：逐字节可回拼 ----
  ROUND_TRIP_SAMPLES.forEach((raw) => {
    const segments = segmentsOf(raw);
    const joined = segments.map((segment) => segment.value).join('');
    tap.eq(joined, raw, id() + ' 分句可回拼 ' + json(raw), 'segments=' + json(segments));
  });

  // ---- 不变式 2：码值原样 ----
  const control = segmentsOf('\\C[2]こんにちは');
  tap.eq(control, [{ kind: 'code', value: '\\C[2]' }, { kind: 'text', value: 'こんにちは' }],
    id() + ' \\C[2] 被识别为 code 段，文本段不含控制码');
  const name = segmentsOf('\\N[1]は元気');
  tap.eq(name, [{ kind: 'code', value: '\\N[1]' }, { kind: 'text', value: 'は元気' }],
    id() + ' \\N[1] 被识别为 code 段（人名码）');
  tap.eq(segmentsOf('\\c[3]こんにちは')[0].value, '\\c[3]',
    id() + ' 小写码值原样保留（\\c[3] 不得上转成 \\C[3]）');
  tap.eq(segmentsOf('\\FS[30]大きい')[0].value, '\\FS[30]',
    id() + ' 两字母括号码 \\FS[30] 被完整识别');
  tap.eq(segmentsOf('\\PX[10]\\PY[20]').length, 2, id() + ' 连续两个括号码各成一段');

  // ---- 不变式 3：mapKey 口径 ----
  tap.eq(keyOf('こんにちは'), 'こんにちは', id() + ' 纯文本的 mapKey 等于原文');
  tap.eq(keyOf('\\C[2]こんにちは'), 'こんにちは', id() + ' 带码行的 mapKey 剥掉控制码');
  tap.eq(keyOf('あ\\C[2]い'), 'あ\u001fい', id() + ' 多文本段用 U+001F 连接（与 Host 的 joinForBackend 同形）');
  tap.eq(keyOf('\\i[17]'), '\\i[17]', id() + ' 全 code 段时 mapKey 退回原串（否则会判成 whitespace）');
  tap.eq(keyOf('{勇者|ゆうしゃ}が来た'), '{勇者|ゆうしゃ}が来た',
    id() + ' ruby 记号不是控制码：整串作为文本，不做任何改写');
  tap.eq(segmentsOf('{漢字|かんじ}\\C[2]').map((segment) => segment.kind), ['text', 'code'],
    id() + ' ruby 与后继控制码的分段边界正确');
  tap.eq(segmentsOf('\\C[2]'), [{ kind: 'code', value: '\\C[2]' }],
    id() + ' 只有控制码的行仍是一段 code（不是空数组）');
  tap.ok(segmentsOf('\\C[2]').every((segment) => segment.kind === 'code'),
    id() + ' 全控制码行没有 text 段（lookup 不会尝试替换）', json(segmentsOf('\\C[2]')));
  tap.eq(segmentsOf('\\C[2'), [{ kind: 'text', value: '\\C[2' }],
    id() + ' 未闭合的 \\C[2 按文本处理，不被吞掉');
  tap.eq(segmentsOf('')[0] === undefined && segmentsOf('').length === 0, true,
    id() + ' 空串分句得到空数组（不产生空文本段）');
  tap.eq(keyOf(''), '', id() + ' 空串的 mapKey 是空串');

  // ---- 跳过判据（半角/全角/符号） ----
  SKIP_SAMPLES.forEach(([raw, expected]) => {
    // 判据吃的是 mapKey（剥码后的 text），不是 raw —— \C[2]350 必须先剥成 350 再判。
    const key = keyOf(raw);
    const actual = reasonOf(key);
    tap.eq(actual, expected, id() + ' skipReasonOf(key=' + json(key) + ') = ' + (expected || 'null'),
      '原文=' + json(raw) + ' 实际=' + json(actual));
  });

  // ---- 采集：空串 / 超长句 / ruby ----
  h.advance(900);
  h.draw('');
  tap.eq(h.drainAll().filter((envelope) => envelope.type === 'text').length, 0,
    id() + ' 空串不产生 text 事件（也不记 error）');
  tap.eq(h.state().errors, 0, id() + ' 空串路径不增加 state.errors');

  const long = 'あ'.repeat(6000);
  h.advance(900);
  h.draw(long);
  const longEvents = h.drainAll().filter((envelope) => envelope.type === 'text');
  tap.ok(longEvents.length === 1 && longEvents[0].payload.raw === long && longEvents[0].payload.raw.length === 6000,
    id() + ' 6000 字超长句原样 emit（长度未被截断）',
    'events=' + longEvents.length + ' len=' + (longEvents[0] ? longEvents[0].payload.raw.length : -1));

  h.advance(900);
  h.draw('{勇者|ゆうしゃ}が来た');
  const rubyEvents = h.drainAll().filter((envelope) => envelope.type === 'text');
  tap.ok(rubyEvents.length === 1 && rubyEvents[0].payload.raw === '{勇者|ゆうしゃ}が来た' &&
    rubyEvents[0].payload.status === 'pending',
    id() + ' ruby 行原样 emit 且判为待翻译', JSON.stringify(rubyEvents[0] && rubyEvents[0].payload).slice(0, 200));

  h.advance(900);
  h.draw('\\N[1]は元気');
  const codeEvents = h.drainAll().filter((envelope) => envelope.type === 'text');
  tap.ok(codeEvents.length === 1 && codeEvents[0].payload.raw === '\\N[1]は元気' &&
    codeEvents[0].payload.key === 'は元気',
    id() + ' 带人名码的行：raw 原样、key 剥码（原文列与控制码都不丢）',
    JSON.stringify(codeEvents[0] && codeEvents[0].payload).slice(0, 250));
});
