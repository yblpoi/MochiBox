/*
 * 15_agent_diag.mjs —— Agent 诊断信封分级/节流的 Swift 探针入口（agent_diag_probe.swift）。
 *
 * 被测源码：Sources/Infra/Stores.swift 里的 `AgentDiagGate`（+ qa 档其余文件）。
 *
 * 为什么需要：`SessionController.handleEnvelope` 是 private，唯一触达方式是真实 adapter
 * attach；`--play` 那条链路由 AttachCLI 消费信封，它不处理 type=="error"（全部静默丢弃）。
 * 所以 94ef649 的分流在 E2E 五层里原本没有任何可观测面。把判定与节流抽成无依赖类型后，
 * 才能在这里把 5 条行为钉死：首条立即 / 中间静默 / 第 200 条补一行 / 非诊断不计数 / reset 归零。
 *
 * 本文件只负责编译与转出 TAP，断言正文在 Swift 里。
 */
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileProbe, runProbe, SOURCES } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';

const PROBE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'agent_diag_probe.swift');

runCase('agent-diag', (tap) => {
  let compiled = null;
  try {
    compiled = compileProbe({ name: 'agent_diag_probe', probeFile: PROBE, sources: SOURCES.qa() });
  } catch (error) {
    tap.fatal('agent_diag_probe 编译失败', error);
    return;
  }
  try {
    const result = runProbe(compiled.bin);
    tap.absorbTap(result.stdout);
    if (result.stderr.trim() !== '') {
      for (const line of result.stderr.trimEnd().split('\n').slice(0, 10)) { tap.note('[agent-diag] stderr: ' + line); }
    }
    if (result.status !== 0 && !/^not ok /m.test(result.stdout)) {
      tap.fatal('agent_diag_probe 进程异常退出（exit=' + result.status + '）', new Error(result.stderr || '无输出'));
    } else if (!/^1\.\.\d+$/m.test(result.stdout)) {
      tap.fatal('agent_diag_probe 没有打印 TAP 计划行（输出被截断？）', new Error(result.stdout.slice(0, 500)));
    }
  } finally {
    if (compiled) { compiled.cleanup(); }
  }
});
