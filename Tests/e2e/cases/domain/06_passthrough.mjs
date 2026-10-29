/*
 * D6 —— 直通后端（P0-11）
 *
 * 断言：默认后端就是 passthrough（Settings 默认 + AttachCLI 的 --provider 缺省值）；
 * provider 与管线两层的译文都与原文**逐字节**相等（含 \C[2] 与 U+001F）；
 * passthrough 不走 provider、不写缓存；合规开关 allowSendTextToBackend=false 时
 * 即便 backendType=openai 也强制直通；整个探测过程对本地监听端口的请求数为 0。
 *
 * 依据：docs/prd.md P0-11 原文（translated === text、status=passthrough、
 * 不产生任何网络请求、设为默认后端）；Sources/Infra/Translators.swift:172-190（PassthroughProvider）、
 * :430-448（ProviderFactory 按 effectiveBackend 分派）、Sources/Infra/Stores.swift:455-460（effectiveBackend）；
 * Sources/App/AttachCLI.swift:109（--provider 缺省 passthrough）。
 *
 * 不验："整条链路（启动/采集/回绘）仍可跑通"属内核层（kernel K1/K3），这里不重复。
 */
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';

import { runCase } from '../../lib/tap.mjs';
import { makeWork, ROOT, SRC, runProbeCase } from './_domain_kit.mjs';

runCase('domain-d6', async (tap) => {
  const work = makeWork('mochibox-d6-');
  let server = null;
  const sockets = new Set();
  const requests = [];
  try {
    // 本地监听：只要产品真的发一次 HTTP，这里就会记录到。端口用 0 现取，避免冲突。
    server = http.createServer((req, res) => {
      requests.push({ method: req.method, url: req.url });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{}');
    });
    // keep-alive 连接会让 server.close() 的回调永远等下去；显式跟踪并断开。
    server.on('connection', (socket) => {
      sockets.add(socket);
      socket.once('close', () => sockets.delete(socket));
    });
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const port = server.address().port;

    runProbeCase(tap, {
      name: 'domain_resilience_d6',
      probe: 'probe_resilience.swift',
      sources: SRC.pipeline(),
      args: ['--only', 'D6', '--work', work.dir, '--http-port', String(port)]
    });

    // 零网络请求：endpoint 指向这个活着的监听器，passthrough 下它一次都不该被访问。
    tap.eq(requests.length, 0, 'D6 passthrough 全程零网络请求（本地监听计数 = 0）');

    // CLI 缺省值：不传 --provider 时就是 passthrough（源码常量，可被下一行断言证伪）
    const cliSource = fs.readFileSync(path.join(ROOT, 'Sources/App/AttachCLI.swift'), 'utf8');
    tap.ok(/options\.provider = value\(of: "--provider"\) \?\? "passthrough"/.test(cliSource),
      'D6 CLI 不传 --provider 时默认 passthrough（AttachCLI.swift:109）');
  } finally {
    if (server) {
      for (const socket of sockets) { try { socket.destroy(); } catch (error) { /* 已断 */ } }
      sockets.clear();
      await new Promise((resolve) => { server.close(() => resolve()); });
    }
    work.cleanup();
  }
});
