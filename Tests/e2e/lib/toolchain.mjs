/*
 * toolchain.mjs —— 编译器 / SDK / git 的路径自动探测。
 *
 * 为什么需要：Xcode 装了但许可证未接受时，/usr/bin 下由 Xcode 放置的那层 shim
 * （swiftc / clang / clang++ / git / xcrun / strip …）全部拒绝执行：退出码 69，
 * 输出 "You have not agreed to the Xcode license agreements. …"。
 * 工具链**真身**不受影响：
 *   <dev>/Toolchains/XcodeDefault.xctoolchain/usr/bin/<tool>   Xcode 安装
 *   <dev>/usr/bin/<tool>                                       Command Line Tools
 * 但真身脱离 xcrun 后拿不到 SDK 注入，必须自己补：
 *   swiftc  → -sdk <sdk> -target <triple>   否则 "unable to load standard library"
 *   clang++ → -isysroot <sdk>               否则 "ld: library 'c++' not found"
 *
 * 探测顺序（正常机器行为不变，这是硬约束）：
 *   1. `xcrun --find <tool>` 成功 → 用它返回的路径，**额外参数为空**。
 *      正常机器上这与改造前写死 /usr/bin/<tool> 等价（那个 shim 背后就是它），
 *      编译命令行一字不差。
 *   2. xcrun 被许可证拦住 → 从 `xcode-select -p` 推导真身，并补 -sdk/-target/-isysroot。
 *   3. 都不可用 → 抛错，消息直接指向"Xcode 许可证"，绝不静默跳过。
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const TIMEOUT_MS = 20000;

/** 跑一条探测命令；失败时把 xcrun 的原话留下来，供错误信息归因。 */
function capture(command, args) {
  try {
    const stdout = execFileSync(command, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: TIMEOUT_MS,
      maxBuffer: 1024 * 1024
    });
    return { ok: true, stdout: String(stdout).trim(), detail: '' };
  } catch (error) {
    const detail = [error && error.stdout, error && error.stderr]
      .filter(Boolean).join('\n').trim();
    return { ok: false, stdout: '', detail: detail || String((error && error.message) || error) };
  }
}

