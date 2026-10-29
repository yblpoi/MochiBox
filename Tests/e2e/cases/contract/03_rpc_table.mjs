/*
 * 03_rpc_table.mjs —— RPC 分发表全表（45 个方法 × 3 个维度）。
 *
 * 依据：`Resources/agent_mvmz.js` 的 `var RPC = { ... }`（分发表）与 `handleRpc`（信封出口）。
 *
 * 每个方法断言三件事：
 *   H（happy）  ：正常入参 → `ok:true`，且 data 的形状/值落在契约内；
 *   I（invalid）：缺参 / 类型错误 → **要么**给出明确的 `rpc_error` 码（cheat_bad_args /
 *                 cheat_out_of_range），**要么**按实现定义的夹取规则返回 ok —— 两者都是契约，
 *                 这里把具体结果钉死，避免"以后悄悄改成另一种"；
 *   N（no-game）：`$game*` 不在时，依赖游戏状态的 handler 必须返回 `cheat_unavailable`；
 *                 不依赖游戏状态的 8 个方法（snapshot / listMapEvents / transferPoints /
 *                 devTools / objectPath / setObjectPath / scanStart / scanCancel）断言其
 *                 已定义的降级结果 —— 对它们要求 cheat_unavailable 反而是错的。
 *
 * 每个维度都在**全新沙箱**里跑：表里 45 行互不影响，也不依赖行序（工具方法会改场景/金币，
 * 共用沙箱会让 closeAllWindows、scenePop 之类的结果取决于前面跑过什么）。
 *
 * 表驱动：新增方法只加一行 ROWS，不复制断言代码。
 *
 * 防"自说自话"：T-000c 直接读 `Resources/agent_mvmz.js` 的 `var RPC` 块，把源码里的
 * 方法名与本表逐项比集合。否则"给产品加第 46 个方法"时本文件仍全绿 —— ROWS 只证明了
 * 自己和自己一致，证明不了产品。
 *
 * id 类入参的口径（T-014-I / T-015-I / T-016-I）：`id` 缺失可走实现定义的缺省，
 * 但 `id` **存在**却不是数字 / 越界必须走 `requireId()` → `cheat_bad_args` /
 * `cheat_out_of_range`，不得静默夹到默认对象上（夹取会改错对象且无处可查）。
 */
import fs from 'node:fs';

