#!/usr/bin/env node
/*
 * mock_openai_server.mjs —— **合成替身**，零依赖的 OpenAI 兼容 mock 后端（仅用于本机端到端自证）。
 * 不是真实模型服务，词典只有十几条；存在的意义是让 E2E 不依赖任何外部网络或密钥。
 *
 *   node Fixtures/mock_openai_server.mjs [port]           # 词典模式（默认，行为不变）
 *   node Fixtures/mock_openai_server.mjs --echo [port]    # 回声模式：每段前加 `◇` 原样返回
 *
 * 为什么需要 `--echo`（v0.2 AC-3）：真实测试游戏的文本全是简体中文，
 * 词典模式的词典一条都命中不了 → "译文 == 原文"，无法证明回绘链路。
 * 回声模式让每一段都变成**肉眼可辨的不同字符串**，于是
 * `translated > 0` 与页面 `__mochibox.probe().replaced > 0` 才有意义。
 * 它证明的是**通道与回绘**，不是翻译质量 —— 这一点在交付说明里必须写清。
 *
 * 实现 POST /v1/chat/completions：从 user 消息里解析 JSON 字符串数组，
 * 逐段翻译（段之间用 U+001F 连接），按 OpenAI 形状返回。
 */

import http from 'node:http';

const RAW_ARGS = process.argv.slice(2);
const ECHO = RAW_ARGS.includes('--echo');
const POSITIONAL = RAW_ARGS.filter((arg) => !arg.startsWith('--'));
const PORT = Number(POSITIONAL[0] || process.env.MOCK_PORT || 8787);
const US = '\u001f';

const DICTIONARY = {
  '魔物が来た': '魔物来了',
  'こんにちは': '你好',
  '勇者よ、目を覚ませ': '勇者啊，醒醒吧',
  'おはよう': '早上好',
  'ありがとう': '谢谢你',
  'さようなら': '再见',
  '戦闘開始': '战斗开始',
  '回復した': '已恢复',
  'アイテムを手に入れた': '获得了道具',
  'セーブしますか？': '要保存吗？',
  'はい': '是',
  'いいえ': '否',
  'ゲームタイトル': '游戏标题',
  '経験値を獲得': '获得经验值',
  'レベルアップ': '升级了'
};

/**
 * 逐段翻译；未收录的段落回落为原文（保证段数与顺序不变）。
 * @param {string} text U+001F 连接的原文
 * @returns {string} U+001F 连接的译文
 */
function translateJoined(text) {
  return text
    .split(US)
    .map((part) => {
      const trimmed = part.trim();
      if (trimmed === '') return part;
      // 回声模式：每段前加 ◇ —— 段数、顺序都不变，回填时的段数校验仍然成立。
      if (ECHO) return '◇' + part;
      if (Object.prototype.hasOwnProperty.call(DICTIONARY, trimmed)) {
        return DICTIONARY[trimmed];
      }
      return part;
    })
    .join(US);
}

const server = http.createServer((req, res) => {
  if (req.method === 'POST' && (req.url === '/v1/chat/completions' || req.url === '/chat/completions')) {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      let items = [];
      try {
        const payload = JSON.parse(body);
        const messages = payload.messages || [];
        const userText = messages
          .filter((message) => message && message.role === 'user')
          .map((message) => message.content)
          .join('');
        try {
          const parsed = JSON.parse(userText);
          items = Array.isArray(parsed) ? parsed.map((item) => String(item)) : [String(userText)];
        } catch (parseError) {
          items = [String(userText)];
        }
      } catch (error) {
        items = [];
      }

      const translated = items.map((item) => translateJoined(item));
      const content = JSON.stringify(translated);
      const responseBody = JSON.stringify({
        id: 'mock-' + Date.now(),
        object: 'chat.completion',
        model: 'mock-translator',
        choices: [
          {
            index: 0,
            message: { role: 'assistant', content },
            finish_reason: 'stop'
          }
        ],
        usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }
      });

      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(responseBody);
      console.log(`[mock-openai]${ECHO ? '[echo]' : ''} items=${items.length} -> ${content}`);
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end('{"error":"not found"}');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[mock-openai]${ECHO ? '[echo]' : ''} listening on http://127.0.0.1:${PORT}`);
});
