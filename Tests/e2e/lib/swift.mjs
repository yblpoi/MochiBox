/*
 * swift.mjs —— Swift 探针的"现编现跑"工具（编译器产物只落在 mkdtemp 目录里）。
 *
 * 为什么每轮从零编译：旧脚本里踩过——二进制还在而源码改坏时，
 * `[ -x $BIN ]` 会把"编译失败"当成可执行，拿上一轮的产物跑出一片假绿。
 * 这里用 swiftc 的退出码判死，失败直接把编译器输出抛给调用方。
 */
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(fileURLToPath(new URL('../../..', import.meta.url)));
export const SWIFTC = '/usr/bin/swiftc';

function models() {
  const directory = path.join(ROOT, 'Sources/Domain/Models');
  return fs.readdirSync(directory)
    .filter((name) => name.endsWith('.swift'))
    .sort()
    .map((name) => path.join(directory, name));
}

/** 被测源码清单（只读 Sources/，不修改）。 */
export const SOURCES = {
  domain: () => [
    ...models(),
    path.join(ROOT, 'Sources/Domain/TolerantDecoding.swift'),
    path.join(ROOT, 'Sources/Domain/Segmenter.swift'),
    path.join(ROOT, 'Sources/Domain/GlossaryModels.swift'),
    path.join(ROOT, 'Sources/App/Constants.swift')
  ],
  store: () => [
    ...SOURCES.domain(),
    path.join(ROOT, 'Sources/Domain/TextStreamStore.swift')
  ],
  // 经典 RM（2000/2003）数据层：LCFDatabase 依赖 liblcf 的 C shim（构建产物在 vendor/），
  // 所以额外要传 shim 头与静态库 —— 见 compileProbe 的 extraArgs。
  // LCFError 必须**无条件**编进来：LCFTextCodec 也抛它，而 LCFDatabase 在没有 liblcf 的
  // 机器上会被 MOCHI_NO_LCF 整段编译掉。
  lcf: () => [
    path.join(ROOT, 'Sources/Adapters/LCF/LCFError.swift'),
    path.join(ROOT, 'Sources/Adapters/LCF/LCFTextCodec.swift'),
    path.join(ROOT, 'Sources/Adapters/LCF/LCFDatabase.swift')
  ],
  qa: () => [
    ...SOURCES.domain(),
    // 缓存纯度用例要真跑 TranslationPipeline，它只被 qa 探针引用；
    // 放进 domain 会让只依赖 Segmenter 的探针把整条管线一起拖进来（编译变慢且耦合）。
    path.join(ROOT, 'Sources/Domain/TranslationPipeline.swift'),
    path.join(ROOT, 'Sources/Infra/Stores.swift'),
    path.join(ROOT, 'Sources/Infra/Translators.swift'),
    path.join(ROOT, 'Sources/Adapters/EngineDetector.swift')
  ]
};

/**
 * 编译一个探针，返回 { bin, dir, cleanup() }。
 * @param {{ name: string, probeFile: string, sources: string[], extraArgs?: string[] }} options
 *   extraArgs 追加在源文件之后、-o 之前：给需要额外链接物（.o / .a / -import-objc-header）的探针用。
 */
export function compileProbe(options) {
  const { name, probeFile, sources, extraArgs = [] } = options;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mochibox-e2e-' + name + '-'));
  const bin = path.join(dir, name);
  try {
    execFileSync(SWIFTC, [
      '-swift-version', '5',
      '-parse-as-library',
      ...sources,
      probeFile,
      ...extraArgs,
      '-o', bin
    ], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 300000, maxBuffer: 16 * 1024 * 1024 });
  } catch (error) {
    const output = [error.stdout, error.stderr].filter(Boolean).join('\n').trim();
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch (e) { /* ignore */ }
    throw new Error('swiftc 编译失败（' + name + '）\n' + output.split('\n').slice(0, 30).join('\n'));
  }
  if (!fs.existsSync(bin)) {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch (e) { /* ignore */ }
    throw new Error('swiftc 返回成功但没有产物：' + bin);
  }
  return {
    bin,
    dir,
    cleanup() { try { fs.rmSync(dir, { recursive: true, force: true }); } catch (e) { /* ignore */ } }
  };
}

/** 跑探针；返回 { stdout, stderr, status }。 */
export function runProbe(bin, args = [], options = {}) {
  const result = spawnSync(bin, args, {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: options.timeout || 120000,
    maxBuffer: 16 * 1024 * 1024
  });
  return { stdout: result.stdout || '', stderr: result.stderr || '', status: result.status };
}
