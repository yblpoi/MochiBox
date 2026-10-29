/*
 * D3 —— 密钥脱敏与文件权限（P0-12）
 *
 * 断言：sk- / Bearer / DeepL-Auth-Key 三种形态一律脱敏为"sk-…后4位"（maskToken 的规则，
 * 不是臆造的"前3后4"）；脱敏后原文不出现；mask 幂等；MochiBoxError.rawSnippet 构造即脱敏；
 * 会话日志落盘同样脱敏；settings.json / credentials.json / 日志文件权限都是 0600。
 *
 * 依据：docs/prd.md P0-12 原文（"apiKey 一律脱敏为 sk-…后4位"、"权限为 0600"）；
 * Sources/Domain/Models/ErrorModels.swift:250-300（SecretMask）；
 * Sources/Infra/Stores.swift:573/590（两处原子写都传 0o600）、:190（日志文件 0600）。
 *
 * 已修复（D19，`e091c6e`）：短 sk- 密钥（如 sk-abc）不再回退明文，一律脱敏为 `***`。
 * 本文件 D3 的四条短 key 断言（含 `task-manager` 左边界反例）守回归。
 */
import { runCase } from '../../lib/tap.mjs';
import { fileMode, makeWork, SRC, runProbeCase } from './_domain_kit.mjs';
import fs from 'node:fs';
import path from 'node:path';

runCase('domain-d3', (tap) => {
  const work = makeWork('mochibox-d3-');
  try {
    runProbeCase(tap, {
      name: 'domain_store_d3',
      probe: 'probe_store.swift',
      sources: SRC.store(),
      args: ['--only', 'D3', '--work', work.dir]
    });

    // 权限用 stat(2) 断言：产品写文件，case 侧独立取证。
    const credentials = path.join(work.dir, 'perm', 'credentials.json');
    const settings = path.join(work.dir, 'perm', 'settings.json');
    tap.eq(fileMode(credentials), 0o600, 'D3 credentials.json 权限 0600（stat）');
    tap.eq(fileMode(settings), 0o600, 'D3 settings.json 权限 0600（stat）');

    const logDir = path.join(work.dir, 'mask');
    const logs = fs.existsSync(logDir) ? fs.readdirSync(logDir).filter((n) => n.startsWith('session-')) : [];
    tap.ok(logs.length === 1, 'D3 会话日志文件恰好 1 份', logs.join(','));
    if (logs.length === 1) {
      tap.eq(fileMode(path.join(logDir, logs[0])), 0o600, 'D3 会话日志文件权限 0600（stat）');
    }
  } finally {
    work.cleanup();
  }
});
