/*
 * 18_lcf_extract.mjs —— 经典 RM 数据层（RPG Maker 2000/2003 的 RPG_RT.ldb）的 Swift 探针入口。
 *
 * 被测源码：Sources/Adapters/LCF/{LCFDatabase,LCFTextCodec,LCFError}.swift
 *           + Sources/Adapters/LCF/lcf_shim.cpp（C shim，链 liblcf 静态库）
 * 断言正文：lcf_probe.swift（28 条，L1–L25 + L26–L29），本文件负责：
 *   1) 确认 vendor 里的 liblcf 静态库在（不在就是这层没构建，直接报怎么补）；
 *   2) 用 clang++ 把 shim 编成 .o，再把 .o 与 liblcf.a 一起交给 swiftc；
 *   3) 现场造两个合成库（lcf_synth.cpp），用完就删 —— 它们是测试构造物，不入库；
 *   4) 把子进程的 TAP 原样转出；编译失败转成一条 FATAL 失败。
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
const SYNTH = path.join(HERE, 'lcf_synth.cpp');
const LCF_DIR = path.join(ROOT, 'Sources/Adapters/LCF');
const SHIM_H = path.join(LCF_DIR, 'lcf_shim.h');
const SHIM_CPP = path.join(LCF_DIR, 'lcf_shim.cpp');
const PREFIX = path.join(ROOT, 'vendor/liblcf-build/install');
const LIBLCF = path.join(PREFIX, 'lib/liblcf.a');
const INCLUDE = path.join(PREFIX, 'include');
const FIXTURES = [
  path.join(ROOT, 'Fixtures/rm2000/RPG_RT.ldb'),
  path.join(ROOT, 'Fixtures/rm2003/RPG_RT.ldb')
];

const CLANG = '/usr/bin/clang++';

runCase('lcf-extract', (tap) => {
  // 缺件时的口径：这一层是**可选构建**（见 Scripts/build.sh 的 Step 0.6），
  // 但一旦用例跑到这里，缺件就意味着"本层没被验证过"。静默跳过等于假绿，
  // 所以记一条 FATAL 并把补救命令写清楚。
  const missing = [];
  if (!fs.existsSync(LIBLCF)) { missing.push('vendor/liblcf-build/install/lib/liblcf.a'); }
  if (!fs.existsSync(path.join(INCLUDE, 'lcf/config.h'))) { missing.push('vendor/liblcf-build/install/include/lcf/config.h'); }
  for (const f of FIXTURES) { if (!fs.existsSync(f)) { missing.push(path.relative(ROOT, f)); } }
  if (missing.length > 0) {
    tap.fatal('经典 RM 数据层的依赖不齐：' + missing.join('、'),
      new Error('先跑 bash Scripts/build-liblcf.sh（约 30s）生成 vendor 产物'));
    return;
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mochibox-lcf-'));
  let compiled = null;
  try {
    const obj = path.join(tmp, 'lcf_shim.o');
    execFileSync(CLANG, [
      '-std=c++17', '-O2', '-arch', 'arm64', '-mmacosx-version-min=13.0',
      // 只导出 lcf_shim.h 里标了 visibility("default") 的 C 函数，
      // 把 liblcf 的上千个 C++ 符号关在这支探针内部（与 Scripts/build.sh 同口径）。
      '-fvisibility=hidden',
      '-c', SHIM_CPP,
      '-I', LCF_DIR, '-I', INCLUDE,
      '-o', obj
    ], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 300000 });

    // 两个合成库：造完就用，用完随 tmp 一起删（不入库，见 lcf_synth.cpp 头注释）。
    const synthBin = path.join(tmp, 'lcf_synth');
    execFileSync(CLANG, [
      '-std=c++17', '-O2', '-arch', 'arm64', '-mmacosx-version-min=13.0',
      SYNTH, LIBLCF, '-I', INCLUDE, '-o', synthBin
    ], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 300000 });

    const synthEmpty2k3 = path.join(tmp, 'synth_empty_2k3.ldb');
    const synth2kWithClasses = path.join(tmp, 'synth_2k_with_classes.ldb');
    execFileSync(synthBin, ['empty-2k3', FIXTURES[1], synthEmpty2k3], { cwd: ROOT, encoding: 'utf8', timeout: 120000 });
    execFileSync(synthBin, ['inject-2k', FIXTURES[0], synth2kWithClasses], { cwd: ROOT, encoding: 'utf8', timeout: 120000 });

    compiled = compileProbe({
      name: 'lcf_probe',
      probeFile: PROBE,
      sources: SOURCES.lcf(),
      extraArgs: ['-import-objc-header', SHIM_H, obj, LIBLCF, '-lc++']
    });

    const result = runProbe(compiled.bin, [...FIXTURES, synthEmpty2k3, synth2kWithClasses]);
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
  } catch (error) {
    tap.fatal('lcf_probe 编译或造库失败', error);
  } finally {
    if (compiled) { compiled.cleanup(); }
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
