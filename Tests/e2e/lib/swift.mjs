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
 * @param {{ name: string, probeFile: string, sources: string[] }} options
 */
export function compileProbe(options) {
  const { name, probeFile, sources } = options;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mochibox-e2e-' + name + '-'));
  const bin = path.join(dir, name);
  try {
    execFileSync(SWIFTC, [
      '-swift-version', '5',
      '-parse-as-library',
      ...sources,
      probeFile,
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
