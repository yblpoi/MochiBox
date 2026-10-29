/*
 * tap.mjs —— TAP 13 输出与断言库（协议层 case 唯一依赖的断言入口）。
 *
 * 约定：
 *   · 通过：`ok N - [group] name`
 *   · 失败：`not ok N - [group] name # <短原因>`，其后可跟 `#   <详情>` 行
 *   · 结束：`1..N` + `# pass X fail Y`
 *
 * 名字允许 UTF-8 中文；换行与制表符会被压成空格（TAP 的 test 行必须单行）。
 * 断言里**不要**写"不崩就算过"：ok() 的第一个参数必须是可判定的谓词。
 */

/** TAP 的 test 行必须单行；把控制字符压掉，保留中文与常见符号。 */
function oneLine(text) {
  return String(text == null ? '' : text)
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, ' ')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim();
}

function short(text, max = 160) {
  const value = oneLine(text);
  return value.length > max ? value.slice(0, max) + '…' : value;
}

function stringify(value) {
  if (typeof value === 'string') { return JSON.stringify(value); }
  try {
    const text = JSON.stringify(value);
    return text === undefined ? String(value) : text;
  } catch (e) {
    return String(value);
  }
}

export class Tap {
  /**
   * @param {string} group 用例组名（出现在每一行的 `[group]` 里，用短横线英文，便于 grep）
   */
  constructor(group) {
    this.group = group;
    this.total = 0;
    this.pass = 0;
    this.fail = 0;
    this.finished = false;
  }

  /** 底层出口：所有断言最终都走这里，保证编号与计数只有一份实现。 */
  _report(ok, name, detail, reason) {
    const index = ++this.total;
    const label = oneLine(`[${this.group}] ${name}`);
    if (ok) {
      this.pass += 1;
      console.log(`ok ${index} - ${label}`);
    } else {
      this.fail += 1;
      const tail = reason ? ` # ${short(reason)}` : '';
      console.log(`not ok ${index} - ${label}${tail}`);
    }
    if (detail !== undefined && detail !== null && detail !== '') {
      const text = typeof detail === 'string' ? detail : stringify(detail);
      for (const line of String(text).split('\n')) {
        if (line.trim() !== '') { console.log(`#   ${line}`); }
      }
    }
    return ok;
  }

  /** 布尔断言。detail 建议写"期望 vs 实际"，失败时是唯一的现场证据。 */
  ok(condition, name, detail) {
    return this._report(!!condition, name, condition ? null : detail,
      condition ? null : '条件不成立');
  }

  /** 相等断言（深比较走 JSON 形态，够用于本层的标量/对象/数组）。 */
  eq(actual, expected, name) {
    const a = stringify(actual);
    const e = stringify(expected);
    if (a === e) { return this._report(true, name, null, null); }
    return this._report(false, name, `期望: ${e}\n实际: ${a}`, `期望 ${short(e, 80)}，实际 ${short(a, 80)}`);
  }

  ne(actual, forbidden, name) {
    const a = stringify(actual);
    const f = stringify(forbidden);
    if (a !== f) { return this._report(true, name, null, null); }
    return this._report(false, name, `不得等于: ${f}`, '出现了被禁止的值');
  }

  /** 断言表达式抛错，且错误码等于期望值。 */
  throwsCode(fn, expectedCode, name) {
    try {
      fn();
    } catch (error) {
      const code = error && error.code ? String(error.code) : '';
      if (code === expectedCode) { return this._report(true, name, null, null); }
      return this._report(false, name, `期望错误码: ${expectedCode}\n实际: ${code || short(error)}`,
        `错误码 ${code || '(空)'} != ${expectedCode}`);
    }
    return this._report(false, name, `期望抛出 ${expectedCode}，实际没有抛错`, '未抛错');
  }

  /** 用例自身异常（读不到文件、编译失败）：记一条失败，并由调用方决定退出码。 */
  fatal(name, error) {
    const message = error && error.message ? error.message : String(error);
    const stack = error && error.stack ? String(error.stack).split('\n').slice(1, 4).join('\n') : '';
    return this._report(false, name, stack ? `${message}\n${stack}` : message, `FATAL: ${short(message, 100)}`);
  }

  /**
   * 把子进程（Swift 探针）打印的 TAP 结果并入当前用例。
   *
   * 存在的理由：Swift 探针自带编号与 plan，直接透传会让一个 case 出现两个 plan。
   * 这里只吸收 `ok/not ok` 与随后的 `#   ` 诊断行，编号由当前 Tap 重新分配。
   */
  absorbTap(text) {
    let failing = null;
    let details = [];
    const flush = () => {
      if (failing !== null) {
        this._report(false, failing, details.length ? details.join('\n') : null, '断言不成立');
      }
      failing = null;
      details = [];
    };
    for (const rawLine of String(text).split('\n')) {
      const line = rawLine.trimEnd();
      const matched = /^(not ok|ok)\s+\d+\s+-\s+(.*)$/.exec(line);
      if (matched) {
        flush();
        const label = matched[2].replace(/\s+#\s+.*$/, '');
        if (matched[1] === 'ok') { this._report(true, label, null, null); }
        else { failing = label; }
        continue;
      }
      if (failing !== null && line.startsWith('#   ')) { details.push(line.slice(4)); continue; }
      if (failing !== null && line.startsWith('# ')) { details.push(line.slice(2)); continue; }
    }
    flush();
  }

  /** 诊断信息，不计入断言数。 */
  note(message) {
    for (const line of String(message).split('\n')) {
      if (line.trim() !== '') { console.log(`# ${line}`); }
    }
  }

  /** 打印计划与汇总，返回进程退出码（0 = 全绿，1 = 有失败）。 */
  summary() {
    if (this.finished) { return this.fail === 0 ? 0 : 1; }
    this.finished = true;
    console.log(`1..${this.total}`);
    console.log(`# pass ${this.pass} fail ${this.fail}`);
    return this.fail === 0 ? 0 : 1;
  }
}

/**
 * case 文件的统一骨架：`Tap` + 异常兜底。
 * 用法：
 *   runCase('agent-api', (tap) => { tap.ok(true, '...'); });
 */
export function runCase(group, body) {
  const tap = new Tap(group);
  console.log('TAP version 13');
  try {
    const result = body(tap);
    if (result && typeof result.then === 'function') {
      return result.then(
        () => process.exit(tap.summary()),
        (error) => { tap.fatal('case 执行异常', error); process.exit(tap.summary() || 2); }
      );
    }
  } catch (error) {
    tap.fatal('case 执行异常', error);
    process.exit(tap.summary() || 2);
  }
  process.exit(tap.summary());
}
