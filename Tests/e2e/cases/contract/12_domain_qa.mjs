/*
 * 12_domain_qa.mjs —— Domain / Adapter 层的 Swift 探针入口（qa_probe.swift）。
 *
 * 覆盖：
 *   · V4S-6a/b  跳过句不写缓存、不打后端（复刻 SessionController 的规范顺序）
 *   · V4S-1..5  Swift 侧 SkipRules（19 条，含全角/尾空格/剥码/归一化口径）
 *   · V6-01..25 EngineDetector（13 类引擎正例 + 空目录/非目录/index.html/冲突/大小写/隐藏文件）
 *   · V5-01..05 HTTP 错误码映射（401/429/500/非 JSON/超时）—— 打本地 127.0.0.1 的
 *               Tests/qa/error_server.py，不读外网
 *
 * 本文件只负责编译、起停本地错误后端、把子进程 TAP 并入本用例。
 * 端口用 0 号端口现取空闲端口，进程退出即 SIGKILL —— 不依赖 18787、不与别的测试抢端口。
 */
import net from 'node:net';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { compileProbe, runProbe, SOURCES, ROOT } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';
import { sleep } from '../../lib/harness.mjs';

const PROBE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'qa_probe.swift');
const ERROR_SERVER = path.join(ROOT, 'Tests/qa/error_server.py');

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

async function waitForPort(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const connected = await new Promise((resolve) => {
      const socket = net.connect(port, '127.0.0.1');
      socket.once('connect', () => { socket.destroy(); resolve(true); });
      socket.once('error', () => { socket.destroy(); resolve(false); });
    });
    if (connected) { return true; }
    await sleep(50);
  }
  return false;
}

runCase('domain', async (tap) => {
  let compiled = null;
  let server = null;
  let serverLog = '';
  try {
    compiled = compileProbe({ name: 'qa_probe', probeFile: PROBE, sources: SOURCES.qa() });

    const port = await freePort();
    server = spawn('python3', [ERROR_SERVER, String(port)], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
    server.stdout.on('data', (chunk) => { serverLog += String(chunk); });
    server.stderr.on('data', (chunk) => { serverLog += String(chunk); });

    if (!await waitForPort(port, 8000)) {
      tap.fatal('本地 error_server 未就绪（V5 无法运行）',
        new Error(serverLog.slice(-800) || '8s 内端口未监听：' + port));
      return;
    }

    const result = runProbe(compiled.bin, ['--http-base', 'http://127.0.0.1:' + port]);
    tap.absorbTap(result.stdout);

    if (result.stderr.trim() !== '') {
      for (const line of result.stderr.trimEnd().split('\n').slice(0, 10)) { tap.note('stderr: ' + line); }
    }
    if (result.status !== 0 && !/^not ok /m.test(result.stdout)) {
      tap.fatal('qa_probe 进程异常退出（exit=' + result.status + '）', new Error(result.stderr || '无输出'));
    } else if (!/^1\.\.\d+$/m.test(result.stdout)) {
      tap.fatal('qa_probe 没有打印 TAP 计划行（输出被截断？）', new Error(result.stdout.slice(0, 500)));
    }
  } catch (error) {
    tap.fatal('qa_probe 编译/执行失败', error);
  } finally {
    if (server) { try { server.kill('SIGKILL'); } catch (e) { /* ignore */ } }
    if (compiled) { compiled.cleanup(); }
  }
});
