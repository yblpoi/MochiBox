/*
 * D22 —— RPG Maker 经典引擎的文本控制码（2000/2003 与 XP/VX/VX Ace）
 *
 * 断言（全部落在 probe_legacy_escapes.swift 里，这里只负责编译 + 并 TAP）：
 *   · 真实语料：EasyRPG TestGame-2000/Map0001.lmu（lcf2xml 转出）的消息串里，
 *     \c[n] / \s[n] / \n[n] / \v[n] / \$ / \! / \. 一条不漏地进非 text token；
 *     2000 工程里的大写 \C[4] 同样要认（EasyRPG window_message.cpp 两种大小写都认）；
 *     嵌套 \N[\v[0009]] 按括号配平整段成一个替换符。
 *   · 边界：空串 / 只有控制码 / \\ 字面反斜杠 / \c[12] 多位数 / 未知 \z /
 *     串尾裸 \ / \c[12 未闭合 / \s 不带 [n] / 0x00–0x1F 与 0x7F 控制字节 / CRLF。
 *   · 往返：tokenize → translatableSegments → reassemble(原样) 字符与 UTF-8 字节都相等；
 *     译文条数不符抛 segment_mismatch。
 *   · 保护：改 id（\v[1]→\v[2]）、丢替换符、凭空多出控制码都必须被报出；正常回填不误报。
 *   · 家族独立：\G/\I[5] 只属 RGSS，\$/\_ 只属 2k；\C[n] 两族都认但理由不同
 *     （rm2k 是引擎大小写不敏感，rgss 是官方大写写法）。
 *   · 0x5C 尾字节陷阱：SJIS 的 0x83 0x5C(ソ)/0x95 0x5C(表)/0x8F 0x5C(十)/0x97 0x5C(予)
 *     解码后是正文，不许产生控制码 —— 这条钉住"只吃已解码 String"的接口约束。
 *   · 桥接：LegacyEscapeCodec.segments(from:) 产出的 Segment 能直接喂
 *     Segmenter.mapKey（缓存键只认 Segmenter，不另写一份哈希）。
 *   · 与现有装配器不漂移（touchpoint-map 的三条不变式）：join(segments) 与原文逐字节相同、
 *     码值原样（\\c[3] 不得上转）、跳过判据吃剥码后的 mapKey；并对 13 条语料断言
 *     Segmenter.reassemble 与 LegacyEscapeCodec.reassemble 结果一致。
 *   · 纯码行语义：\\c[1] 与 \\^ 的 textSegmentCount 都是 0，调用侧必须短路；
 *     且两类的 SkipRules 行为不同 —— \\^ 落 punctuation 跳过，\\c[1] 不会被跳过
 *     （这就是"只靠 SkipRules 挡不住方括号码行"的实证）。
 *
 * 依据：Sources/Domain/LegacyEscapeCodec.swift 的文档注释（含 EasyRPG 源码行号）。
 *
 * LegacyEscapeCodec.swift 刻意没有塞进 _domain_kit 的 SRC 分档里：
 * 这一支用例是本轮新增的，先就地拼源码清单，等并进主分支后再决定要不要提升成 SRC.legacy。
 */
import path from 'node:path';
import { runCase } from '../../lib/tap.mjs';
import { SRC, ROOT, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d22', (tap) => {
  runProbeCase(tap, {
    name: 'domain_legacy_escapes_d22',
    probe: 'probe_legacy_escapes.swift',
    // probe_support.swift（FileIO/Fs/ProbeArgs）依赖 Sources/Infra/Stores.swift，
    // 所以用 SRC.store() 这一档，而不是 SOURCES.domain()。
    // LegacyEscapeCodec.swift 已在 SRC.store() 里（FullTextController 依赖它），不要重复加。
    sources: SRC.store(),
    args: ['--only', 'D22']
  });
});
