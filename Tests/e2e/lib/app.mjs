/*
 * app.mjs —— 内核层 E2E 的进程驱动库（零依赖，只用 node 内置模块）。
 *
 * 为什么需要它（而不是在 case 里直接 `spawn`）：
 *   1) **绝不留下孤儿进程**。`--play` 会建 NSWindow；进程被遗忘时用户桌面上会多一个
 *      关不掉的窗口，下一次启动还会撞端口。这里统一走 SIGTERM → SIGKILL 兜底，并在
 *      本进程 exit/SIGTERM/SIGINT 时同步收尸。
 *   2) **零固定 sleep**。所有等待都是 "轮询条件 + deadline"：`waitUntil` / `waitForLine`。
 *   3) **输出取证**。stdout/stderr 全量留内存（可选落盘），失败时能把最后 40 行贴进 TAP 诊断。
 *
 * 约定：case 结束必须 `await app.dispose()`（内部 kill + control.destroy）。
 */

import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { ControlClient } from './control.mjs';

export const REPO_ROOT = path.resolve(fileURLToPath(new URL('../../..', import.meta.url)));
export const BIN = path.join(REPO_ROOT, 'build/MochiBox.app/Contents/MacOS/MochiBox');
export const AGENT_PATH = path.join(REPO_ROOT, 'Resources/agent_mvmz.js');
export const MOCK_SERVER_PATH = path.join(REPO_ROOT, 'Fixtures/mock_translate_server.mjs');
export const FIXTURE_GAME = path.join(REPO_ROOT, 'Fixtures/e2e_game');
export const WEB_PORT_LOW = 39310;
export const WEB_PORT_HIGH = 39409;

/** 从 `Resources/agent_mvmz.js` 读 `var VERSION = n;`：K2 用它对照页面里的 `__mochibox.version`。 */
export const AGENT_VERSION = (() => {
  const source = fs.readFileSync(AGENT_PATH, 'utf8');
  const matched = /var VERSION = (\d+);/.exec(source);
  if (!matched) { throw new Error('Resources/agent_mvmz.js 里找不到 var VERSION = <n>;'); }
  return Number(matched[1]);
})();

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * 轮询直到 `predicate()` 返回真值。**唯一的等待原语**：不许在 case 里写 `await sleep(1000)`。
 * @template T
 * @param {() => T | Promise<T>} predicate
 * @param {{timeoutMs?: number, intervalMs?: number, label?: string}} options
 * @returns {Promise<T>}
 */
export async function waitUntil(predicate, options = {}) {
  const timeoutMs = options.timeoutMs ?? 15_000;
  const intervalMs = options.intervalMs ?? 50;
  const label = options.label ?? 'condition';
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const value = await predicate();
      if (value) { return value; }
    } catch (error) {
      lastError = error;
    }
    await sleep(intervalMs);
  }
  throw new Error('等待超时（' + timeoutMs + 'ms）：' + label
    + (lastError ? '（最后一次错误：' + lastError.message + '）' : ''));
}

export function makeTempDir(prefix = 'mochibox-e2e-') {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

export function removeDir(dir) {
  if (!dir) { return; }
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch (error) { /* 尽力而为 */ }
}

/** unix socket 的 `sun_path` 在 Darwin 上只有 104 字节（含结尾 NUL）；超了就换短路径。 */
export function socketPathFor(dir, name = 'ctl.sock') {
  const long = path.join(dir, name);
  if (Buffer.byteLength(long) <= 100) { return long; }
  return path.join(os.tmpdir(), 'mt-' + crypto.randomBytes(4).toString('hex') + '.sock');
}

export function readJsonl(filePath) {
  if (!fs.existsSync(filePath)) { return []; }
  const text = fs.readFileSync(filePath, 'utf8');
  const rows = [];
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) { continue; }
    try { rows.push(JSON.parse(trimmed)); } catch (error) { /* 半行（进程被杀）忽略 */ }
  }
  return rows;
}

/**
 * 产品端口分配算法的 Node 复刻（只用于"占住那个端口"这一类用例）。
 *
 * 依据 Sources/Adapters/Launcher/WebPortAssignments.swift：
 *   candidate = low + UInt32(sha256("mochibox-web-v1|" + canonicalPath).prefix(8), radix: 16) % (high-low+1)
 * canonicalPath = resolvingSymlinksInPath().standardizedFileURL.path。
 * 注意：MOCHI_DATA_DIR 必须是全新的（没有 web-ports.json 记录），否则会直接复用持久记录。
 */
