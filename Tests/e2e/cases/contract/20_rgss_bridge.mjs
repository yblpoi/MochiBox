/*
 * 20_rgss_bridge.mjs —— RGSS 文本桥的协议 / 控制符 / 超时 / 缓存 / 降级回归。
 *
 * 桥接链路：RGSSBridge → RGSSPipelineTranslator → TranslationPipeline → TranslationCache。
 * 本用例把这条链路真正跑起来（不是只测辅助函数）：
 *
 *   RB-A 协议层（真 loopback socket）
 *     RB-A1  TEXT 的 base64 往返：中文 + \n 解码后逐字符相同
 *     RB-A1b 正常 RESP 不带 PENDING 后缀
 *     RB-A2  RESP 逐字节 = RESP\t<seq>\t<base64>\n
 *     RB-A3  少字段 / seq 非数字 / base64 非法 / 非 TEXT 行都被拒绝（无回包）
 *     RB-A3e 畸形行之后同一连接仍能正常应答（handler 没死）
 *
 *   RB-B 控制符分段（LegacyEscapeCodec.skeleton + Segmenter，不经过网络）
 *     RB-B1  \C[2]赤い\C[0] 只送「赤い」
 *     RB-B2  拼回 \C[2]译文\C[0]，控制码序列与原文逐项相同
 *     RB-B3  \N[1]こんにちは 只送「こんにちは」，替换符拼回
 *     RB-B4  模型返回混入 \C[9] 被判 corrupt
 *     RB-B5  \C[2]/ \C[3] 同 key；keyMaterial 不含控制码；key 前 8 位与文档向量一致
 *     RB-B6  真实管线里 corrupt 译文整条丢弃 + ignoreCache 重试一次
 *
 *   RB-C 超时（永不返回的 translator）
 *     RB-C1  120ms 回 PENDING + 原文的 UTF-8 重编码（100–600ms 实测窗）
 *     RB-C1b PENDING 逐字节 = RESP\t<seq>\t<base64>\tPENDING
 *     RB-C2  stop() 后原端口拒绝连接
 *     RB-C3  stop() 后新桥仍能启动、服务
 *
 *   RB-D 缓存（真实 TranslationPipeline + TranslationCache）
 *     RB-D1  miss → fresh，控制码拼回
 *     RB-D2  写入缓存
 *     RB-D3  同文本换 \C[3] → hit，用本行控制码；不再打后端
 *     RB-D4  hitCount 递增
 *     RB-D5  落盘 JSONL 存在且非空
 *     RB-D6  load() 读回
 *
 *   RB-E 降级
 *     RB-E1  bind 失败返回 .bind 类型化错误（产品路径由 GameLauncher 捕获）
 *     RB-E2  客户端发一半 close / 发完立刻 close 后桥仍能服务新连接
 *
 * 编译与运行：node Tests/e2e/lib/run.mjs --suite contract（或直接跑本文件）。
 * 探针产物落 mkdtemp，不碰 build/ 与 ~/Library。
 */
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileProbe, runProbe, SOURCES, ROOT } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';

const PROBE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'rgss_bridge_probe.swift');
const s = (...parts) => path.join(ROOT, ...parts);

/** 桥 + 翻译器 + 管线 + 缓存：只多编这四个文件，不拖整个 App。 */
function bridgeSources() {
  return [
    ...SOURCES.domain(),
    s('Sources/Domain/LegacyEscapeCodec.swift'),
    s('Sources/Infra/Stores.swift'),
    s('Sources/Infra/Translators.swift'),
    s('Sources/Domain/TranslationPipeline.swift'),
    s('Sources/Adapters/RGSSBridge.swift'),
    s('Sources/Adapters/RGSSPipelineTranslator.swift')
  ];
}

runCase('rgss-bridge', (tap) => {
  let compiled = null;
  try {
    const sources = bridgeSources();
    tap.ok(sources.length >= 12, '桥探针的源码清单包含 Domain + Infra + Adapters',
      '实际文件数: ' + sources.length);
    compiled = compileProbe({ name: 'rgss_bridge_probe', probeFile: PROBE, sources });
    const result = runProbe(compiled.bin, [], { timeout: 120_000 });
    if (result.stderr.trim()) {
      tap.note('探针 stderr:\n' + result.stderr.trim().split('\n').slice(0, 12).join('\n'));
    }
    tap.absorbTap(result.stdout);
    tap.eq(result.status, 0, '探针退出码为 0（全部断言通过）');
  } catch (error) {
    tap.fatal('RGSS 桥探针执行失败', error);
  } finally {
    if (compiled) { compiled.cleanup(); }
  }
});
