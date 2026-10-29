/*
 * _domain_kit.mjs —— 领域层（domain）用例的共享小工具。
 *
 * 文件名以下划线开头：Tests/e2e/lib/run.mjs 发现用例时会跳过它，不会被当成一个 case 跑。
 *
 * 这一层解决的是"审计确认零自动断言"的那批需求：持久化（P0-04/20）、脱敏与权限（P0-12）、
 * 日志（P0-19）、韧性（P0-13）、直通（P0-11）、缓存容量（P0-10）、全文翻译（AC-10.3/4）、
 * 运行不改游戏目录（AC-10.5）。除 D9 外全部不依赖 Aqua 桌面。
 *
 * 这里只放三件事：
 *   · 被测源码清单（swiftc 的输入，只读 Sources/）；
 *   · "编译 + 跑探针 + 并入 TAP"的唯一实现；
 *   · D9 的全目录哈希。
 * 具体的业务断言永远留在 case 与 .swift 探针里。
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { compileProbe, runProbe, SOURCES, ROOT } from '../../lib/swift.mjs';

export const DOMAIN_DIR = path.dirname(fileURLToPath(import.meta.url));
export { ROOT };

const s = (...parts) => path.join(ROOT, ...parts);

/**
 * 探针的源码集合。分三档而不是一档，是为了让每个 case 只编它真需要的文件：
 *   · store    —— 持久化 / 脱敏 / 日志 / 缓存（Stores.swift 一族，零管线依赖）
 *   · pipeline —— 韧性 / 直通（再加 Translators + TranslationPipeline）
 *   · fulltext —— 全文翻译（再加 FullTextModels + FullTextStore）
 */
export const SRC = {
  // Stores.swift 的 Settings.normalized() 用到 Translators.swift 里的 String.endpointBase，
  // 所以这一档必须带上 Translators（它本身不依赖管线）。
  store: () => [
    ...SOURCES.domain(),
    s('Sources/Infra/Stores.swift'),
    s('Sources/Infra/Translators.swift')
  ],
  pipeline: () => [
    ...SRC.store(),
    s('Sources/Domain/TranslationPipeline.swift')
  ],
  fulltext: () => [
    ...SRC.store(),
    s('Sources/Domain/FullTextModels.swift'),
    // 质量校验与 Glossary.violations 同源：D18 要断言「违例能定位到具体术语对」。
    s('Sources/Domain/FullTextQuality.swift'),
    s('Sources/Infra/FullTextStore.swift')
  ],
  // 全文控制器的跨游戏状态（D21）：在 fulltext 之上再要 TranslationPipeline / AgentRPC /
  // FullTextController 本体 —— 只给真跑 attach/pushAll 的用例用，别拖慢 D8/D18/D20。
  controller: () => [
    ...SRC.fulltext(),
    s('Sources/Domain/GlossarySeed.swift'),
    s('Sources/Domain/TranslationPipeline.swift'),
    s('Sources/Domain/AgentRPC.swift'),
    s('Sources/Domain/FullTextController.swift'),
    s('Sources/Infra/GlossaryStore.swift')
  ],
  glossary: () => [
    ...SRC.store(),
    s('Sources/Domain/GlossarySeed.swift'),
    s('Sources/Domain/FullTextQuality.swift'),
    s('Sources/Infra/GlossaryStore.swift')
  ]
};

/** 每个 case 独有的临时根：不读 ~/Library/Application Support，结束即删。 */
export function makeWork(prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  return {
    dir,
    file(name) { return path.join(dir, name); },
    cleanup() { try { fs.rmSync(dir, { recursive: true, force: true }); } catch (error) { /* 尽力而为 */ } }
  };
}

/**
 * 编译并运行一支 Swift 探针，把它的 TAP 并入当前 case。
 *
 * 编译失败 / 探针非 0 退出且没有失败断言 / 没有 plan，都转成一条可判定的失败：
 * 不允许"一个断言都没跑"被当成绿。
 *
 * @param {import('../../lib/tap.mjs').Tap} tap
 * @param {{name: string, probe: string, sources: string[], args?: string[], timeout?: number}} options
 * @returns {{stdout: string, stderr: string, status: number|null}}
 */
