/*
 * 18_lcf_extract.mjs —— 经典 RM 数据层（RPG Maker 2000/2003 的 RPG_RT.ldb）的 Swift 探针入口。
 *
 * 被测源码：Sources/Adapters/LCF/{LCFDatabase,LCFTextCodec,LCFError}.swift
 *           + Sources/Adapters/LCF/lcf_shim.cpp（C shim，链 liblcf 静态库）
 * 断言正文：lcf_probe.swift（25 条，L1–L25），本文件只负责：
 *   1) 确认 vendor 里的 liblcf 静态库在（不在就是这层没构建，直接报怎么补）；
 *   2) 用 clang++ 把 shim 编成 .o，再把 .o 与 liblcf.a 一起交给 swiftc；
 *   3) 把子进程的 TAP 原样转出；编译失败转成一条 FATAL 失败。
 *
 * 为什么不能只靠 --attach 的 JSONL：那里面只有翻译事件。字段路径是否还寻得到址、
 * 写回有没有顺手改坏没动的字段、保存后 2003 的专有结构还在不在 —— 只有这一层看得见。
 *
 * 数据来源：Fixtures/rm2000|rm2003 是 EasyRPG/TestGame 的原始数据（GPL-3.0），
 * 只被本用例读取，不进产物。见 Fixtures/README.md。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { compileProbe, runProbe, SOURCES, ROOT } from '../../lib/swift.mjs';
import { runCase } from '../../lib/tap.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROBE = path.join(HERE, 'lcf_probe.swift');
const LCF_DIR = path.join(ROOT, 'Sources/Adapters/LCF');
const SHIM_H = path.join(LCF_DIR, 'lcf_shim.h');
const SHIM_CPP = path.join(LCF_DIR, 'lcf_shim.cpp');
const PREFIX = path.join(ROOT, 'vendor/liblcf-build/install');
const LIBLCF = path.join(PREFIX, 'lib/liblcf.a');
const FIXTURES = [
  path.join(ROOT, 'Fixtures/rm2000/RPG_RT.ldb'),
  path.join(ROOT, 'Fixtures/rm2003/RPG_RT.ldb')
];

runCase('lcf-extract', (tap) => {
  // 缺件时分两种，口径与 Scripts/build.sh 的 Step 0.6 一致：
  //   · liblcf 产物不在 = 这台机器没 opt-in 这个**可选构建** → SKIP，不把 contract 判红
  //     （Swift 侧此时是 MOCHI_NO_LCF，LCFDatabase 整段没编进来，本来也没东西可测）；
  //   · 产物在、样本却缺 = 真错误（样本是入库数据，缺了说明仓库不完整）→ FATAL。
  // 两者不能混：把"没装可选依赖"报成失败，会让每个新 clone 的机器一上手就红。
  const built = fs.existsSync(LIBLCF)
    && fs.existsSync(path.join(PREFIX, 'include/lcf/config.h'))
    && fs.existsSync(SHIM_CPP) && fs.existsSync(SHIM_H);
  if (!built) {
    tap.ok(true, '经典 RM 数据层 # SKIP 未构建 liblcf（先跑 bash Scripts/build-liblcf.sh）');
    return;
  }
  const missing = FIXTURES.filter((f) => !fs.existsSync(f)).map((f) => path.relative(ROOT, f));
  if (missing.length > 0) {
    tap.fatal('经典 RM 测试样本缺失：' + missing.join('、'),
      new Error('样本是入库数据（Fixtures/rm2000|rm2003，GPL-3.0），缺了说明仓库不完整'));
    return;
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mochibox-lcf-shim-'));
  let compiled = null;
  try {
    const obj = path.join(tmp, 'lcf_shim.o');
    execFileSync('/usr/bin/clang++', [
      '-std=c++17', '-O2', '-arch', 'arm64', '-mmacosx-version-min=13.0',
      // 只导出 lcf_shim.h 里标了 visibility("default") 的 C 函数，
      // 把 liblcf 的上千个 C++ 符号关在这支探针内部（与 Scripts/build.sh 同口径）。
      '-fvisibility=hidden',
      '-c', SHIM_CPP,
      '-I', LCF_DIR, '-I', path.join(PREFIX, 'include'),
      '-o', obj
    ], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 300000 });

    compiled = compileProbe({
      name: 'lcf_probe',
      probeFile: PROBE,
      sources: SOURCES.lcf(),
      extraArgs: ['-import-objc-header', SHIM_H, obj, LIBLCF, '-lc++']
    });
  } catch (error) {
    tap.fatal('lcf_probe 编译失败', error);
    fs.rmSync(tmp, { recursive: true, force: true });
    return;
  }

  try {
    const result = runProbe(compiled.bin, FIXTURES);
    tap.absorbTap(result.stdout);
    if (result.stderr.trim() !== '') {
      // L25 故意喂了一个非 LCF 文件，liblcf 会往 stderr 打一行 "This is not a valid
      // RPG2000 database." —— 那是**预期**的诊断输出，不是失败信号。其余行照常转出。
      const expected = /not a valid RPG2000 database/;
      const lines = result.stderr.trimEnd().split('\n').filter((line) => !expected.test(line));
      for (const line of lines.slice(0, 10)) { tap.note('[lcf] stderr: ' + line); }
    }
    if (result.status !== 0) {
      if (!/^not ok /m.test(result.stdout)) {
        tap.fatal('lcf_probe 进程异常退出（exit=' + result.status + '）', new Error(result.stderr || '无输出'));
      }
    } else if (!/^1\.\.\d+$/m.test(result.stdout)) {
      tap.fatal('lcf_probe 没有打印 TAP 计划行（输出被截断？）', new Error(result.stdout.slice(0, 500)));
    }
  } finally {
    compiled.cleanup();
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
