/*
 * D23 —— RGSS（XP / VX / VX Ace）启动预译
 *
 * 断言：游戏启动后只读扫描 Data/，把"将要显示的文本"按运行时**同一公式**算 cacheKey，
 * 命中缓存跳过、未命中 submit(.low)。首次显示因此能在 hook 的 120ms 闸内拿到译文，
 * 不必等 P50≈997ms 的 provider（docs/rgss-text-channel.md §8.2 / §10）。
 *
 * 三条不许退让的边界：
 *   1) 与运行时同一把钥匙 —— 断言用 RGSSPipelineTranslator.makeRequestItem 现算 key，
 *      在真实 TranslationCache 里能查到；XP 的 101+401 必须按整段 message_text 预译。
 *   2) 缓存纯度 —— 头像资源名 / 地图名 / 纯数字 / 纯符号 / 已中文 / 过短文本 0 请求、
 *      0 缓存条目；VX Ace 的 101[0]（头像名）绝不入队。
 *   3) 不阻塞 / 只降级 —— provider 被门卡住时 run() 2s 内返回；关闭 / 直通 / 上限 0 /
 *      provider 抛错都只意味着"首句回落运行时翻译"，不抛错、不写坏缓存。
 *
 * 依据：docs/architecture.md §5；Sources/Domain/RGSSPrewarm.swift；
 * Sources/Adapters/RGSSPipelineTranslator.swift:98（makeRequestItem）；
 * Sources/Domain/TranslationPipeline.swift（submit 只入队 / 缓存写入）；
 * Sources/Infra/Stores.swift（Settings 新字段 tolerant 默认值 + clamp）。
 *
 * 证据等级：本用例是**测试证据**（假 provider + 真实 TranslationCache/Pipeline/Marshal
 * 读取层，不依赖网络与 GUI）。真实 provider 下的首句命中见 docs 的"实跑证据"一条。
 */
import { runCase } from '../../lib/tap.mjs';
import { makeWork, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d23', (tap) => {
  const work = makeWork('mochibox-d23-');
  try {
    runProbeCase(tap, {
      name: 'domain_prewarm_d23',
      probe: 'probe_prewarm.swift',
      sources: SRC.prewarm(),
      args: ['--only', 'D23', '--work', work.dir],
      // 管线 flush 有 20~35s 预算；探针自己不等真实网络，留足余量即可。
      timeout: 150_000
    });
  } finally {
    work.cleanup();
  }
});
