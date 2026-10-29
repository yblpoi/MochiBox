/*
 * _kernel_kit.mjs —— kernel / faults 用例的共享小工具。
 *
 * 文件名以下划线开头：Tests/e2e/lib/run.mjs 发现用例时会跳过它，不会被当成一个 case 跑。
 *
 * 这里只放"每个 case 都要写一遍、写两遍必然漂移"的东西：
 *   · 隔离目录（MOCHI_DATA_DIR / --out / socket）的生命周期；
 *   · "内核就绪或没有 Aqua"的二选一等待；
 *   · 崩溃标记与退出信号的可判定断言。
 * 具体的业务断言永远留在 case 里。
 */

import fs from 'node:fs';
import path from 'node:path';

import {
  makeTempDir,
  removeDir,
  socketPathFor,
  spawnApp
} from '../lib/app.mjs';

/** 一次 case 的隔离三件套：数据目录、控制 socket、JSONL 输出。 */
export function casePaths(prefix) {
  const dir = makeTempDir(prefix);
  return {
    dir,
    socket: socketPathFor(dir),
    out: path.join(dir, 'out.jsonl'),
    file(name) { return path.join(dir, name); },
    cleanup() { removeDir(dir); }
  };
}

/** 启动被测进程；`overrides` 原样透传给 spawnApp。 */
export function startApp(paths, overrides = {}) {
  return spawnApp({
    gameDir: overrides.gameDir,
    dataDir: paths.dir,
    controlPath: overrides.controlPath === undefined ? paths.socket : overrides.controlPath,
    out: overrides.out === undefined ? paths.out : overrides.out,
    duration: overrides.duration ?? 30,
    timeoutMs: overrides.timeoutMs ?? 60_000,
    ...overrides
  });
}

export function noAqua(app) {
  return app.stdoutText.includes('kernel_reason=no_aqua')
    || app.stdoutText.includes('error_code: kernel_no_desktop_session')
    || app.stdoutText.includes('play: environment=kernel_no_desktop_session');
}

/**
 * 等 "控制通道就绪"；若进程因无 Aqua 退出，返回 {ready:false, noAqua:true}。
 * 其余失败原样抛出（附带 stdout/stderr 末尾）。
 */
export async function waitKernelReady(app, timeoutMs = 25_000) {
  try {
    const line = await app.waitForLine(/play: control=ready/, timeoutMs);
    return { ready: true, line };
  } catch (error) {
    if (noAqua(app)) { return { ready: false, noAqua: true }; }
    if (app.exitCode !== null && app.exitCode !== 0) {
      throw new Error('内核未就绪且进程已退出（exit=' + app.exitCode + '）\n' + error.message);
    }
    throw error;
  }
}

/** 整层无 Aqua 时的统一出口：输出一条明确的 SKIP，而不是失败。 */
export function skipForNoAqua(tap, name) {
  tap.ok(true, name + ' # SKIP 无 Aqua 会话（kernel_reason=no_aqua，换一台有登录桌面的 Mac 再跑）');
}

/**
 * "不崩"的可判定定义（不是"进程还在"）：
 *   · 没有被信号杀死；
 *   · stdout/stderr 里没有 fatal error / SIGSEGV / SIGABRT / Assertion failed。
 */
export function assertNoCrash(tap, app, name) {
  const combined = app.stdoutText + '\n' + app.stderrText;
  const markers = [];
  if (app.exitSignal) { markers.push('exitSignal=' + app.exitSignal); }
  for (const pattern of [/fatal error/i, /Segmentation fault/i, /SIGSEGV/i, /SIGABRT/i, /Assertion failed/i]) {
    if (pattern.test(combined)) { markers.push(String(pattern)); }
  }
  tap.ok(markers.length === 0, name, markers.length ? '命中标记：' + markers.join(', ') : undefined);
}

/** 优雅收工：quit → 等退出。返回退出码（进程已退出则直接返回）。 */
export async function quitAndWait(app, timeoutMs = 15_000) {
  if (app.exitCode !== null) { return app.exitCode; }
  if (app.control) {
    try { await app.control.quit(); } catch (error) { /* 进程可能已经自己退出 */ }
  }
  return await app.waitForExit(timeoutMs);
}

/** 取 `play: probe={json}` 并解析；没有这一行返回 null（产品只在未失败时打印）。 */
export function readProbeLine(app) {
  const line = app.line(/^play: probe=/);
  if (!line) { return null; }
  const raw = line.slice('play: probe='.length);
  try { return JSON.parse(raw); } catch (error) { return null; }
}

/** `play: http=...` 的字段解析（K1 / F10 共用，避免两处正则漂移）。 */
export function parseHttpLine(line) {
  if (!line) { return null; }
  const matched = /^play: http=(\d+) debug=0 page=(\S+) kernel=(\S+) content=(\d+)x(\d+) scale=(\S+)$/.exec(line);
  if (!matched) { return null; }
  return {
    port: Number(matched[1]),
    page: matched[2],
    kernel: matched[3],
    width: Number(matched[4]),
    height: Number(matched[5]),
    scale: Number(matched[6])
  };
}

/** 报告行 `captured=N translated=N skipped=N [reason=n,...]`。 */
export function parseReportLine(app) {
  const line = app.line(/^captured=\d+ translated=\d+ skipped=\d+/);
  if (!line) { return null; }
  const matched = /^captured=(\d+) translated=(\d+) skipped=(\d+)(?:\s+\[([^\]]*)\])?$/.exec(line);
  if (!matched) { return null; }
  const reasons = {};
  if (matched[4]) {
    for (const part of matched[4].split(',')) {
      const pair = /^(\w+)=(\d+)$/.exec(part.trim());
      if (pair) { reasons[pair[1]] = Number(pair[2]); }
    }
  }
  return {
    captured: Number(matched[1]),
    translated: Number(matched[2]),
    skipped: Number(matched[3]),
    reasons,
    line
  };
}

export function fileExists(filePath) {
  return fs.existsSync(filePath);
}