export function candidateWebPort(gameDir) {
  const canonical = fs.realpathSync(gameDir);
  const digest = crypto.createHash('sha256').update('mochibox-web-v1|' + canonical).digest('hex');
  const seed = parseInt(digest.slice(0, 8), 16) >>> 0;
  return WEB_PORT_LOW + (seed % (WEB_PORT_HIGH - WEB_PORT_LOW + 1));
}

/** 选一个当前没人监听的回环端口（绑 0 → 读端口 → 立刻释放）。用于"endpoint 无监听"用例。 */
export function freeLoopbackPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

/**
 * 占住一个回环端口。返回 {port, close(), sockets}；close 幂等且**等到端口真的关掉**。
 * 端口已被别人占用时 reject（调用方自己决定"跳过"还是"失败"）。
 *
 * 为什么 close() 必须先 destroy 已接受的连接：`net.Server.close()` 只停止 accept，
 * 回调要等**所有既有连接**都结束才触发。产品的端口探测会真的连上来（connect 探活），
 * 对端不主动断开时 close 回调永远不来 —— 端口就一直被本进程占着，下一个 case 撞
 * `listen EADDRINUSE 127.0.0.1:39330`。这是真实发生过的 flake，不是理论风险。
 */
export function occupyPort(port) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    const sockets = new Set();
    server.on('connection', (socket) => {
      sockets.add(socket);
      socket.once('close', () => sockets.delete(socket));
    });
    const fail = (error) => {
      // 绑定失败时 server 不会自己释放内部 handle：显式关掉，别把它留给 GC。
      try { server.close(); } catch (e) { /* 未进入监听态 */ }
      for (const socket of sockets) { try { socket.destroy(); } catch (e) { /* 已断 */ } }
      sockets.clear();
      reject(error);
    };
    server.once('error', fail);
    server.listen(port, '127.0.0.1', () => {
      server.removeListener('error', fail);
      server.on('error', () => { /* 运行期错误不冒泡成未捕获异常 */ });
      let closing = null;
      resolve({
        port,
        sockets,
        close: () => {
          if (closing) { return closing; }
          for (const socket of sockets) { try { socket.destroy(); } catch (e) { /* 已断 */ } }
          sockets.clear();
          closing = new Promise((done) => { server.close(() => done()); });
          return closing;
        }
      });
    });
  });
}

/**
 * 端口现在能不能被重新监听（= 没有残留监听器）。用真实 bind 判定，不用 `lsof`：
 * 判据必须和产品下一步要做的事完全一致（`SO_REUSEADDR` 下 bind 成功即可）。
 * TIME_WAIT 的旧连接不算占用 —— 那正是产品也允许复用的状态。
 */
export function probePortFree(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => { resolve(false); });
    server.listen(port, '127.0.0.1', () => {
      server.close(() => resolve(true));
    });
  });
}

// ---------------------------------------------------------------------------
// 进程收尸：case 自己忘了 dispose、或被 run.mjs 的 timeout 杀掉时，保证不留下 GUI 进程。
// ---------------------------------------------------------------------------

const LIVE_CHILDREN = new Set();
let exitHookInstalled = false;

function installExitHook() {
  if (exitHookInstalled) { return; }
  exitHookInstalled = true;
  const reap = () => {
    for (const child of LIVE_CHILDREN) {
      try { child.kill('SIGKILL'); } catch (error) { /* 已退出 */ }
    }
    LIVE_CHILDREN.clear();
  };
  process.on('exit', reap);
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(signal, () => { reap(); process.exit(0); });
  }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

export class AppHandle {
  constructor(child, options) {
    this.child = child;
    this.options = options;
    this.pid = child.pid;
    this.stdoutLines = [];
    this.stderrLines = [];
    this.stdoutText = '';
    this.stderrText = '';
    this.exitCode = null;
    this.exitSignal = null;
    this.timedOut = false;
    this._partial = { stdout: '', stderr: '' };
    this._exitPromise = new Promise((resolve) => {
      child.once('exit', (code, signal) => {
        this.exitCode = code;
        this.exitSignal = signal;
        resolve({ code, signal });
      });
    });
    this.control = options.controlPath
      ? new ControlClient(options.controlPath, {
        connectTimeoutMs: options.controlConnectTimeoutMs ?? 20_000,
        responseTimeoutMs: options.controlResponseTimeoutMs ?? 15_000
      })
      : null;
    this._watchdog = null;
    if (options.timeoutMs) {
      this._watchdog = setTimeout(() => {
        this.timedOut = true;
        this.kill('SIGKILL').catch(() => {});
      }, options.timeoutMs);
      if (typeof this._watchdog.unref === 'function') { this._watchdog.unref(); }
    }
  }

