/*
 * run.mjs —— E2E 分层串行执行器（contract / domain / kernel / faults / game 共用）。
 *
 * 做什么：
 *   1) 发现 `Tests/e2e/cases/<suite>/*.mjs`（按文件名排序，顺序固定）；
 *   2) 每个 case 起一个**独立 node 进程**跑（不共享模块状态，不依赖执行顺序）；
 *   3) 解析子进程的 TAP 输出，重新编号后汇总，最后打印总计划与 `# pass/# fail`；
 *   4) 任一 case 失败 → 退出码 1；全绿 → 退出码 0，最后一行 `E2E PASS suite=... cases=N assertions=M`。
 *
 * case 子进程自己也会打 `1..K` 与 `# pass`：这里把它们去掉，只保留总计划，避免下游
 * TAP 消费者看到多个 plan。
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(fileURLToPath(new URL('../../..', import.meta.url)));

function usage(code) {
  const text = `用法: node Tests/e2e/lib/run.mjs --suite <contract|domain|kernel|faults|game|all>`;
  (code === 0 ? console.log : console.error)(text);
  process.exit(code);
}

let suite = 'contract';
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--suite' && i + 1 < argv.length) { suite = argv[++i]; }
  else if (argv[i] === '--help' || argv[i] === '-h') { usage(0); }
  else { console.error('error: 未知参数 ' + argv[i]); usage(2); }
}

const IMPLEMENTED = new Set(['contract', 'domain', 'kernel', 'faults', 'game']);
if (!IMPLEMENTED.has(suite)) {
  console.error('error: 未知 suite "' + suite + '"（可选 ' + [...IMPLEMENTED].join('|') + '|all）');
  console.error('       all 由 Tests/e2e/run.sh 负责分层调度。');
  process.exit(2);
}

const caseDirectory = path.join(ROOT, 'Tests/e2e/cases', suite);
let files;
try {
  files = fs.readdirSync(caseDirectory)
    .filter((name) => name.endsWith('.mjs') && !name.startsWith('_'))
    .sort();
} catch (error) {
  console.error('error: 读不到用例目录 ' + caseDirectory + '：' + error.message);
  process.exit(2);
}
if (files.length === 0) {
  console.error('error: ' + caseDirectory + ' 下没有 .mjs 用例');
  process.exit(2);
}

/** 单个 case 的墙钟上限：超时即 SIGTERM 中断，并把卡住的 case 名写进 TAP。 */
const CASE_TIMEOUT_MS = 180_000;

const TEST_LINE = /^(not ok|ok)\s+(\d+)\s+-\s+(.*)$/;
let sequence = 0;
let pass = 0;
let fail = 0;

console.log('TAP version 13');
console.log('# suite=' + suite + ' cases=' + files.length + ' root=' + path.relative(ROOT, caseDirectory));

for (const file of files) {
  const fullPath = path.join(caseDirectory, file);
  const caseName = file.replace(/\.mjs$/, '');
  const started = Date.now();
  const result = spawnSync(process.execPath, [fullPath], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: CASE_TIMEOUT_MS,
    maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, E2E_SUITE: suite, E2E_CASE: caseName }
  });
  const elapsed = Date.now() - started;
  const stdout = result.stdout || '';
  const stderr = result.stderr || '';

  let caseAssertions = 0;
  let caseFailed = 0;
  for (const line of stdout.split('\n')) {
    const trimmed = line.trimEnd();
    if (trimmed === 'TAP version 13') { continue; }
    if (/^1\.\.\d+$/.test(trimmed)) { continue; }
    if (/^# pass \d+ fail \d+$/.test(trimmed)) { continue; }
    const matched = TEST_LINE.exec(trimmed);
    if (matched) {
      const ok = matched[1] === 'ok';
      sequence += 1;
      caseAssertions += 1;
      if (ok) { pass += 1; } else { fail += 1; caseFailed += 1; }
      console.log(ok ? 'ok ' + sequence + ' - ' + matched[3] : 'not ok ' + sequence + ' - ' + matched[3]);
      continue;
    }
    if (trimmed.startsWith('#')) { console.log(trimmed); }
    else if (trimmed.trim() !== '') { console.log('# [' + caseName + '] ' + trimmed); }
  }

  if (stderr.trim() !== '') {
    for (const line of stderr.trimEnd().split('\n').slice(0, 20)) {
      console.log('# [' + caseName + '] stderr: ' + line);
    }
  }

  // 子进程崩溃（语法错误、未捕获异常、超时）：必须变成一条可见的失败，而不是"少几条断言"。
  // 但它自己已经报过 not ok（tap.fatal / 断言失败）时不再补一条，否则一处故障会记两次。
  const timedOut = !!(result.error && result.error.code === 'ETIMEDOUT');
  const crashed = result.error || result.signal ||
    (result.status !== 0 && caseFailed === 0);
  if (crashed) {
    sequence += 1;
    fail += 1;
    caseFailed += 1;
    const reason = timedOut
      ? '卡住的 case=' + caseName + ' 超时 ' + Math.round(CASE_TIMEOUT_MS / 1000) + 's，已被中断'
      : (result.error
        ? String(result.error.message || result.error)
        : (result.signal ? 'signal=' + result.signal : 'exit=' + result.status + '（未输出失败断言）'));
    console.log('not ok ' + sequence + ' - [' + caseName + '] case 进程异常结束 # ' + reason);
    if (caseAssertions === 0) { caseAssertions += 1; }
  }

  console.log('# case ' + caseName + ': assertions=' + caseAssertions + ' fail=' + caseFailed + ' ' + elapsed + 'ms');
}

console.log('1..' + sequence);
console.log('# pass ' + pass + ' fail ' + fail);

if (fail !== 0) {
  console.log('E2E FAIL suite=' + suite + ' cases=' + files.length + ' assertions=' + sequence);
  process.exit(1);
}
console.log('E2E PASS suite=' + suite + ' cases=' + files.length + ' assertions=' + sequence);
process.exit(0);
