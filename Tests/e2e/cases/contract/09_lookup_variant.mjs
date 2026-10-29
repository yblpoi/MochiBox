/*
 * 09_lookup_variant.mjs —— BUG-11 的硬门禁：同 mapKey、不同 raw 的译文重组（C1–C9）。
 *
 * 缺陷本体（v0.2）：`lookup(raw, key)` 收了 raw 却没用，直接返回 `translations[key].translatedRaw`。
 * 而 key 是**剥码后的 text**，于是 `こんにちは` 与 `\\C[2]こんにちは` 共享同一格译文：
 * 先下发「你好」→ 再画 `\\C[2]こんにちは` → 颜色丢失；反向 → 凭空加色；
 * `\\N[1]は元気` / `\\N[2]は元気` → **一个角色的名字被画成另一个角色**。
 *
 * 修复后：`lookup` 以本行 raw 的 splitSegments 骨架重组译文
 * （code 段发本行自己的码值，text 段按序取 Host 下发 segments 里的译文文本段）。
 *
 * 降级矩阵（两种"拿不到骨架"的原因不能混成一条路）：
 *   有 segments 且段数相符     → 按骨架重组                      C1–C5
 *   有 segments 但段数不符     → 画原文（绝不重放别人的码）      C6, C9
 *   segments 缺失/为空         → 回退 translatedRaw（v0.2 行为） C7
 *
 * 每个用例一条独立沙箱：译文 Map 是模块内闭包状态，共用会让 C1 的条目泄漏到 C9。
 * 每个用例两条断言：渲染结果（逐条 draw）+ 状态不变量（errors / mergeFallback 精确值）。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

const CASES = [
  {
    id: 'C1',
    title: '纯文本译文 + 带码行：本行码值必须保留',
    deliver: { key: 'こんにちは', translatedRaw: '你好', segments: [{ kind: 'text', value: '你好' }] },
    draws: [{ raw: '\\C[2]こんにちは', expect: '\\C[2]你好' }],
    mergeFallback: 0
  },
  {
    id: 'C2',
    title: '反向顺序：下发的是带码行，画无码行 → 不得凭空加色',
    deliver: {
      key: 'こんにちは',
      translatedRaw: '\\C[2]你好',
      segments: [{ kind: 'code', value: '\\C[2]' }, { kind: 'text', value: '你好' }]
    },
    draws: [{ raw: 'こんにちは', expect: '你好' }],
    mergeFallback: 0
  },
  {
    id: 'C3',
    title: '同文本不同码：\\C[3] 不得沿用先前的 \\C[2]',
    deliver: {
      key: 'こんにちは',
      translatedRaw: '\\C[2]你好',
      segments: [{ kind: 'code', value: '\\C[2]' }, { kind: 'text', value: '你好' }]
    },
    draws: [
      { raw: '\\C[2]こんにちは', expect: '\\C[2]你好' },
      { raw: '\\C[3]こんにちは', expect: '\\C[3]你好' }
    ],
    mergeFallback: 0
  },
  {
    id: 'C4',
    title: '小写码保留原大小写：\\c[2] 不得被上转成 \\C[2]',
    deliver: { key: 'やあ', translatedRaw: '你好', segments: [{ kind: 'text', value: '你好' }] },
    draws: [{ raw: '\\c[2]やあ', expect: '\\c[2]你好' }],
    mergeFallback: 0
  },
  {
    id: 'C5',
    title: '人名码（最高危害样本）：\\N[2] 不得被画成 \\N[1]',
    deliver: {
      key: 'は元気',
      translatedRaw: '\\N[1]你好',
      segments: [{ kind: 'code', value: '\\N[1]' }, { kind: 'text', value: '你好' }]
    },
    draws: [
      { raw: '\\N[1]は元気', expect: '\\N[1]你好' },
      { raw: '\\N[2]は元気', expect: '\\N[2]你好' }
    ],
    mergeFallback: 0
  },
  {
    id: 'C6',
    title: '段数不匹配 → 拒绝拼接，画原文（码值一个都不许变）',
    deliver: {
      key: 'こんにちは',
      translatedRaw: '你好',
      segments: [{ kind: 'text', value: '你' }, { kind: 'text', value: '好' }]
    },
    draws: [{ raw: '\\C[2]こんにちは', expect: '\\C[2]こんにちは' }],
    mergeFallback: 1
  },
  {
    id: 'C7',
    title: '旧条目无 segments 字段：走 v0.2 兼容路径（translatedRaw）',
    deliver: { key: 'こんにちは', translatedRaw: '你好' },
    draws: [{ raw: '\\C[2]こんにちは', expect: '你好' }],
    mergeFallback: 1
  },
  {
    id: 'C8',
    title: '无该 key：不改写，画原文',
    deliver: null,
    draws: [{ raw: 'こんにちは', expect: 'こんにちは' }],
    mergeFallback: 0
  },
  {
    id: 'C9',
    title: '人名不串行（病态数据）：段数不符 → 画 \\N[2] 原文，绝不画 \\N[1]',
    // 病态构造：先到的行把「は」「元気」切成两个 text 段（mapKey 用 U+001F 连接），
    // 后来的行正文里**真的**带一个 U+001F（单段），两行 mapKey 相同而文本段数不同（1 vs 2）。
    deliver: {
      key: 'は\u001F元気',
      translatedRaw: '\\N[1]你好',
      segments: [
        { kind: 'code', value: '\\N[1]' },
        { kind: 'text', value: 'は' },
        { kind: 'text', value: '元気' }
      ]
    },
    draws: [{ raw: '\\N[2]は\u001F元気', expect: '\\N[2]は\u001F元気', mustNotContain: ['\\N[1]'] }],
    mergeFallback: 1
  }
];

runCase('lookup', (tap) => {
  for (const testCase of CASES) {
    const h = createHarness({ capture: true });
    h.drainAll();
    if (testCase.deliver) {
      h.inbox({ type: 'setTranslation', payload: testCase.deliver });
      h.drainAll();
    }

    const problems = [];
    const rendered = [];
    for (const step of testCase.draws) {
      h.advance(1000);
      const actual = h.draw(step.raw);
      rendered.push(JSON.stringify(step.raw) + ' → ' + JSON.stringify(actual));
      if (actual !== step.expect) {
        problems.push('画 ' + JSON.stringify(step.raw) + ' 期望 ' + JSON.stringify(step.expect) +
          '，实际 ' + JSON.stringify(actual));
      }
      for (const forbidden of (step.mustNotContain || [])) {
        if (typeof actual === 'string' && actual.includes(forbidden)) {
          problems.push('输出不得包含 ' + JSON.stringify(forbidden) + '，实际 ' + JSON.stringify(actual));
        }
      }
    }

    tap.eq(problems, [], testCase.id + ' ' + testCase.title, rendered.join(' ; '));

    const probe = h.probe();
    tap.ok(probe.errors === 0 && probe.mergeFallback === testCase.mergeFallback,
      testCase.id + '-state 状态不变量：errors=0、mergeFallback=' + testCase.mergeFallback,
      'errors=' + probe.errors + ' mergeFallback=' + probe.mergeFallback);
  }
});