  /** 最后一条匹配行；找不到返回 null。pattern 支持 string（includes）/RegExp/函数。 */
  line(pattern) {
    const match = toPredicate(pattern);
    for (let i = this.stdoutLines.length - 1; i >= 0; i--) {
      if (match(this.stdoutLines[i])) { return this.stdoutLines[i]; }
    }
    return null;
  }

  lines(pattern) {
    const match = toPredicate(pattern);
    return this.stdoutLines.filter((line) => match(line));
  }

  /** 等 stdout 出现匹配行。超时把最后 30 行塞进错误消息 —— 失败时唯一的现场。 */
  async waitForLine(pattern, timeoutMs = 20_000) {
    const match = toPredicate(pattern);
    try {
      return await waitUntil(() => {
        for (const line of this.stdoutLines) {
          if (match(line)) { return line; }
        }
        if (this.exitCode !== null) {
          throw new Error('进程已退出（exit=' + this.exitCode + '）');
        }
        return null;
      }, { timeoutMs, intervalMs: 20, label: 'stdout 出现 ' + describe(pattern) });
    } catch (error) {
      throw new Error(error.message + '\n--- stdout 末尾 ---\n' + this.tail(this.stdoutLines)
        + '\n--- stderr 末尾 ---\n' + this.tail(this.stderrLines));
    }
  }

  async waitForExit(timeoutMs = 20_000) {
    if (this.exitCode !== null) { return this.exitCode; }
    let timer = null;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(
        '进程 ' + this.pid + ' 在 ' + timeoutMs + 'ms 内没有退出\n--- stdout 末尾 ---\n' + this.tail(this.stdoutLines)
        + '\n--- stderr 末尾 ---\n' + this.tail(this.stderrLines))), timeoutMs);
    });
    try {
      const result = await Promise.race([this._exitPromise, timeout]);
      return result.code;
    } finally {
      if (timer) { clearTimeout(timer); }
    }
  }

  /**
   * SIGTERM → 等 `graceMs` → SIGKILL。幂等；已退出直接返回。
   * 不用 `child.killed` 判断：那个标志只表示"发过信号"，不表示进程死了。
   */
  async kill(graceMs = 3_000) {
    if (this.exitCode !== null) { return this.exitCode; }
    try { this.child.kill('SIGTERM'); } catch (error) { /* 已退出 */ }
    const exited = await Promise.race([
      this._exitPromise.then(() => true),
      sleep(graceMs).then(() => false)
    ]);
    if (!exited) {
      try { this.child.kill('SIGKILL'); } catch (error) { /* 已退出 */ }
      await this._exitPromise;
    }
    return this.exitCode;
  }

  async dispose() {
    if (this._watchdog) { clearTimeout(this._watchdog); this._watchdog = null; }
    if (this.control) { this.control.close(); }
    await this.kill();
    LIVE_CHILDREN.delete(this.child);
  }

  tail(lines = this.stdoutLines, count = 30) {
    return lines.slice(-count).join('\n');
  }
}

function describe(pattern) {
  if (typeof pattern === 'string') { return JSON.stringify(pattern); }
  if (pattern instanceof RegExp) { return String(pattern); }
  return '<predicate>';
}

function toPredicate(pattern) {
  if (typeof pattern === 'function') { return pattern; }
  if (pattern instanceof RegExp) { return (line) => pattern.test(line); }
  return (line) => line.includes(String(pattern));
}

function attachStream(handle, stream, key, targetKey) {
  if (!stream) { return; }
  stream.setEncoding('utf8');
  stream.on('data', (chunk) => {
    handle[targetKey] += chunk;
    handle._partial[key] += chunk;
    let index;
    while ((index = handle._partial[key].indexOf('\n')) >= 0) {
      const line = handle._partial[key].slice(0, index);
      handle._partial[key] = handle._partial[key].slice(index + 1);
      handle[key === 'stdout' ? 'stdoutLines' : 'stderrLines'].push(line);
    }
  });
  stream.on('end', () => {
    if (handle._partial[key]) {
      handle[key === 'stdout' ? 'stdoutLines' : 'stderrLines'].push(handle._partial[key]);
      handle._partial[key] = '';
    }
  });
}

