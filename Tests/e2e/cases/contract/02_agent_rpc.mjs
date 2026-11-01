/*
 * 02_agent_rpc.mjs —— rpc / cheat / scan 协议语义（Node vm + 真夹具 + 真 Agent）。
 *
 * 迁移自 `Tests/qa/agent_rpc_smoke.mjs`，断言逐条保留（R-01 … R-57）。
 * 与浏览器探针的分工不变：这里只断言**协议语义**（ok/code、值真的写进引擎对象、
 * 扫描分片与去重），布局 / 重绘 / CDP 时序仍由内核层负责。
 *
 * 夹具不另写一套：`Fixtures/mv_stub/index.html` 的内联脚本原样在 vm 里跑，
 * 因此这里看到的 `$game*` / `$data*` 与浏览器里是同一份。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

runCase('agent-rpc', async (tap) => {
  const h = createHarness({ fixture: true });
  const run = h.run;

  tap.ok(typeof run('window.$gameParty && window.$gameParty._gold') === 'number',
    'R-01 夹具已在 vm 里跑起来（$gameParty 可读）');

  drainTexts(); // 清 hello

  function drainTexts() {
    return h.drainAll().filter((envelope) => envelope && envelope.type === 'text');
  }

  /** 断言 ack.ok===true 并返回 data；失败时把 ack 打进 detail。 */
  function okAck(result, label) {
    const ack = result.ack;
    const passed = !!(ack && ack.ok === true && ack.data !== undefined);
    tap.ok(passed, `${label} → ok:true 且带 data`,
      ack ? JSON.stringify(ack).slice(0, 400) : '没有 rpcResult');
    return passed ? (ack.data || {}) : null;
  }

  // ---- 只读 ----
  const snapshot = okAck(h.rpc('cheat.snapshot'), 'R-02 cheat.snapshot') || {};
  tap.eq([snapshot.scene, snapshot.mapId, snapshot.gold], ['Scene_Map', 3, 1200],
    'R-03 snapshot 的 scene/mapId/gold 来自引擎对象');
  tap.ok(Array.isArray(snapshot.party) && snapshot.party.length === 2 &&
    snapshot.party[0].name === 'アレン' && snapshot.party[0].level === 5,
    'R-04 snapshot.party 来自 $gameParty.members()', JSON.stringify(snapshot.party));

  // ---- 写入：金币 / 变量 / 开关 / 独立开关 / 物品 / 角色 ----
  okAck(h.rpc('cheat.setGold', { value: 4321 }), 'R-05 setGold {value}');
  tap.eq(run('window.$gameParty._gold'), 4321, 'R-06 $gameParty._gold 被改写');
  okAck(h.rpc('cheat.setGold', { delta: 100 }), 'R-07 setGold {delta}');
  tap.eq(run('window.$gameParty._gold'), 4421, 'R-08 delta 是叠加');

  okAck(h.rpc('cheat.setVariable', { id: 7, value: 'スモーク' }), 'R-09 setVariable #7');
  tap.eq(run('window.$gameVariables.value(7)'), 'スモーク', 'R-10 $gameVariables.value(7) 往返');

  okAck(h.rpc('cheat.setSwitch', { id: 3, on: true }), 'R-11 setSwitch #3 on');
  tap.eq(run('window.$gameSwitches.value(3)'), true, 'R-12 $gameSwitches.value(3) 往返');

  okAck(h.rpc('cheat.setSelfSwitch', { mapId: 3, eventId: 1, letter: 'B', on: true }), 'R-13 setSelfSwitch [3,1,B]');
  tap.eq(run('window.$gameSelfSwitches.value([3,1,"B"])'), true, 'R-14 $gameSelfSwitches 往返');

  okAck(h.rpc('cheat.giveItem', { kind: 'item', id: 2, count: 4 }), 'R-15 giveItem item#2 +4');
  tap.eq(run('window.$gameParty.numItems(window.$dataItems[2])'), 5, 'R-16 numItems 从 1 变 5');

  okAck(h.rpc('cheat.updateActor', { id: 1, level: 33 }), 'R-17 updateActor #1 level=33');
  tap.eq(run('window.$gameActors.actor(1).level'), 33, 'R-18 $gameActors.actor(1).level 被改写');
  const actors = h.rpc('cheat.listActors').ack;
  const actor1 = (actors && actors.ok && Array.isArray(actors.data))
    ? actors.data.find((entry) => entry.id === 1) : null;
  tap.ok(!!actor1 && actor1.level === 33 && actor1.className === '剣士',
    'R-19 listActors 反映新 level 并带 className', JSON.stringify(actor1));

  // ---- 世界 / 流程 ----
  okAck(h.rpc('cheat.noclip', { on: true }), 'R-20 noclip on');
  tap.eq(run('window.$gamePlayer._through'), true, 'R-21 $gamePlayer._through 被改写');

  // godMode：夹具是 MV 形（mhp 是方法）；MZ 的 getter 形态由 store/domain 探针另行覆盖。
  okAck(h.rpc('cheat.godMode', { on: true, lockHp: true }), 'R-22 godMode on lockHp');
  run('window.$gameActors.actor(1).setHp(1)');
  tap.eq(run('window.$gameActors.actor(1).hp'), run('window.$gameActors.actor(1).mhp'),
    'R-23 godMode+lockHp：引擎侧 setHp(1) 后 HP 仍等于 mhp');
  okAck(h.rpc('cheat.godMode', { on: false }), 'R-24 godMode off');

  okAck(h.rpc('cheat.encounter', { on: false }), 'R-25 encounter off');
  tap.eq(run('window.$gameSystem._encounterEnabled'), false, 'R-26 on=false → 禁止遇敌');
  okAck(h.rpc('cheat.encounter', { on: true }), 'R-27 encounter on');
  tap.eq(run('window.$gameSystem._encounterEnabled'), true, 'R-28 on=true → 允许遇敌');

  // speed：倍率 2 时一次 SceneManager.update() 应推进 2 帧。
  // 基准必须在 rpc **之后**读：inbox() 末尾会调 __stubRepaint()，那次重绘已经走过一遍被包装的 update。
  okAck(h.rpc('cheat.speed', { multiplier: 2 }), 'R-29 speed ×2');
  const framesBefore = run('window.SceneManager._frameCount');
  run('window.SceneManager.update()');
  tap.eq(run('window.SceneManager._frameCount') - framesBefore, 2, 'R-30 speed ×2：一次 update 走两帧');
  okAck(h.rpc('cheat.speed', { multiplier: 1 }), 'R-31 speed 复位 ×1');
  const framesReset = run('window.SceneManager._frameCount');
  run('window.SceneManager.update()');
  tap.eq(run('window.SceneManager._frameCount') - framesReset, 1, 'R-32 speed 复位后一次 update 只走一帧');

  // transferPoints 必须在 teleport 之前（它读"当前地图"）
  const points = (await h.rpcWait('cheat.transferPoints')).ack;
  tap.ok(!!points && points.ok === true && Array.isArray(points.data) && points.data.length >= 1 &&
    typeof points.data[0].mapId === 'number' && typeof points.data[0].eventId === 'number',
    'R-33 transferPoints 从 $dataMap 的 201/<TP> 里取到至少一个点',
    JSON.stringify(points && points.data).slice(0, 300));

  okAck(h.rpc('cheat.teleport', { mapId: 1, x: 5, y: 7, dir: 2 }), 'R-34 teleport {mapId:1,x:5,y:7}');
  run('window.__stubRepaint()'); // 引擎在 Scene_Map.update 里做 performTransfer
  tap.eq(
    run('JSON.stringify({x: window.$gamePlayer._x, y: window.$gamePlayer._y, mapId: window.$gameMap.mapId()})'),
    JSON.stringify({ x: 5, y: 7, mapId: 1 }),
    'R-35 传送落到 $gamePlayer._x/_y 且 mapId 切换');

  okAck(h.rpc('cheat.scene', { name: 'menu' }), 'R-36 scene menu');
  tap.eq(run('window.SceneManager._scene.constructor.name'), 'Scene_Menu', 'R-37 SceneManager._scene = Scene_Menu');
  okAck(h.rpc('cheat.scenePop'), 'R-38 scenePop');
  tap.eq(run('window.SceneManager._scene.constructor.name'), 'Scene_Map', 'R-39 scenePop 回到 Scene_Map');

  // 结算语义的观测点：必须在 rpc 之前装。
  //   · check / victory：证明"结束"是引擎的 checkBattleEnd 判的（它内部调一次 processVictory），
  //     Agent 不该在 ended===true 之后再补一次 processVictory —— 那会把经验/金钱发两遍。
  //   · die：作弊路径的三步是 setHp(0) → die() → 补死亡状态（见 killEnemyMember）。
  //     die() 必须真的被调一次：插件把掉落 / 伤害转金币 / 战利品结算挂在 die() 上，
  //     setHp(0) 的 refresh 不会触发它们（exp 走 expTotal 不受影响，表现为"经验正常、钱为 0"）。
  //     但 die() 的 clearStates() 会抹掉死亡状态，所以第三步必须把它补回来 ——
  //     只 setHp 不 die 与只 die 不补状态，都会让 _hp===0 的尸体进不了 deadMembers()，
  //     expTotal/goldTotal/makeDropItems 归零。
  //   · diePerEnemy / deadAfterDie：按敌人记录 die 次数，以及 die() 返回那一刻是否还带死亡状态
  //     （MZ 语义下必为 false，因为 Game_BattlerBase.die 不调 refresh）。
  run('(function () {' +
    'window.__battleSpy = { check: 0, victory: 0, defeat: 0, die: 0, diePerEnemy: [], deadAfterDie: [] };' +
    'var BM = window.BattleManager;' +
    'var checkBattleEnd = BM.checkBattleEnd;' +
    'var processVictory = BM.processVictory;' +
    'BM.checkBattleEnd = function () { window.__battleSpy.check += 1; return checkBattleEnd.apply(this, arguments); };' +
    'BM.processVictory = function () { window.__battleSpy.victory += 1; return processVictory.apply(this, arguments); };' +
    'window.$gameTroop.members().forEach(function (enemy, i) {' +
      'window.__battleSpy.diePerEnemy[i] = 0;' +
      'window.__battleSpy.deadAfterDie[i] = null;' +
      'var die = enemy.die;' +
      'enemy.die = function () {' +
        'window.__battleSpy.die += 1;' +
        'window.__battleSpy.diePerEnemy[i] += 1;' +
        'var out = die.apply(this, arguments);' +
        'window.__battleSpy.deadAfterDie[i] = enemy.isDeathStateAffected();' +
        'return out;' +
      '};' +
    '});' +
  '})()');

  okAck(h.rpc('cheat.battle', { op: 'win' }), 'R-40 battle win');
  tap.ok(run('window.BattleManager._phase === "victory" || window.BattleManager._victory === true'),
    'R-41 BattleManager 进入胜利态');
  tap.eq(run('window.$gameTroop.isAllDead()'), true, 'R-41b 敌群真的全灭了（isDead 由死亡状态判定，不是只看 _hp）');
  tap.ok(run('window.$gameTroop.expTotal()') > 0 && run('window.$gameTroop.goldTotal()') > 0,
    'R-41c 胜利结算有收益：expTotal 与 goldTotal 都非 0',
    'exp=' + run('window.$gameTroop.expTotal()') + ' gold=' + run('window.$gameTroop.goldTotal()'));
  tap.ok(run('window.$gameTroop.makeDropItems().length') > 0,
    'R-41d makeDropItems 按 deadMembers 产出掉落（非空）',
    'drops=' + run('JSON.stringify(window.$gameTroop.makeDropItems())'));
  tap.eq(run('window.__battleSpy.check'), 1, 'R-41e 结束判定只走一次 checkBattleEnd');
  tap.eq(run('window.__battleSpy.victory'), 1,
    'R-41f processVictory 只被调用一次（checkBattleEnd 已判胜，Agent 不再补刀，收益不会发两遍）');
  // R-41g：die 次数按敌人断言（不写死敌群大小，期望值由 members() 现场推出）。
  // 恰好一次：少了 die() 插件挂在上面的结算不触发；多了说明同一场战斗被重复处理。
  const troopSize = run('window.$gameTroop.members().length');
  const expectedDies = JSON.stringify(Array.from({ length: troopSize }, () => 1));
  const diePerEnemy = run('JSON.stringify(window.__battleSpy.diePerEnemy)');
  tap.eq(diePerEnemy, expectedDies,
    'R-41g die() 对每个敌人恰好调用一次（插件挂在 die 上的结算才会触发）',
    'diePerEnemy=' + diePerEnemy + ' total=' + run('window.__battleSpy.die'));

  // R-41h：死亡状态确实是"补"回来的 —— die() 返回那一刻它已被 clearStates 抹掉，
  // 所以三步的顺序只能是 setHp → die → addState，反过来会被清掉。
  const deadAfterDie = run('JSON.stringify(window.__battleSpy.deadAfterDie)');
  tap.eq(deadAfterDie, JSON.stringify(Array.from({ length: troopSize }, () => false)),
    'R-41h die() 返回时死亡状态已被 clearStates 抹掉（第三步必须存在的原因）',
    'deadAfterDie=' + deadAfterDie);

  // R-41i：三步走完后每个敌人都重新带上死亡状态（补回成功）。
  tap.ok(
    run('window.$gameTroop.members().every(function (e) {' +
      'return e.isDeathStateAffected() && e.isDead(); })'),
    'R-41i 三步之后每个敌人都重新带上死亡状态（isDeathStateAffected / isDead 都为真）');

  // R-41j：deadMembers 非空且覆盖全部敌人 —— 它是 expTotal/goldTotal/makeDropItems 的唯一求和基础。
  tap.eq(run('window.$gameTroop.deadMembers().length'), troopSize,
    'R-41j deadMembers 非空且覆盖全部敌人',
    'dead=' + run('window.$gameTroop.deadMembers().length') + ' members=' + troopSize);

  // ---- objectPath / setObjectPath / 安全边界 ----
  const read = h.rpc('cheat.objectPath', { path: '$gameParty._gold' }).ack;
  tap.ok(!!read && read.ok === true && read.data && read.data.value === 4421,
    'R-42 objectPath 读到 $gameParty._gold', JSON.stringify(read && read.data));

  okAck(h.rpc('cheat.setObjectPath', { path: '$gameVariables._data', value: 1 }), 'R-43 setObjectPath $gameVariables._data');
  tap.eq(h.rpc('cheat.setObjectPath', { path: 'location.href', value: 'x' }).ack.error.code, 'cheat_forbidden',
    'R-44 不在 $game*/$data* 前缀的路径 → cheat_forbidden');

  // ---- 错误路径 ----
  const outOfRange = h.rpc('cheat.setVariable', { id: 99999, value: 1 }).ack;
  tap.ok(!!outOfRange && outOfRange.ok === false && outOfRange.error.code === 'cheat_out_of_range',
    'R-45 越界 id → cheat_out_of_range（不夹取）', JSON.stringify(outOfRange).slice(0, 300));
  tap.eq(h.rpc('cheat.snapshot').ack.ok, true, 'R-46 错误路径之后 Agent 仍可用');

  const unknown = h.rpc('cheat.noSuchMethod').ack;
  tap.ok(!!unknown && unknown.ok === false && unknown.error.code === 'rpc_unknown_method',
    'R-47 未知 method → rpc_unknown_method', JSON.stringify(unknown).slice(0, 300));

  // ---- 扫描 ----
  const start = h.rpc('text.scanStart', { includeRuntime: false }).ack;
  const started = tap.ok(!!start && start.ok === true && typeof start.data.scanId === 'string',
    'R-48 scanStart 立即返回 scanId/estimated', JSON.stringify(start).slice(0, 300));
  if (started) {
    const terms = start.data.terms;
    tap.ok(Array.isArray(terms) && terms.length > 0 &&
      terms.every((term) => typeof term.raw === 'string' && typeof term.path === 'string'),
      'R-48b scanStart 带回 $dataSystem.terms（不走 scanCandidate）', JSON.stringify(terms).slice(0, 300));
    const scanId = start.data.scanId;
    const { events, done } = await h.collectScan(scanId);
    tap.ok(!!done, 'R-49 scanDone 到达', 'scanId=' + scanId + ' events=' + events.length);
    if (done) {
      const items = [];
      for (const envelope of events) {
        if (envelope.type === 'scanChunk' && Array.isArray(envelope.payload.items)) {
          items.push(...envelope.payload.items);
        }
      }
      const raws = items.map((item) => item && item.raw);
      const unique = new Set(raws);
      tap.ok(done.total > 0 && items.length > 0 && done.total >= items.length,
        'R-50 total>0 且不小于实际收到的条目数', 'total=' + done.total + ' items=' + items.length);
      tap.eq(unique.size, raws.length, 'R-51 同一次扫描内无重复 raw（Agent 侧已去重）');
      tap.ok(items.every((item) => item && typeof item.raw === 'string' && item.raw.length > 0 &&
        typeof item.source === 'string' && typeof item.path === 'string'),
        'R-52 每条 item 都有 raw/source/path');
      tap.eq(done.cancelled, false, 'R-53 未取消的扫描 cancelled=false');
      tap.ok(done.skipped >= 0 && typeof done.skipped === 'number',
        'R-54 scanDone 带 skipped 计数', 'skipped=' + done.skipped);
    }

    // 取消：start 与 cancel 在同一个同步块里发出，扫描一定还没跑完（分片靠 setTimeout）
    const secondStart = h.rpc('text.scanStart', { includeRuntime: false }).ack;
    const secondId = secondStart && secondStart.data && secondStart.data.scanId;
    const cancelRun = secondId ? h.rpc('text.scanCancel', { scanId: secondId }) : { ack: null, events: [] };
    tap.ok(!!cancelRun.ack && cancelRun.ack.ok === true, 'R-55 scanCancel 返回 ok:true', JSON.stringify(cancelRun.ack));
    if (secondId) {
      // scanCancel 是同步完成的：它的 scanDone 与 rpcResult 同一批 drain 出来，必须当 seed 传进去。
      const cancelledRun = await h.collectScan(secondId, 5000, cancelRun.events);
      tap.eq(cancelledRun.done && cancelledRun.done.cancelled, true, 'R-56 取消后 scanDone.cancelled === true');
      tap.eq(cancelledRun.done && cancelledRun.done.total >= 0, true, 'R-57 取消结果仍带 total（可判定，不是空壳）');
    }
  }

  tap.note('agent.state=' + JSON.stringify(h.state()));
});
