/*
 * 23_win32_shim.mjs —— macOS 上 Win32API 的 Ruby shim 合同测试。
 *
 * 背景：mkxp-z 在 macOS 把 dll 名当相对路径 dlopen，Win32API.new('kernel32', ...)
 * 直接 RuntimeError。Resources/rgss/mochi_win32_shim.rb 在 preload 阶段 reopen
 * Win32API.new，按 (dll, func) 分派到纯 Ruby 安全实现；未知 API 返回声明类型的
 * 安全默认并记一次日志，绝不 raise。
 *
 * 覆盖：
 *   WS-A 纯 MRI 契约（stub Win32API 后 load shim）
 *     WS-A1 Win32API.new 返回 shim 对象，call / Call 等价、任意参数个数
 *     WS-A2 imports/exports 为字符串/数组/整数/nil/怪形状都能构造且不 raise
 *     WS-A3 未知 API 按 exports 兜底（P→""，L/N/I→0，V/nil→nil），只记一次日志
 *     WS-A4 INI 真读写：A/W、大小写不敏感、缺失默认、缓冲区写入/截断、GBK/UTF-16
 *     WS-A5 kernel32/user32/winmm/version/gdi32/advapi32 的安全降级返回值
 *   WS-B 开关与宿主缺失
 *     WS-B1 MOCHI_WIN32_SHIM=off 保留原 new（仍抛错）
 *     WS-B2 宿主没有 Win32API 时 install! 返回 false，之后可重试
 *   WS-C 与 hook 接线
 *     WS-C1 preload 链上 shim 生效，hook 照常安装
 *     WS-C2 MOCHI_RGSS_HOOK=off 时 hook 提前返回，但 shim 仍安装
 *     WS-C3 shim 文件缺失时 hook 不抛异常、照常安装并记录失败
 *
 * 每个场景独立 ruby 进程；探针自带 TAP 输出，本文件只负责起进程与转发。
 * 运行：node Tests/e2e/lib/run.mjs --suite contract
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ROOT } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';

const PROBE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'win32_shim_probe.rb');
const HOOK = path.join(ROOT, 'Resources/rgss/mochi_rgss_hook.rb');
const SHIM = path.join(ROOT, 'Resources/rgss/mochi_win32_shim.rb');

const SCENARIOS = [
  { name: 'contract', env: {} },
  { name: 'disabled', env: { MOCHI_WIN32_SHIM: 'off' } },
  { name: 'no-host', env: {} },
  { name: 'hook-on', env: {} },
  { name: 'hook-off-shim-on', env: { MOCHI_RGSS_HOOK: 'off' } },
  { name: 'hook-missing-shim', env: {} }
];

runCase('win32-shim', (tap) => {
  tap.ok(fs.existsSync(SHIM), 'shim 脚本存在', SHIM);
  tap.ok(fs.existsSync(HOOK), 'hook 脚本存在', HOOK);
  tap.ok(fs.existsSync(PROBE), 'Ruby 探针存在', PROBE);

  for (const { name, env: overrides } of SCENARIOS) {
    const env = { ...process.env };
    delete env.MOCHI_WIN32_SHIM;
    delete env.MOCHI_RGSS_HOOK;
    delete env.MOCHI_RGSS_SURFACES;
    Object.assign(env, overrides);

    const result = spawnSync('ruby', [PROBE, HOOK, SHIM, name], {
      cwd: ROOT,
      encoding: 'utf8',
      timeout: 120_000,
      maxBuffer: 8 * 1024 * 1024,
      env
    });

    if (result.error) {
      tap.fatal('场景 ' + name + ' 无法启动 ruby', result.error);
      continue;
    }
    if (result.stderr.trim()) {
      tap.note('场景 ' + name + ' stderr:\n' + result.stderr.trim().split('\n').slice(0, 8).join('\n'));
    }
    tap.absorbTap(result.stdout);
    tap.eq(result.status, 0, '场景 ' + name + ' 的 Ruby 探针退出码为 0');
  }
});