/**
 * 启动被测进程。
 *
 * @param {{
 *   gameDir?: string,
 *   args?: string[],
 *   env?: Record<string,string>,
 *   dataDir?: string,
 *   out?: string,
 *   controlPath?: string,
 *   duration?: number,
 *   kernel?: string,
 *   e2e?: boolean,
 *   timeoutMs?: number,
 *   stdoutFile?: string,
 *   stderrFile?: string
 * }} options
 * @returns {AppHandle}
 */
export function spawnApp(options = {}) {
  installExitHook();
  const dataDir = options.dataDir ?? makeTempDir();
  if (!fs.existsSync(dataDir)) { fs.mkdirSync(dataDir, { recursive: true }); }

  const args = [];
  if (options.gameDir) { args.push('--play', options.gameDir); }
  if (options.controlPath) { args.push('--control', options.controlPath); }
  if (options.duration !== undefined) { args.push('--duration', String(options.duration)); }
  if (options.out) { args.push('--out', options.out); }
  if (options.kernel) { args.push('--kernel', options.kernel); }
  args.push(...(options.args ?? []));

  const env = { ...process.env, ...(options.env ?? {}) };
  env.MOCHI_DATA_DIR = dataDir;
  if (options.e2e !== false) { env.MOCHI_E2E = env.MOCHI_E2E ?? '1'; }

  const child = spawn(options.bin ?? BIN, args, {
    cwd: options.cwd ?? REPO_ROOT,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: false
  });
  LIVE_CHILDREN.add(child);

  const handle = new AppHandle(child, {
    dataDir,
    args,
    controlPath: options.controlPath,
    timeoutMs: options.timeoutMs ?? 0,
    ...options
  });
  handle.dataDir = dataDir;

  attachStream(handle, child.stdout, 'stdout', 'stdoutText');
  attachStream(handle, child.stderr, 'stderr', 'stderrText');

  if (options.stdoutFile) {
    fs.mkdirSync(path.dirname(options.stdoutFile), { recursive: true });
    fs.writeFileSync(options.stdoutFile, '');
    child.stdout.on('data', (chunk) => fs.appendFileSync(options.stdoutFile, chunk));
  }
  if (options.stderrFile) {
    fs.mkdirSync(path.dirname(options.stderrFile), { recursive: true });
    fs.writeFileSync(options.stderrFile, '');
    child.stderr.on('data', (chunk) => fs.appendFileSync(options.stderrFile, chunk));
  }

  return handle;
}

// ---------------------------------------------------------------------------
// mock 翻译后端
// ---------------------------------------------------------------------------

export class MockHandle {
  constructor(child, options) {
    this.child = child;
    this.options = options;
    this.stdoutLines = [];
    this.stderrText = '';
    this.port = null;
    this._partial = '';
    this._exit = new Promise((resolve) => child.once('exit', resolve));
  }

  async waitForPort(timeoutMs = 10_000) {
    await waitUntil(() => this.port !== null, { timeoutMs, intervalMs: 20, label: 'mock 服务打印端口' });
    return this.port;
  }

  requestsDir() {
    return this.options.recordDir;
  }

  requests() {
    return this.options.recordDir ? readJsonl(path.join(this.options.recordDir, 'requests.jsonl')).length : 0;
  }

  entries() {
    return this.options.recordDir ? readJsonl(path.join(this.options.recordDir, 'requests.jsonl')) : [];
  }

  async stop(graceMs = 2_000) {
    if (this.child.exitCode !== null) { LIVE_CHILDREN.delete(this.child); return; }
    try { this.child.kill('SIGTERM'); } catch (error) { /* 已退出 */ }
    const exited = await Promise.race([
      this._exit.then(() => true),
      sleep(graceMs).then(() => false)
    ]);
    if (!exited) {
      try { this.child.kill('SIGKILL'); } catch (error) { /* 已退出 */ }
      await this._exit;
    }
    LIVE_CHILDREN.delete(this.child);
  }
}

