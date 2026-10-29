/*
 * 04_safe_path.mjs —— `assertSafePath` / `resolvePath` 的安全边界（cheat.objectPath / setObjectPath）。
 *
 * 依据：`Resources/agent_mvmz.js` 的 assertSafePath（深度 2..8、根必须是 $game* 或 $data*、
 * 禁 __proto__/constructor/prototype）与 cheatSetObjectPath（只允许写 string/number/boolean）。
 *
 * 这里的断言全部只依赖 rpcResult 的 `ok`/`error.code`，不看错误文案 —— 文案会改，码是契约。
 * 另外每条"被拒绝"的写入都补一条副作用断言：拒绝必须真的没写进去，也不能污染原型。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

runCase('safe-path', (tap) => {
  const h = createHarness({ fixture: true });
  h.drainAll();

  const readPath = (path) => h.rpc('cheat.objectPath', { path }).ack;
  const codeOf = (ack) => (ack && ack.ok === false && ack.error ? ack.error.code : (ack && ack.ok ? 'ok' : 'no-ack'));

  // ---- 深度边界 ----
  tap.eq(codeOf(readPath('$gameParty._gold')), 'ok', 'P-01 深度 2 的合法路径放行（$gameParty._gold）');

  const depth8 = readPath('$gameParty._a._b._c._d._e._f._g');
  tap.eq(codeOf(depth8), 'cheat_out_of_range',
    'P-02 深度 8 通过校验（失败在解析而非深度）：期望 cheat_out_of_range',
    JSON.stringify(depth8));

  const depth9 = readPath('$gameParty._a._b._c._d._e._f._g._h');
  tap.eq(codeOf(depth9), 'cheat_bad_args', 'P-03 深度 9 被校验拒绝：cheat_bad_args', JSON.stringify(depth9));

  const depth1 = readPath('$gameParty');
  tap.eq(codeOf(depth1), 'cheat_bad_args', 'P-04 深度 1 被拒绝：cheat_bad_args', JSON.stringify(depth1));

  // ---- 根白名单 ----
  tap.eq(codeOf(readPath('location.href')), 'cheat_forbidden', 'P-05 非 $game*/$data* 根：cheat_forbidden');
  tap.eq(codeOf(readPath('.href')), 'cheat_forbidden', 'P-06 空根（.href）也算非白名单根：cheat_forbidden');
  tap.eq(codeOf(readPath('$dataItems.1.name')), 'ok', 'P-07 $data* 根放行（$dataItems.1.name）');
  const temp = readPath('$gameTemp._error');
  tap.ok(codeOf(temp) === 'ok' && temp.data.value === null && temp.data.type === 'object',
    'P-08 显式列出的 $gameTemp 根放行，值为 null 也能返回', JSON.stringify(temp));

  // ---- 禁用路径段 ----
  const proto = readPath('$gameVariables.__proto__.polluted');
  tap.eq(codeOf(proto), 'cheat_forbidden', 'P-09 __proto__ 段：cheat_forbidden', JSON.stringify(proto));
  tap.eq(codeOf(readPath('$gameParty.constructor.name')), 'cheat_forbidden', 'P-10 constructor 段：cheat_forbidden');
  tap.eq(codeOf(readPath('$gameParty.prototype.x')), 'cheat_forbidden', 'P-11 prototype 段：cheat_forbidden');
  tap.eq(codeOf(readPath('$gameVariables._data.__proto__')), 'cheat_forbidden',
    'P-12 禁用段在末位同样被拒绝（不是只查第一段）');

  // ---- 入参类型 ----
  tap.eq(codeOf(readPath('')), 'cheat_bad_args', 'P-13 空串 path：cheat_bad_args');
  tap.eq(codeOf(readPath(42)), 'cheat_bad_args', 'P-14 非字符串 path：cheat_bad_args');
  tap.eq(codeOf(readPath('$gameParty.')), 'cheat_out_of_range',
    'P-15 尾随点产生的空段不是"禁止段"，按路径不存在处理：cheat_out_of_range');

  // ---- setObjectPath 的写入类型 ----
  const write = (value) => h.rpc('cheat.setObjectPath', { path: '$gameVariables._probe', value }).ack;
  tap.eq(codeOf(write('文本')), 'ok', 'P-16 写入 string 放行');
  tap.eq(codeOf(write(3.5)), 'ok', 'P-17 写入 number 放行');
  tap.eq(codeOf(write(true)), 'ok', 'P-18 写入 boolean 放行');
  tap.eq(codeOf(write({ a: 1 })), 'cheat_bad_args', 'P-19 写入 object 被拒绝：cheat_bad_args');
  tap.eq(codeOf(write([1, 2])), 'cheat_bad_args', 'P-20 写入 array 被拒绝：cheat_bad_args');
  tap.eq(codeOf(write(null)), 'cheat_bad_args', 'P-21 写入 null 被拒绝：cheat_bad_args');

  // ---- setObjectPath 的路径边界 ----
  const missingParent = h.rpc('cheat.setObjectPath', { path: '$gameParty._ghost.deep', value: 1 }).ack;
  tap.eq(codeOf(missingParent), 'cheat_out_of_range', 'P-22 父路径不存在：cheat_out_of_range',
    JSON.stringify(missingParent));
  tap.eq(h.run('typeof window.$gameParty._ghost'), 'undefined',
    'P-23 被拒绝的写入不得凭空创建中间对象（$gameParty._ghost 仍不存在）');
  tap.eq(codeOf(h.rpc('cheat.setObjectPath', {
    path: '$gameParty._a._b._c._d._e._f._g._h', value: 1
  }).ack), 'cheat_bad_args', 'P-24 setObjectPath 同样受深度 8 上限约束');

  // ---- 原型不被污染 ----
  h.rpc('cheat.setObjectPath', { path: '$gameVariables.__proto__.polluted', value: 1 });
  tap.eq(h.run('({}).polluted === undefined && window.$gameVariables.polluted === undefined'), true,
    'P-25 拒绝 __proto__ 写入后，Object.prototype 与引擎对象都未被污染');

  // ---- 只读：函数值与深层值 ----
  const fn = readPath('$gameParty.gainGold');
  tap.ok(codeOf(fn) === 'ok' && fn.data.type === 'function' && fn.data.value === null,
    'P-26 读到函数时 type=function、value=null（safeValue 不触发 getter/toJSON）', JSON.stringify(fn));
  const deep = readPath('$gameParty._items.1');
  tap.ok(codeOf(deep) === 'ok' && deep.data.value === 3, 'P-27 深度 3 的对象键读得到（$gameParty._items.1 = 3）',
    JSON.stringify(deep));
});