export function runProbeCase(tap, options) {
  let compiled = null;
  try {
    compiled = compileProbe({
      name: options.name,
      probeFile: path.join(DOMAIN_DIR, options.probe),
      // probe_support.swift 提供 TAP 与文件小工具：编号/计数只有一份实现。
      sources: [...options.sources, path.join(DOMAIN_DIR, 'probe_support.swift')]
    });
  } catch (error) {
    tap.fatal(options.name + ' 编译失败', error);
    return { stdout: '', stderr: '', status: null };
  }
  try {
    const result = runProbe(compiled.bin, options.args ?? [], { timeout: options.timeout ?? 120_000 });
    tap.absorbTap(result.stdout);
    if (result.stderr.trim() !== '') {
      for (const line of result.stderr.trimEnd().split('\n').slice(0, 10)) {
        tap.note('[' + options.name + '] stderr: ' + line);
      }
    }
    const hasFailureLine = /^not ok /m.test(result.stdout);
    if (result.status !== 0 && !hasFailureLine) {
      tap.fatal(options.name + ' 进程异常退出（exit=' + result.status + '）', new Error(result.stderr || '无输出'));
    } else if (!/^1\.\.\d+$/m.test(result.stdout)) {
      tap.fatal(options.name + ' 没有打印 TAP 计划行（输出被截断？）', new Error(result.stdout.slice(0, 500)));
    }
    return { stdout: result.stdout, stderr: result.stderr, status: result.status };
  } finally {
    compiled.cleanup();
  }
}

/** 文件权限（八进制）。用 stat(2) 的 mode & 0o777，不解析 ls。 */
export function fileMode(filePath) {
  return fs.statSync(filePath).mode & 0o777;
}

/**
 * 全目录哈希：路径 + 逐文件 sha256 + 汇总摘要。
 *
 * 为什么不用 shell 的 shasum：它不递归、也不记录文件集合，
 * "新增一个文件"和"一个文件都没变"会得到同样的输出。这里同时比对
 * 文件集合、每个文件的哈希，再给一个汇总摘要便于一行断言。
 */
export function hashTree(root) {
  const files = [];
  const walk = (current, prefix) => {
    const names = fs.readdirSync(current, { withFileTypes: true })
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const entry of names) {
      const absolute = path.join(current, entry.name);
      const relative = prefix ? prefix + '/' + entry.name : entry.name;
      if (entry.isDirectory()) { walk(absolute, relative); continue; }
      if (entry.isFile()) {
        const data = fs.readFileSync(absolute);
        files.push({
          path: relative,
          size: data.length,
          sha256: crypto.createHash('sha256').update(data).digest('hex')
        });
        continue;
      }
      files.push({ path: relative, size: -1, sha256: 'type:' + (entry.isSymbolicLink() ? 'symlink' : 'other') });
    }
  };
  walk(root, '');
  const manifest = files.map((f) => f.path + '\u0000' + f.sha256).join('\n');
  return {
    files,
    digest: crypto.createHash('sha256').update(manifest).digest('hex')
  };
}

/** 两次哈希的差异（新增 / 删除 / 修改），供失败诊断直接贴进 TAP。 */
export function diffTree(before, after) {
  const left = new Map(before.files.map((f) => [f.path, f.sha256]));
  const right = new Map(after.files.map((f) => [f.path, f.sha256]));
  const added = [];
  const removed = [];
  const modified = [];
  for (const [name, hash] of right) {
    if (!left.has(name)) { added.push(name); continue; }
    if (left.get(name) !== hash) { modified.push(name); }
  }
  for (const name of left.keys()) {
    if (!right.has(name)) { removed.push(name); }
  }
  return { added: added.sort(), removed: removed.sort(), modified: modified.sort() };
}
