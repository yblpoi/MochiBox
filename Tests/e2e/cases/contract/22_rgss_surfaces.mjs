/*
 * 22_rgss_surfaces.mjs —— RGSS hook 的多面文本提取 / 分派 / 面开关回归。
 *
 * 与 20_rgss_bridge 的分工：
 *   20 测的是 Swift 侧的 RGSSBridge 协议、控制符、超时、缓存；
 *   本用例测的是 Resources/rgss/mochi_rgss_hook.rb 自己——
 *   假 Window_* 类在 MRI 里按真实默认脚本顺序定义，走 TracePoint(:end) 安装，
 *   经 loopback mock 服务返回「译:」前缀，验证：
 *
 *   RS-A XP/VX/VX Ace 的入口
 *     RS-A1 消息、菜单、帮助、战斗日志的原文逐项正确
 *     RS-A2 译文在调用原方法之前写回（原方法看到的是译文）
 *     RS-A3 三个版本的协议标签分别是 RGSS1/RGSS2/RGSS3
 *     RS-A4 XP/VX 的选项、XP 的战斗日志如实记录为并入 message
 *
 *   RS-B 分派隔离
 *     RS-B1 VX Ace 的 Window_ChoiceList 只走 choice 面，不被 menu 面吃掉
 *     RS-B2 每个面完成后 TracePoint 关闭
 *
 *   RS-C 面开关与降级
 *     RS-C1 MOCHI_RGSS_SURFACES=menu 时消息/帮助保持原文
 *     RS-C2 单个面 hook 失败（冻结的 Window_Command）不影响消息/帮助
 *     RS-C3 MOCHI_RGSS_HOOK=off 时零请求、全部原文
 *     RS-C4 始终不 hook Window_Base#draw_text
 *
 * 运行：node Tests/e2e/lib/run.mjs --suite contract
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ROOT } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';

const PROBE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'rgss_surfaces_probe.rb');
const HOOK = path.join(ROOT, 'Resources/rgss/mochi_rgss_hook.rb');
const SCENARIOS = ['xp', 'vx', 'vxace', 'gate-menu', 'failure-isolation', 'off'];

runCase('rgss-surfaces', (tap) => {
  tap.ok(fs.existsSync(HOOK), 'hook 脚本存在', HOOK);
  tap.ok(fs.existsSync(PROBE), 'Ruby 探针存在', PROBE);

  for (const scenario of SCENARIOS) {
    const result = spawnSync('ruby', [PROBE, HOOK, scenario], {
      cwd: ROOT,
      encoding: 'utf8',
      timeout: 60_000,
      maxBuffer: 8 * 1024 * 1024
    });

    if (result.error) {
      tap.fatal('场景 ' + scenario + ' 无法启动 ruby', result.error);
      continue;
    }
    if (result.stderr.trim()) {
      tap.note('场景 ' + scenario + ' stderr:\n' + result.stderr.trim().split('\n').slice(0, 8).join('\n'));
    }
    tap.absorbTap(result.stdout);
    tap.eq(result.status, 0, '场景 ' + scenario + ' 的 Ruby 探针退出码为 0');
  }
});