import { AGENT_PATH, createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

/** 调用 requireGame() 的方法：无 $game* 时必须 cheat_unavailable。 */
const REQUIRES_GAME = new Set([
  'cheat.listVariables', 'cheat.listSwitches', 'cheat.listItems', 'cheat.listActors',
  'cheat.setGold', 'cheat.setVariable', 'cheat.setSwitch', 'cheat.setSelfSwitch',
  'cheat.toggleAllSwitches', 'cheat.toggleAllSelfSwitches', 'cheat.giveItem', 'cheat.setItemCount',
  'cheat.updateActor', 'cheat.recoverAll', 'cheat.addPartyMember', 'cheat.removePartyMember',
  'cheat.godMode', 'cheat.noclip', 'cheat.encounter', 'cheat.alwaysDash', 'cheat.followers',
  'cheat.unlockEquip', 'cheat.unlockChoice', 'cheat.speed', 'cheat.moveSpeed', 'cheat.teleport',
  'cheat.scene', 'cheat.scenePop', 'cheat.battle', 'cheat.clearPictures', 'cheat.clearEvent',
  'cheat.clearMoveRoute', 'cheat.closeAllWindows', 'cheat.fadeIn', 'cheat.recover', 'cheat.repair',
  'cheat.fixError'
]);

/** 断言工具：check 返回 true 或 [false, detail]。 */
function expect(condition, detail) {
  return condition ? true : [false, detail];
}

/**
 * 从产品源码里取 `var RPC = { ... };` 的顶层方法名。
 *
 * 边界：起点 `var RPC = {`，终点是紧随其后的第一个 `  };`（RPC 对象的收尾行）。
 * 只认"行首（允许缩进）+ 引号包裹的 key + 冒号"，避免把块内的值/表达式误当 key。
 */
function rpcMethodsInSource() {
  const source = fs.readFileSync(AGENT_PATH, 'utf8');
  const start = source.indexOf('var RPC = {');
  if (start < 0) { throw new Error(AGENT_PATH + ' 里找不到 `var RPC = {`'); }
  const end = source.indexOf('\n  };', start);
  if (end < 0) { throw new Error(AGENT_PATH + ' 的 var RPC 块没有闭合行 `  };`'); }
  const block = source.slice(start, end);
  const methods = [];
  for (const matched of block.matchAll(/^[ \t]*(['"])([A-Za-z0-9_.-]+)\1[ \t]*:/gm)) {
    methods.push(matched[2]);
  }
  if (methods.length === 0) { throw new Error('var RPC 块里没解析出任何方法名'); }
  return methods;
}

/**
 * "该 handler 的返回形状恰为 {ok:true}" —— 稳定字段断言。
 *
 * unlockChoice / clearPictures / fadeIn 没有别的返回值语义；只断言 data.ok===true
 * 时，将来多塞一个字段、或把 ok 改成任意 truthy 值都不会变红。这里把键集合钉死。
 */
function onlyOk(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return [false, 'data 不是对象：' + JSON.stringify(data)];
  }
  const keys = Object.keys(data);
  return (keys.length === 1 && keys[0] === 'ok' && data.ok === true)
    ? true
    : [false, '返回形状应为 {"ok":true}，实际 keys=' + JSON.stringify(keys) + ' ok=' + JSON.stringify(data.ok)];
}

const ROWS = [
  {
    method: 'cheat.snapshot', args: {},
    check: (data) => expect(data.scene === 'Scene_Map' && data.mapId === 3 && data.gold === 1200,
      'scene/mapId/gold=' + JSON.stringify([data.scene, data.mapId, data.gold])),
    invalid: { args: {}, check: (data) => expect(typeof data.gold === 'number', 'gold 缺失') }
  },
  {
    method: 'cheat.listVariables', args: { from: 1, count: 5 },
    check: (data) => expect(Array.isArray(data) && data.length === 5 && data[0].id === 1,
      'len=' + (Array.isArray(data) ? data.length : 'not-array')),
    invalid: { args: { from: 'x', count: 0 }, check: (data) => expect(Array.isArray(data) && data.length === 1, 'from 回退 1 / count 夹到 1') }
  },
  {
    method: 'cheat.listSwitches', args: { from: 1, count: 5 },
    check: (data) => expect(Array.isArray(data) && data.length === 5 && typeof data[0].value === 'boolean', 'len=' + (Array.isArray(data) ? data.length : 'not-array')),
    invalid: { args: { count: -5 }, check: (data) => expect(Array.isArray(data) && data.length === 1, 'count 夹到 1') }
  },
  {
    method: 'cheat.listItems', args: { kind: 'item', ownedOnly: true },
    check: (data) => expect(Array.isArray(data) && data.length === 3 && data.every((row) => row.count > 0), 'ownedOnly 后应只剩 3 条持有物品'),
    invalid: { args: { kind: 'bogus' }, check: (data) => expect(Array.isArray(data) && data.length >= 6, '未知 kind 退回 item 表') }
  },
  {
    method: 'cheat.listActors', args: {},
    check: (data) => expect(Array.isArray(data) && data.length === 3 && data[0].className === '剣士' && data[0].level === 5,
      JSON.stringify(data && data[0] && [data[0].className, data[0].level])),
    invalid: { args: { id: 'x' }, check: (data) => expect(Array.isArray(data) && data.length === 3, 'id 不是该方法的入参，应被忽略') }
  },
  {
    method: 'cheat.listMapEvents', args: { mapId: 1 }, async: true,
    check: (data) => expect(Array.isArray(data) && data.length === 2 && data[0].name === '村人アン',
      JSON.stringify(Array.isArray(data) ? data.map((row) => row.name) : data)),
    invalid: { args: { mapId: 'x' }, async: true, check: (data) => expect(Array.isArray(data) && data.length >= 1, 'mapId 回退 0 → 当前地图') }
  },
  {
    method: 'cheat.transferPoints', args: {}, async: true,
    check: (data) => expect(Array.isArray(data) && data.length >= 1 && typeof data[0].eventId === 'number' && data[0].mapId === 3,
      JSON.stringify(data).slice(0, 200)),
    invalid: { args: { mapId: 'x' }, async: true, check: (data) => expect(Array.isArray(data) && data.length >= 1, 'mapId 回退 0 → 当前地图') }
  },
  {
    method: 'cheat.setGold', args: { value: 2500 },
    check: (data) => expect(data.gold === 2500, 'gold=' + data.gold),
    invalid: { args: { value: 'x' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.setVariable', args: { id: 7, value: 'runtime' },
    check: (data) => expect(data.id === 7 && data.value === 'runtime', JSON.stringify(data)),
    invalid: { args: { id: 'x' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.setSwitch', args: { id: 3, on: true },
    check: (data) => expect(data.id === 3 && data.value === true, JSON.stringify(data)),
    invalid: { args: { id: 'x' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.setSelfSwitch', args: { mapId: 3, eventId: 1, letter: 'B', on: true },
    check: (data) => expect(data.mapId === 3 && data.eventId === 1 && data.letter === 'B' && data.value === true, JSON.stringify(data)),
    invalid: { args: { eventId: 'x' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.toggleAllSwitches', args: { on: true },
    check: (data) => expect(data.changed === 6 && data.on === true, JSON.stringify(data)),
    invalid: { args: { on: 'yes' }, check: (data) => expect(data.changed === 6 && data.on === true, 'on 按 Boolean 强制转换') }
  },
  {
    method: 'cheat.toggleAllSelfSwitches', args: { on: false },
    check: (data) => expect(data.changed === 8 && data.on === false && data.mapId === 3, JSON.stringify(data)),
    invalid: { args: { on: 1 }, check: (data) => expect(data.on === true, 'on 按 Boolean 强制转换') }
  },
  // ---- id 必须严格校验：非数字不得静默落到 #1（requireId → cheat_bad_args） ----
  {
    method: 'cheat.giveItem', args: { kind: 'item', id: 3, count: 2 },
    check: (data) => expect(data.id === 3 && data.count === 4, 'item#3 2+2=4，实际 ' + data.count),
    invalid: { args: { id: 'x' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.setItemCount', args: { kind: 'item', id: 1, count: 9 },
    check: (data) => expect(data.id === 1 && data.count === 9, JSON.stringify(data)),
    invalid: { args: { id: 'x' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.updateActor', args: { id: 1, level: 40 },
    check: (data) => expect(Array.isArray(data.changed) && data.changed.includes('level'), JSON.stringify(data)),
    invalid: { args: { id: 'x' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.recoverAll', args: { scope: 'party' },
    check: (data) => expect(data.count === 2, JSON.stringify(data)),
    invalid: { args: { scope: 42 }, check: (data) => expect(data.count === 2, '未知 scope 不影响队伍回满') }
  },
  {
    method: 'cheat.addPartyMember', args: { actorId: 3 },
    check: (data) => expect(Array.isArray(data.members) && data.members.includes(3), JSON.stringify(data)),
    invalid: { args: { actorId: 'x' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.removePartyMember', args: { actorId: 1 },
    check: (data) => expect(Array.isArray(data.members) && !data.members.includes(1), JSON.stringify(data)),
    invalid: { args: { actorId: 0 }, code: 'cheat_out_of_range' }
  },
  {
    method: 'cheat.godMode', args: { on: true, lockHp: true, lockMp: true },
    check: (data) => expect(data.on === true && data.lockHp === true && data.lockMp === true, JSON.stringify(data)),
    invalid: { args: { on: 1 }, check: (data) => expect(data.on === true, 'on 按 Boolean 强制转换') }
  },
  {
    method: 'cheat.noclip', args: { on: true },
    check: (data) => expect(data.on === true, JSON.stringify(data)),
    invalid: { args: { on: 1 }, check: (data) => expect(data.on === true, 'on 按 Boolean 强制转换') }
  },
  {
    method: 'cheat.encounter', args: { on: false },
    check: (data) => expect(data.encounterEnabled === false, JSON.stringify(data)),
    invalid: { args: { on: '' }, check: (data) => expect(data.encounterEnabled === false, '空串按 Boolean 强制转换') }
  },
  {
    method: 'cheat.alwaysDash', args: { on: true },
    check: (data) => expect(data.on === true, JSON.stringify(data)),
    invalid: { args: { on: 1 }, check: (data) => expect(data.on === true, 'on 按 Boolean 强制转换') }
  },
  {
    method: 'cheat.followers', args: { on: false },
    check: (data) => expect(data.on === false, JSON.stringify(data)),
    invalid: { args: { on: 1 }, check: (data) => expect(data.on === true, 'on 按 Boolean 强制转换') }
  },
  {
    method: 'cheat.unlockEquip', args: {},
    check: (data) => expect(typeof data.touched === 'number' && data.touched >= 0, JSON.stringify(data)),
    invalid: { args: { x: 1 }, check: (data) => expect(typeof data.touched === 'number', '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.unlockChoice', args: {}, shape: onlyOk,
    check: (data) => expect(data.ok === true, JSON.stringify(data)),
    invalid: { args: { on: 'x' }, check: (data) => expect(data.ok === true && onlyOk(data) === true, '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.speed', args: { multiplier: 3 },
    check: (data) => expect(data.multiplier === 3, JSON.stringify(data)),
    invalid: { args: { multiplier: 'x' }, check: (data) => expect(data.multiplier === 1, '非数字回退 ×1') }
  },
  {
    method: 'cheat.moveSpeed', args: { value: 5 },
    check: (data) => expect(data.moveSpeed === 5, JSON.stringify(data)),
    invalid: { args: { value: 'x' }, check: (data) => expect(data.moveSpeed === 4, '非数字保持当前值 4') }
  },
  {
    method: 'cheat.teleport', args: { mapId: 1, x: 5, y: 7, dir: 2 },
    check: (data) => expect(data.mapId === 1 && data.x === 5 && data.y === 7, JSON.stringify(data)),
    invalid: { args: { mapId: 'x' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.scene', args: { name: 'menu' },
    check: (data) => expect(data.scene === 'menu', JSON.stringify(data)),
    invalid: { args: { name: 'nope' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.scenePop', args: {},
    check: (data) => expect(typeof data.scene === 'string' && data.scene.length > 0, JSON.stringify(data)),
    invalid: { args: { name: 'x' }, check: (data) => expect(typeof data.scene === 'string', '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.battle', args: { op: 'win' },
    check: (data) => expect(data.op === 'win' && data.inBattle === true, JSON.stringify(data)),
    invalid: { args: { op: 'nope' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.clearPictures', args: {}, shape: onlyOk,
    check: (data) => expect(data.ok === true, JSON.stringify(data)),
    invalid: { args: { x: 1 }, check: (data) => expect(data.ok === true && onlyOk(data) === true, '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.clearEvent', args: {},
    check: (data) => expect(data.erased === false, '没有运行中的事件时应 erased=false'),
    invalid: { args: { id: 1 }, check: (data) => expect(data.erased === false, 'id 不是该方法的入参') }
  },
  {
    method: 'cheat.clearMoveRoute', args: {},
    check: (data) => expect(data.cleared === 1, JSON.stringify(data)),
    invalid: { args: { x: 1 }, check: (data) => expect(data.cleared === 1, '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.closeAllWindows', args: {},
    check: (data) => expect(data.closed === 2, '初始场景有 2 个可 close 的窗口，实际 ' + data.closed),
    invalid: { args: { x: 1 }, check: (data) => expect(data.closed === 2, '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.fadeIn', args: {}, shape: onlyOk,
    check: (data) => expect(data.ok === true, JSON.stringify(data)),
    invalid: { args: { x: 1 }, check: (data) => expect(data.ok === true && onlyOk(data) === true, '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.recover', args: {},
    check: (data) => expect(data.count === 2, JSON.stringify(data)),
    invalid: { args: { x: 1 }, check: (data) => expect(data.count === 2, '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.repair', args: {},
    check: (data) => expect(Array.isArray(data.fixed), JSON.stringify(data)),
    invalid: { args: { x: 1 }, check: (data) => expect(Array.isArray(data.fixed), '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.fixError', args: {},
    check: (data) => expect(Array.isArray(data.fixed), JSON.stringify(data)),
    invalid: { args: { x: 1 }, check: (data) => expect(Array.isArray(data.fixed), '无入参语义，忽略未知键') }
  },
  {
    method: 'cheat.devTools', args: {},
    check: (data) => expect(data.opened === false && typeof data.hint === 'string', JSON.stringify(data)),
    invalid: { args: { x: 1 }, check: (data) => expect(data.opened === false, '无 NW.js 菜单时固定 opened=false') }
  },
  {
    method: 'cheat.objectPath', args: { path: '$gameParty._gold' }, noGameArgs: { path: '$gameParty._gold' },
    check: (data) => expect(data.value === 1200 && data.type === 'number', JSON.stringify(data)),
    invalid: { args: { path: '' }, code: 'cheat_bad_args' }
  },
  {
    method: 'cheat.setObjectPath', args: { path: '$gameVariables._data', value: 1 }, noGameArgs: { path: '$gameParty._gold', value: 1 },
    check: (data) => expect(data.value === 1, JSON.stringify(data)),
    invalid: { args: { path: '$gameParty._gold', value: { a: 1 } }, code: 'cheat_bad_args' }
  },
  {
    method: 'text.scanStart', args: { includeMaps: false, includeRuntime: false },
    check: (data) => expect(typeof data.scanId === 'string' && /^scan-\d+$/.test(data.scanId) && data.estimated > 0,
      JSON.stringify(data)),
    invalid: { args: { includeMaps: 'yes', includeRuntime: false }, check: (data) => expect(typeof data.scanId === 'string', '非 false 一律视为 true') }
  },
  {
    method: 'text.scanCancel', noGameArgs: { scanId: 'scan-missing' }, prep: (h) => {
      const ack = h.rpc('text.scanStart', { includeMaps: false, includeRuntime: false }).ack;
      return { scanId: ack && ack.data ? ack.data.scanId : 'missing' };
    },
    args: (context) => ({ scanId: context.scanId }),
    check: (data) => expect(data.cancelled === true, JSON.stringify(data)),
    invalid: { args: {}, check: (data) => expect(data.cancelled === false && data.reason === 'scan_not_found', JSON.stringify(data)) }
  }
];

/** 无 $game* 时的期望：requireGame 的走 cheat_unavailable，其余按各方法的降级契约。 */
const NO_GAME = {
  'cheat.snapshot': { check: (data) => expect(data.gold === 0 && data.mapId === 0 && Array.isArray(data.party), JSON.stringify(data)) },
  'cheat.listMapEvents': { check: (data) => expect(Array.isArray(data) && data.length === 0, JSON.stringify(data)) },
  'cheat.transferPoints': { check: (data) => expect(Array.isArray(data) && data.length === 0, JSON.stringify(data)) },
  'cheat.devTools': { check: (data) => expect(data.opened === false, JSON.stringify(data)) },
  'cheat.objectPath': { code: 'cheat_out_of_range' },
  'cheat.setObjectPath': { code: 'cheat_out_of_range' },
  'text.scanStart': { check: (data) => expect(typeof data.scanId === 'string' && data.estimated === 0, '无 $data* 时 estimated 必须为 0：' + JSON.stringify(data)) },
  'text.scanCancel': { check: (data) => expect(data.cancelled === false && data.reason === 'scan_not_found', JSON.stringify(data)) }
};

function ackDetail(ack) {
  return ack ? JSON.stringify(ack).slice(0, 300) : '没有 rpcResult';
}

runCase('rpc-table', async (tap) => {
  // ---- 用例表自检：这三条只证明"本文件的表自洽"，不证明产品 ----
  tap.eq(ROWS.length, 45, '[用例表自检] T-000 表固定 45 行（增删方法必须同步本文件与 COVERAGE.md）');
  tap.eq(new Set(ROWS.map((row) => row.method)).size, ROWS.length, '[用例表自检] T-000b 表内方法名无重复');

  // ---- 与产品源码对表：这才是"产品真的只有这 45 个方法"的证据 ----
  {
    const sourceMethods = rpcMethodsInSource();
    const rowMethods = ROWS.map((row) => row.method);
    const onlyInSource = sourceMethods.filter((name) => !rowMethods.includes(name));
    const onlyInRows = rowMethods.filter((name) => !sourceMethods.includes(name));
    const setsEqual = onlyInSource.length === 0 && onlyInRows.length === 0;
    let orderNote = '顺序一致';
    if (setsEqual) {
      const firstDiff = sourceMethods.findIndex((name, index) => name !== rowMethods[index]);
      if (firstDiff >= 0) {
        orderNote = '集合相同但顺序不同，首个分歧 index=' + firstDiff +
          '（源码 ' + sourceMethods[firstDiff] + ' / ROWS ' + rowMethods[firstDiff] + '）';
      }
    }
    tap.ok(setsEqual,
      'T-000c 用例表的方法集合 === Resources/agent_mvmz.js 的 var RPC（双向）',
      '只在源码（产品有、这里没覆盖）：' + JSON.stringify(onlyInSource) +
      '；只在 ROWS（这里写了、产品没有 / 改名了）：' + JSON.stringify(onlyInRows) +
      '；' + orderNote);
  }

  const seen = [];
  const allAcks = [];

  for (let index = 0; index < ROWS.length; index++) {
    const row = ROWS[index];
    const tag = 'T-' + String(index + 1).padStart(3, '0');
    const mode = row.mode === 'bare' ? 'bare' : 'fixture';

    // ---------- H：正常入参 ----------
    {
      const h = createHarness({ fixture: mode === 'fixture' });
      h.drainAll();
      const context = row.prep ? row.prep(h) : {};
      const args = typeof row.args === 'function' ? row.args(context) : row.args;
      const result = row.async ? await h.rpcWait(row.method, args) : h.rpc(row.method, args);
      const ack = result.ack;
      allAcks.push(ack);
      const ok = !!(ack && ack.ok === true);
      const verdict = ok ? row.check(ack.data === undefined ? null : ack.data) : [false, 'ack.ok !== true'];
      const passed = ok && verdict === true;
      tap.ok(passed, tag + '-H ' + row.method + ' 正常入参 → ok:true 且 data 符合契约',
        passed ? null : (ok ? verdict[1] : ackDetail(ack)));
      // 返回形状单独一条：值对但形状漂了（多字段/类型变了）时，前一条未必能发现。
      if (row.shape) {
        const shaped = ok ? row.shape(ack.data === undefined ? null : ack.data) : [false, 'ack.ok !== true'];
        tap.ok(ok && shaped === true,
          tag + '-S ' + row.method + ' 返回形状稳定（键集合与值类型固定）',
          ok ? (shaped === true ? null : shaped[1]) : ackDetail(ack));
      }
      seen.push(row.method);
    }

    // ---------- I：缺参 / 类型错误 ----------
    {
      const h = createHarness({ fixture: mode === 'fixture' });
      h.drainAll();
      const invalid = row.invalid;
      const result = (invalid.async || row.async)
        ? await h.rpcWait(row.method, invalid.args)
        : h.rpc(row.method, invalid.args);
      const ack = result.ack;
      allAcks.push(ack);
      let passed;
      let detail;
      if (invalid.code) {
        passed = !!(ack && ack.ok === false && ack.error && ack.error.code === invalid.code &&
          typeof ack.error.message === 'string' && ack.error.message.length > 0);
        detail = '期望错误码 ' + invalid.code + '（且 message 非空），实际 ' + ackDetail(ack);
      } else {
        const ok = !!(ack && ack.ok === true);
        const verdict = ok ? invalid.check(ack.data === undefined ? null : ack.data) : [false, 'ack.ok !== true'];
        passed = ok && verdict === true;
        detail = ok ? verdict[1] : ackDetail(ack);
      }
      tap.ok(passed, (row.bug ? '[BUG-' + row.bug + '] ' : '') + tag + '-I ' + row.method + ' 缺参/类型错误 → ' +
        (invalid.code ? '明确错误码 ' + invalid.code : '按实现定义的夹取/忽略规则返回 ok'),
        passed ? null : detail);
    }

    // ---------- N：$game* 不在 ----------
    {
      const h = createHarness({ fixture: false });
      h.drainAll();
      const spec = REQUIRES_GAME.has(row.method) ? { code: 'cheat_unavailable' } : (NO_GAME[row.method] || {});
      const noGameArgs = row.noGameArgs || {};
      const result = row.async ? await h.rpcWait(row.method, noGameArgs) : h.rpc(row.method, noGameArgs);
      const ack = result.ack;
      allAcks.push(ack);
      let passed;
      let detail;
      if (spec.code) {
        passed = !!(ack && ack.ok === false && ack.error && ack.error.code === spec.code);
        detail = '期望 ' + spec.code + '，实际 ' + ackDetail(ack);
      } else if (spec.check) {
        const ok = !!(ack && ack.ok === true);
        const verdict = ok ? spec.check(ack.data === undefined ? null : ack.data) : [false, 'ack.ok !== true'];
        passed = ok && verdict === true;
        detail = ok ? verdict[1] : ackDetail(ack);
      } else {
        passed = !!(ack && ack.ok === true);
        detail = ackDetail(ack);
      }
      const expectation = spec.code || '已定义的降级结果（不是 cheat_unavailable）';
      tap.ok(passed, tag + '-N ' + row.method + ' 无 $game* → ' + expectation, passed ? null : detail);
    }
  }

  // ---------- 信封形状（一次覆盖全部 135 个 ack） ----------
  const malformed = allAcks.filter((ack) => !ack || typeof ack.id !== 'string' ||
    typeof ack.ok !== 'boolean' || !Object.prototype.hasOwnProperty.call(ack, 'data') ||
    !Object.prototype.hasOwnProperty.call(ack, 'error') ||
    (ack.ok === true ? ack.error !== null : !ack.error || typeof ack.error.code !== 'string'));
  tap.eq(malformed.length, 0, 'T-999 所有 rpcResult 信封形状一致（id/ok/data/error，失败必带 error.code）',
    malformed.slice(0, 3).map((ack) => JSON.stringify(ack).slice(0, 120)).join(' | '));
  tap.eq(new Set(seen).size, 45, '[用例表自检] T-998 H 维度覆盖 45 个不同方法（无漏项）');
});
