/*
 * 19_marshal.mjs —— Ruby Marshal / RGSS 数据往返用例（探针：19_marshal_probe.swift）。
 *
 * 断言分两层，分工来自实测：外部样本的事件层是空壳，只有数据库/术语层有真文本。
 *
 *   Level-1 外部真实样本（Fixtures/rmxp-real|rmvx-real）
 *     M-L1-<ver>-HEADER  Marshal 4.8 头（04 08）
 *     M-L1-<ver>-RT      每个文件解析 -> 序列化，字节完全相同
 *     M-L1-<ver>-STRUCT  RPG::System / @words(XP 20 扁平) / @terms(VX 33 扁平) / RPG::Map / Table
 *     M-L1-<ver>-EMPTY   事件层如实为 0（@events{} 空、无 101/401）—— 不假装有对话
 *     M-L1-<ver>-DB      数据库层精确条数（XP 620 / VX 769，角色名 8 个非空）
 *     M-L1-GAMEINI       OpenXP 的 Library=RGSS104E.dll，子串命中 EngineDetector 的 Library=RGSS1
 *
 *   Level-2 合成样本（Fixtures/rmxp|rmvx|rmvxace）
 *     M-L2-<ver>-RT/EVENT/CODES/TERMS/EDGE/ENC/COUNT/TABLE/MAPINFO/SCRIPTS
 *     101/401 对话、102/402 选项、405 滚动文本的路径与文本；三版本互不相同的用语表形状；
 *     空串 / 超长串（>255 字节，走多字节长度分支）/ 反斜杠 C 控制序列 / 中日英混排
 *
 *   引擎无关：M-INT（整数逐字节对照 ruby）、M-ENC、M-LINK（对象表）、M-WB（写回）、M-BAD（畸形输入）
 *
 * 源码清单在这里现取 Sources/Adapters/Marshal/*.swift —— 不改 lib/swift.mjs，
 * 避免与同时在改 LCF 适配器的人冲突。探针产物落 mkdtemp，不碰 build/。
 * 仓库根作为 argv[1] 传给探针，所以不依赖启动时的 cwd。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileProbe, runProbe, ROOT } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';

const PROBE = path.join(path.dirname(fileURLToPath(import.meta.url)), '19_marshal_probe.swift');
const SOURCE_DIR = path.join(ROOT, 'Sources/Adapters/Marshal');

function marshalSources() {
  if (!fs.existsSync(SOURCE_DIR)) { return []; }
  return fs.readdirSync(SOURCE_DIR)
    .filter((name) => name.endsWith('.swift'))
    .sort()
    .map((name) => path.join(SOURCE_DIR, name));
}

runCase('marshal', (tap) => {
  let compiled = null;
  try {
    const sources = marshalSources();
    tap.ok(sources.length >= 5, 'Sources/Adapters/Marshal 下找到全部适配器源码',
      '实际文件: ' + sources.map((file) => path.basename(file)).join(', '));
    if (sources.length === 0) { return; }

    compiled = compileProbe({ name: 'marshal_probe', probeFile: PROBE, sources });
    // 仓库根显式传参：探针不依赖启动时的 cwd（在别的目录手跑也不会全红）
    const result = runProbe(compiled.bin, [ROOT], { timeout: 180000 });

    if (result.stderr.trim()) {
      tap.note('探针 stderr:\n' + result.stderr.trim().split('\n').slice(0, 12).join('\n'));
    }
    tap.absorbTap(result.stdout);
    tap.eq(result.status, 0, '探针退出码为 0（全部断言通过）');
  } catch (error) {
    tap.fatal('Marshal 探针执行失败', error);
  } finally {
    if (compiled) { compiled.cleanup(); }
  }
});
