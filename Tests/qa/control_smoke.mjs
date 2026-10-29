#!/usr/bin/env node
/*
 * control_smoke.mjs —— `--control` 控制通道冒烟（unix socket + NDJSON）。
 *
 * 只做一件事：证明"进程外能驱动并观测一个正在跑的 --play 会话"。
 * 五个 op 的**语义**在契约里的部分必须逐条对上，而不是"连上了就算成功"：
 *   ping  → 身份与存活（kernel / pid / uptimeSec）
 *   state → 实时计数（**不得**因为被问一次就多跑一次 drain）
 *   eval  → 值 / JS 异常 两种成功形态
 *   close → 复用 --close-after 的实现（本脚本只验应答；关窗证据由 --play 的 stdout 给）
 *   quit  → 不在本脚本里跑（它会结束进程，留给需要"中途收工"的用例）
 *
 * 依赖：只有 node 内置的 net。TAP 输出（TAP version 13），退出码 0 = 全通过。
 *
 * 用法：
 *   node Tests/qa/control_smoke.mjs /tmp/mochibox-e2e-test.sock
 *   CONTROL_CONNECT_TIMEOUT_MS=60000 ...   # 等 socket 出现的上限（session 启动到 attach 完要时间）
 */

import net from 'node:net';

const socketPath = process.argv[2];
if (!socketPath) {
  console.error('用法: node Tests/qa/control_smoke.mjs <socket 路径>');
  process.exit(2);
}

const CONNECT_TIMEOUT_MS = Number(process.env.CONTROL_CONNECT_TIMEOUT_MS || 60000);
const RESPONSE_TIMEOUT_MS = Number(process.env.CONTROL_RESPONSE_TIMEOUT_MS || 10000);

// ── TAP 记账 ──────────────────────────────────────────────────────────────

let total = 0;
let passed = 0;
let failed = 0;

function ok(name, condition, detail) {
  total += 1;
  if (condition) {
    passed += 1;
    console.log('ok ' + total + ' - ' + name);
  } else {
    failed += 1;
    console.log('not ok ' + total + ' - ' + name);
    if (detail !== undefined) {
      console.log('#   got: ' + JSON.stringify(detail));
    }
  }
}

function bail(message) {
  console.log('Bail out! ' + message);
  console.log('1..' + total);
  console.log('# pass ' + passed + ' fail ' + failed);
  process.exit(1);
}

// ── 客户端 ────────────────────────────────────────────────────────────────

function connectOnce(path) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(path);
    socket.setEncoding('utf8');
    socket.once('connect', () => resolve(socket));
    socket.once('error', reject);
  });
}

async function connectWithRetry(path, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      return await connectOnce(path);
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error('连不上 ' + path + '（' + (lastError ? lastError.message : 'timeout') + '）');
}

const socket = await connectWithRetry(socketPath, CONNECT_TIMEOUT_MS);

let buffer = '';
const waiters = [];
const leftover = [];

socket.on('data', (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      parsed = { __unparsable: line };
    }
    const waiter = waiters.shift();
    if (waiter) waiter(parsed);
    else leftover.push(parsed);
  }
});

socket.on('error', (error) => {
  // close 之后服务端会断开连接：那是预期，不是失败。
  while (waiters.length) waiters.shift()(null);
});

let nextId = 0;

async function request(op, extra) {
  const id = ++nextId;
  const payload = Object.assign({ id: id, op: op }, extra || {});
  const waiting = new Promise((resolve) => waiters.push(resolve));
  socket.write(JSON.stringify(payload) + '\n');
  const timer = new Promise((resolve) => setTimeout(() => resolve(null), RESPONSE_TIMEOUT_MS));
  const response = await Promise.race([waiting, timer]);
  if (!response) bail('op=' + op + ' 在 ' + RESPONSE_TIMEOUT_MS + 'ms 内没有应答');
  response.__sentId = id;
  return response;
}

// ── 1) ping ──────────────────────────────────────────────────────────────

const ping = await request('ping');
ok('ping 应答 ok=true', ping.ok === true, ping);
ok('ping 原样回显 id', ping.id === ping.__sentId, { id: ping.id, sent: ping.__sentId });
ok('ping kernel 是已知内核', ping.kernel === 'embedded' || ping.kernel === 'chromium', ping.kernel);
ok('ping pid 是正整数', Number.isInteger(ping.pid) && ping.pid > 0, ping.pid);
ok(
  'ping uptimeSec 是非负数',
  typeof ping.uptimeSec === 'number' && Number.isFinite(ping.uptimeSec) && ping.uptimeSec >= 0,
  ping.uptimeSec
);

// ── 2) state ─────────────────────────────────────────────────────────────

const state = await request('state');
ok('state 应答 ok=true', state.ok === true, state);
ok(
  'state 三个计数都是非负整数',
  [state.captured, state.translated, state.skipped].every((n) => Number.isInteger(n) && n >= 0),
  { captured: state.captured, translated: state.translated, skipped: state.skipped }
);
ok('state closed=false（会话还开着）', state.closed === false, state.closed);
ok('state kernel 与 ping 一致', state.kernel === ping.kernel, { state: state.kernel, ping: ping.kernel });

// ── 3) eval：正常值 ──────────────────────────────────────────────────────

const sum = await request('eval', { expression: '1+1' });
ok('eval 1+1 → value="2"', sum.ok === true && sum.value === '2', sum);

// ── 4) eval：页面抛异常（不是通道故障）──────────────────────────────────

const boom = await request('eval', { expression: '(function(){ throw new Error("control_smoke_boom"); })()' });
ok(
  'eval 抛异常 → js_error',
  boom.ok === false && boom.error === 'js_error' && typeof boom.message === 'string' && boom.message.length > 0,
  boom
);

// ── 5) 未知 op ───────────────────────────────────────────────────────────

const unknown = await request('definitely_not_an_op');
ok('未知 op → unknown_op', unknown.ok === false && unknown.error === 'unknown_op', unknown);

// ── 6) close ─────────────────────────────────────────────────────────────

const closed = await request('close');
ok('close 应答 ok=true', closed.ok === true, closed);

console.log('1..' + total);
console.log('# pass ' + passed + ' fail ' + failed);
socket.destroy();
process.exit(failed === 0 ? 0 : 1);