/** 启动 mock 后端；`--port 0` 由内核选端口，实际值从启动行解析（没有 TOCTOU）。 */
export async function spawnMock(options = {}) {
  installExitHook();
  const args = [MOCK_SERVER_PATH, '--port', '0', '--mode', options.mode ?? 'ok'];
  if (options.recordDir) { args.push('--record', options.recordDir); }
  if (options.delayMs) { args.push('--delay-ms', String(options.delayMs)); }
  const child = spawn(process.execPath, args, {
    cwd: REPO_ROOT,
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  LIVE_CHILDREN.add(child);
  const handle = new MockHandle(child, options);
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    handle._partial += chunk;
    let index;
    while ((index = handle._partial.indexOf('\n')) >= 0) {
      const line = handle._partial.slice(0, index);
      handle._partial = handle._partial.slice(index + 1);
      handle.stdoutLines.push(line);
      const matched = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(line);
      if (matched) { handle.port = Number(matched[1]); }
    }
  });
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { handle.stderrText += chunk; });
  try {
    await handle.waitForPort();
  } catch (error) {
    // 起不来就当场收尸：否则这个 node 子进程会活到 case 进程退出，
    // 端口与 mock 记录目录都留在一个"已经失败但没清理"的状态里。
    await handle.stop(0);
    LIVE_CHILDREN.delete(child);
    throw error;
  }
  return handle;
}

// ---------------------------------------------------------------------------
// 无浏览器证据
// ---------------------------------------------------------------------------

/// 浏览器特征只看 argv（与产品 ProcessInspector.isBrowser 同族），不读可执行路径。
const BROWSER_ARGV = /Chrome for Testing|Google Chrome|Chromium/;

/**
 * 一次 `ps -axo pid=,ppid=,command=` 快照 → [{pid, ppid, command}]。
 * 用 `=` 后缀让列名消失、左对齐，解析只有一条正则；command 是完整 argv（不截断）。
 */
function processTable() {
  const result = spawnSync('ps', ['-axo', 'pid=,ppid=,command='], {
    encoding: 'utf8',
    timeout: 5_000,
    maxBuffer: 8 * 1024 * 1024
  });
  if (result.error) { throw new Error('ps 执行失败：' + result.error.message); }
  if (result.status !== 0) {
    throw new Error('ps 失败（status=' + result.status + '）：' + (result.stderr || '').trim());
  }
  const rows = [];
  for (const line of String(result.stdout).split('\n')) {
    const matched = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
    if (matched) { rows.push({ pid: Number(matched[1]), ppid: Number(matched[2]), command: matched[3] }); }
  }
  return rows;
}

/**
 * **被测进程的子孙**里 argv 命中浏览器特征的进程。
 *
 * 为什么不再用 `pgrep -f` 做全机快照 + PID 差：那是在问"整台机器上多了哪些浏览器"，
 * 任何 argv 里恰好带 `Google Chrome` 的短命进程（采样脚本、编辑器 grep、终端的
 * `exec -a` 诱饵）都会被算成"被测进程泄漏了浏览器"，整层 kernel 假红。
 * 这里只在 rootPid 的父子子树里找：祖先链不在被测进程下的进程一律忽略。
 *
 * rootPid 已退出（或未给出）→ 子树不存在 → 返回空数组：此时"归因"已经不成立，
 * 不能用全机快照去猜。运行期采样（K10 在会话进行中取两次）才是有效证据。
 *
 * @param {number} rootPid 被测进程 pid
 * @returns {{pid: number, command: string}[]}
 */
export function chromeProcesses(rootPid) {
  if (!Number.isInteger(rootPid) || rootPid <= 0) { return []; }
  const rows = processTable();
  const childrenOf = new Map();
  for (const row of rows) {
    if (!childrenOf.has(row.ppid)) { childrenOf.set(row.ppid, []); }
    childrenOf.get(row.ppid).push(row);
  }
  const descendants = [];
  const queue = [rootPid];
  const seen = new Set([rootPid]);
  while (queue.length > 0) {
    const current = queue.shift();
    for (const child of (childrenOf.get(current) ?? [])) {
      if (seen.has(child.pid)) { continue; }
      seen.add(child.pid);
      descendants.push(child);
      queue.push(child.pid);
    }
  }
  return descendants
    .filter((row) => BROWSER_ARGV.test(row.command))
    .map((row) => ({ pid: row.pid, command: row.command }));
}