function isExecutable(file) {
  if (!file) { return false; }
  try {
    if (!fs.statSync(file).isFile()) { return false; }
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch (error) {
    return false;
  }
}

/** `xcode-select -p`：Xcode 是 <X>.app/Contents/Developer，CLT 是 /Library/Developer/CommandLineTools。 */
export function developerDir() {
  const result = capture('xcode-select', ['-p']);
  return result.ok && result.stdout ? result.stdout : null;
}

/** 真身候选路径：先 Xcode 的 toolchain 目录，再 <dev>/usr/bin（CLT 布局）。 */
function realCandidates(name, dev) {
  if (!dev) { return []; }
  return [
    path.join(dev, 'Toolchains/XcodeDefault.xctoolchain/usr/bin', name),
    path.join(dev, 'usr/bin', name)
  ];
}

/*
 * 谁能提供 SDK：
 *   /usr/bin/<name> 是 Apple 放的小 shim，它会经 xcrun 注入 SDKROOT —— 所以走它
 *   时**不需要**任何额外参数（改造前跑的就是它）。
 *   工具链真身没有这层注入，缺 -sdk / -isysroot 时 swiftc 报
 *   "unable to load standard library"、clang++ 报 "ld: library 'c++' not found"。
 * 因此 needsSDK 只由"用的是不是那层 shim"决定，与"xcrun 是否可用"不是一回事。
 */
function resolveTool(name, dev) {
  const xcrun = capture('xcrun', ['--find', name]);
  const shim = path.join('/usr/bin', name);
  if (xcrun.ok) {
    // 正常机器：xcrun 能用，优先走 /usr/bin 那层 shim，命令行与改造前逐字一致。
    if (isExecutable(shim)) {
      return { path: shim, viaXcrun: true, needsSDK: false, xcrunDetail: '' };
    }
    if (xcrun.stdout && isExecutable(xcrun.stdout)) {
      // 有 xcrun 但没有那层 shim（少见的装机形态）：用 xcrun 给的路径，自己补 SDK。
      return { path: xcrun.stdout, viaXcrun: true, needsSDK: true, xcrunDetail: '' };
    }
  }
  for (const candidate of realCandidates(name, dev)) {
    if (isExecutable(candidate)) {
      return { path: candidate, viaXcrun: false, needsSDK: true, xcrunDetail: xcrun.detail };
    }
  }
  return { path: null, viaXcrun: false, needsSDK: true, xcrunDetail: xcrun.detail };
}

/**
 * SDK 根目录：先问 xcrun，再按 xcode-select 的落点分两种布局找。
 * 找不到返回 null —— 调用方据此拒绝走真身（没有 SDK 的 swiftc 必然编不过）。
 */
export function resolveSDK(dev) {
  const xcrun = capture('xcrun', ['--show-sdk-path']);
  if (xcrun.ok && xcrun.stdout && fs.existsSync(xcrun.stdout)) {
    return { path: xcrun.stdout, viaXcrun: true };
  }
  const candidates = [];
  if (dev) {
    candidates.push(path.join(dev, 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'));
    const cltSDKs = path.join(dev, 'SDKs');
    try {
      const names = fs.readdirSync(cltSDKs)
        .filter((name) => /^MacOSX.*\.sdk$/.test(name))
        .sort()
        .reverse();
      for (const name of names) { candidates.push(path.join(cltSDKs, name)); }
    } catch (error) {
      // 没有这个目录就是 Xcode 布局，正常。
    }
  }
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) { return { path: candidate, viaXcrun: false }; }
  }
  return { path: null, viaXcrun: false };
}

/** 探针的部署目标：与 Scripts/build.sh 的 DEFAULT_TARGET 一致。 */
export function hostTriple() {
  const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  return arch + '-apple-macosx13.0';
}

/**
 * 解析一个编译器。
 * 返回 { path, viaXcrun, sdk, extraFlags, reason, dev, xcrunDetail }。
 * reason 非空 = 找到了路径但环境不完整（例如真身在、SDK 找不到）。
 */
export function resolveCompiler(name) {
  const dev = developerDir();
  const tool = resolveTool(name, dev);
  const sdk = resolveSDK(dev);
  const extraFlags = [];
  let reason = '';

  if (tool.path && tool.needsSDK) {
    if (!sdk.path) {
      reason = '找不到 macOS SDK：xcrun --show-sdk-path 失败，' +
        (dev
          ? dev + ' 下也没有 Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk 或 SDKs/MacOSX*.sdk'
          : 'xcode-select -p 也没有输出');
    } else if (name.startsWith('swift')) {
      extraFlags.push('-sdk', sdk.path, '-target', hostTriple());
    } else {
      extraFlags.push('-isysroot', sdk.path);
    }
  }

  return {
    path: tool.path,
    viaXcrun: tool.viaXcrun,
    needsSDK: tool.needsSDK,
    sdk: sdk.path,
    extraFlags,
    reason,
    dev,
    xcrunDetail: tool.xcrunDetail
  };
}

/**
 * 拿不到编译器时的错误。第一行固定指向"Xcode 许可证"——
 * 这是本机（以及任何装了 Xcode 但没 accept 的机器）最常见的成因，
 * 让人一眼知道是环境问题而不是代码回归。
 */
export function compilerUnavailable(label, binary, resolution) {
  const lines = [
    '没有可用的 ' + label + '：/usr/bin/' + binary + ' 被 Xcode 许可证拦住，工具链真身也不存在'
  ];
  lines.push('xcode-select -p = ' + (resolution.dev || '(无输出)'));
  if (resolution.xcrunDetail) {
    lines.push('xcrun 原话：' + resolution.xcrunDetail.split('\n')[0]);
  }
  if (resolution.reason) { lines.push(resolution.reason); }
  lines.push('修复：sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch');
  return new Error(lines.join('\n'));
}

/**
 * python3：12_domain_qa 起本地 error_server 用，/usr/bin/python3 同样是 Xcode shim。
 * 判据与编译器不同，因为这里要的不是"编译"而是"能跑"：
 *   1. PATH 上的 python3 真的能跑（`--version` 退出 0）→ 原样返回 'python3'，
 *      正常机器上行为与改造前完全一致；
 *   2. 跑不动 → 看 xcrun / <dev>/usr/bin/python3；
 *   3. 都不行 → path 为 null，由调用方报一条明确的环境错误。
 */
export function resolvePython3() {
  const onPath = capture('python3', ['--version']);
  if (onPath.ok) { return { path: 'python3', viaXcrun: false, detail: '' }; }
  const resolved = resolveTool('python3', developerDir());
  if (resolved.path) {
    return { path: resolved.path, viaXcrun: resolved.viaXcrun, detail: resolved.xcrunDetail };
  }
  return { path: null, viaXcrun: false, detail: onPath.detail || resolved.xcrunDetail };
}

/** 拿到编译器路径，否则抛一条指明原因的错误。 */
export function requireCompiler(label, binary, resolution) {
  if (!resolution.path || resolution.reason) {
    throw compilerUnavailable(label, binary, resolution);
  }
  return resolution.path;
}
