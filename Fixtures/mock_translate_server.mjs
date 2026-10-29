#!/usr/bin/env node
/*
 * mock_translate_server.mjs —— E2E 专用的 OpenAI 兼容 mock 后端（零依赖，只用 node 内置模块）。
 *
 * 与 Fixtures/mock_openai_server.mjs 的区别只有一条，但很关键：**它记录每一次请求**。
 * 「第二次启动是否还打后端」这类断言必须看请求数，而不是看翻译结果 —— 结果相同既可能是
 * 缓存命中，也可能是又翻了一遍。
 *
 * 用法：
 *   node Fixtures/mock_translate_server.mjs --port <p> --mode <ok|401|429|500|nonjson|slow> --record <dir>
 *
 *   --port 0        由内核选端口，启动行里打印实际端口（测试用这个形态，避免 TOCTOU）
 *   --record <dir>  每个请求追加一行 {ts,path,status,body} 到 <dir>/requests.jsonl
 *   --mode slow     故意拖 60s 不响应（模拟后端慢；测试用 --duration 而不是等它）
 *
 * 响应形状是标准 chat.completion，choices[0].message.content 是 JSON 字符串数组：
 * 长度 == 请求 items 长度，每项 "译:" + 原文（段内 U+001F 原样保留）。
 *
 * 退出时打印 requests=<N>（SIGTERM / SIGINT / 自然退出都走同一条打印路径）。
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

function parseArgs(argv) {
  const options = { port: 0, mode: 'ok', record: '', delayMs: 60_000 };
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (token === '--port' && i + 1 < argv.length) { options.port = Number(argv[++i]); }
    else if (token === '--mode' && i + 1 < argv.length) { options.mode = argv[++i]; }
    else if (token === '--record' && i + 1 < argv.length) { options.record = argv[++i]; }
    else if (token === '--delay-ms' && i + 1 < argv.length) { options.delayMs = Number(argv[++i]); }
    else if (token === '--help' || token === '-h') {
      console.log('用法: mock_translate_server.mjs --port <p> --mode <ok|401|429|500|nonjson|slow> --record <dir>');
      process.exit(0);
    }
  }
  if (!Number.isInteger(options.port) || options.port < 0 || options.port > 65535) {
    console.error('error: --port 必须是 0–65535 的整数');
    process.exit(2);
  }
  if (!['ok', '401', '429', '500', 'nonjson', 'slow'].includes(options.mode)) {
    console.error('error: --mode 必须是 ok|401|429|500|nonjson|slow');
    process.exit(2);
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));

if (options.record) {
  fs.mkdirSync(options.record, { recursive: true });
  fs.writeFileSync(path.join(options.record, 'requests.jsonl'), '');
}

let requestCount = 0;

function record(entry) {
  if (!options.record) { return; }
  fs.appendFileSync(path.join(options.record, 'requests.jsonl'), JSON.stringify(entry) + '\n');
}

/** 从 OpenAI 请求体里还原 items 数组；解析失败按单条原文处理，保证"不崩"。 */
function parseItems(body) {
  try {
    const payload = JSON.parse(body || '{}');
    const messages = Array.isArray(payload.messages) ? payload.messages : [];
    const userText = messages
      .filter((message) => message && message.role === 'user')
      .map((message) => String(message.content == null ? '' : message.content))
      .join('');
    try {
      const parsed = JSON.parse(userText);
      if (Array.isArray(parsed)) { return parsed.map((item) => String(item)); }
    } catch (error) { /* 不是 JSON 数组：按单条处理 */ }
    return [userText];
  } catch (error) {
    return [];
  }
}

function completionBody(items) {
  const translated = items.map((item) => '译:' + item);
  return JSON.stringify({
    id: 'mock-translate-' + Date.now(),
    object: 'chat.completion',
    model: 'mock-translator',
    choices: [{ index: 0, message: { role: 'assistant', content: JSON.stringify(translated) }, finish_reason: 'stop' }],
    usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }
  });
}

function respond(res, status, body, contentType) {
  res.writeHead(status, { 'Content-Type': contentType || 'application/json; charset=utf-8' });
  res.end(body);
}

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || (req.url !== '/v1/chat/completions' && req.url !== '/chat/completions')) {
    respond(res, 404, JSON.stringify({ error: { message: 'not found' } }));
    return;
  }

  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    requestCount += 1;
    const items = parseItems(body);

    const finish = (status, payload, contentType) => {
      record({ ts: Date.now(), path: req.url, status: status, body: body });
      respond(res, status, payload, contentType);
    };

    switch (options.mode) {
      case '401':
        finish(401, JSON.stringify({ error: { message: 'mock unauthorized', type: 'invalid_request_error' } }));
        return;
      case '429':
        finish(429, JSON.stringify({ error: { message: 'mock rate limited', type: 'rate_limit_error' } }));
        return;
      case '500':
        finish(500, JSON.stringify({ error: { message: 'mock internal error', type: 'server_error' } }));
        return;
      case 'nonjson':
        // 200 + 非 JSON：走 OpenAICompatibleProvider.parseContent 的 badResponse 分支。
        finish(200, 'this is not json at all', 'text/plain; charset=utf-8');
        return;
      case 'slow':
        setTimeout(() => {
          finish(200, completionBody(items));
        }, Number.isFinite(options.delayMs) && options.delayMs > 0 ? options.delayMs : 60_000);
        return;
      default:
        finish(200, completionBody(items));
    }
  });
});

server.listen(options.port, '127.0.0.1', () => {
  const actual = server.address().port;
  console.log('[mock-translate] listening on http://127.0.0.1:' + actual + ' mode=' + options.mode
    + (options.record ? ' record=' + path.join(options.record, 'requests.jsonl') : ''));
});

function shutdown() {
  console.log('requests=' + requestCount);
  server.close(() => process.exit(0));
  // 有 keep-alive 连接时 server.close 不会立刻回调：给一拍就硬退，避免测试收尾挂住。
  setTimeout(() => process.exit(0), 200).unref();
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
