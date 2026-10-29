/*
 * 14_update_actor_equips.mjs —— cheat.updateActor 的装备写入：三态 id 与失败原子性。
 *
 * 依据：Resources/agent_mvmz.js 的 cheatUpdateActor equips 分支。
 *
 * 口径（与 D18 的顶层 id 一致）：
 *   · itemId **缺失**（undefined/null）→ 卸下该槽（UI 的 CheatEquipSlot.itemId == nil）；
 *   · itemId **存在但非数字** → cheat_bad_args；
 *   · itemId **存在但越界** → cheat_out_of_range；
 *   · slotId 同理（0 合法）：缺失忽略该条，存在但非数字/越界必须报错。
 * 失败时**任何槽位都不得变化**：逐条"边验边写"会在第二条出错时留下半成品，
 * 用户看到的是"报错了但装备已经乱了"，比单纯报错更难查。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

/** 角色 #1 的 5 个装备槽，元素为 itemId 或 null。 */
const slots = (h) => JSON.parse(h.run(
  'JSON.stringify(window.$gameActors.actor(1).equips().map(function (e) { return e ? e.id : null; }))'
));

const codeOf = (ack) => (ack && ack.error && ack.error.code) || null;

runCase('actor-equips', (tap) => {
  const h = createHarness({ fixture: true });
  h.drainAll();

  const baseline = slots(h);
  tap.eq(baseline, [2, null, null, null, null],
    'U-01 前置：角色 #1 初始装备 = 鉄の槍(2) + 4 个空槽', JSON.stringify(baseline));

  // ---- itemId 非数字：不得静默夹到 1（銅の剣） ----
  {
    const ack = h.rpc('cheat.updateActor', {
      id: 1, equips: [{ slotId: 0, kind: 'weapon', itemId: 'abc' }]
    }).ack;
    tap.eq(codeOf(ack), 'cheat_bad_args',
      'U-02 itemId 非数字 → cheat_bad_args（不夹到 weapon#1）', JSON.stringify(ack));
    tap.eq(slots(h), baseline, 'U-03 itemId 非数字失败后所有槽位不变', JSON.stringify(slots(h)));
  }

  // ---- itemId 越界 ----
  {
    const ack = h.rpc('cheat.updateActor', {
      id: 1, equips: [{ slotId: 0, kind: 'weapon', itemId: 99999 }]
    }).ack;
    tap.eq(codeOf(ack), 'cheat_out_of_range',
      'U-04 itemId 越界 → cheat_out_of_range', JSON.stringify(ack));
    tap.eq(slots(h), baseline, 'U-05 itemId 越界失败后所有槽位不变', JSON.stringify(slots(h)));
  }

  // ---- slotId 非数字 / 越界 ----
  {
    const nonNumeric = h.rpc('cheat.updateActor', {
      id: 1, equips: [{ slotId: 'x', kind: 'weapon', itemId: 1 }]
    }).ack;
    tap.eq(codeOf(nonNumeric), 'cheat_bad_args',
      'U-06 slotId 非数字 → cheat_bad_args', JSON.stringify(nonNumeric));
    const outOfRange = h.rpc('cheat.updateActor', {
      id: 1, equips: [{ slotId: 9, kind: 'weapon', itemId: 1 }]
    }).ack;
    tap.eq(codeOf(outOfRange), 'cheat_out_of_range',
      'U-07 slotId 越界 → cheat_out_of_range（不夹到 4）', JSON.stringify(outOfRange));
    tap.eq(slots(h), baseline, 'U-08 slotId 非法失败后所有槽位不变', JSON.stringify(slots(h)));
  }

  // ---- 原子性：第一条合法、第二条非法 → 一条都不写 ----
  {
    const ack = h.rpc('cheat.updateActor', {
      id: 1,
      equips: [
        { slotId: 0, kind: 'weapon', itemId: 1 },
        { slotId: 1, kind: 'weapon', itemId: 'abc' }
      ]
    }).ack;
    tap.eq(codeOf(ack), 'cheat_bad_args',
      'U-09 同批第二条非法 → 整批拒绝', JSON.stringify(ack));
    tap.eq(slots(h), baseline, 'U-10 整批拒绝时第一条合法槽也没有被写', JSON.stringify(slots(h)));
  }

  // ---- classId 同族：越界不得夹到 9999 后写进不存在的职业 ----
  {
    const before = h.run('window.$gameActors.actor(1)._classId');
    const ack = h.rpc('cheat.updateActor', { id: 1, classId: 99999 }).ack;
    tap.eq(codeOf(ack), 'cheat_out_of_range',
      'U-11 classId 越界 → cheat_out_of_range', JSON.stringify(ack));
    tap.eq(h.run('window.$gameActors.actor(1)._classId'), before,
      'U-12 classId 越界失败后职业不变', String(h.run('window.$gameActors.actor(1)._classId')));
    const nonNumeric = h.rpc('cheat.updateActor', { id: 1, classId: 'abc' }).ack;
    tap.eq(codeOf(nonNumeric), 'cheat_bad_args',
      'U-13 classId 非数字 → cheat_bad_args（不静默忽略）', JSON.stringify(nonNumeric));
  }

  // ---- itemId 缺失 = 卸下 ----
  {
    const ack = h.rpc('cheat.updateActor', {
      id: 1, equips: [{ slotId: 0, kind: 'weapon' }]
    }).ack;
    tap.ok(!!ack && ack.ok === true, 'U-14 itemId 缺失 → ok:true（按 UI 语义卸下）', JSON.stringify(ack));
    tap.eq(slots(h), [null, null, null, null, null],
      'U-15 itemId 缺失后槽 0 被清空', JSON.stringify(slots(h)));
  }

  // ---- 越界 actor id：真 MZ 的 $gameActors.actor(id) 对未知 id 返回 null ----
  // 夹具若对任意 id 都 new Game_Actor，这条分支在 contract 层永远观测不到。
  {
    const party = () => h.run(
      'JSON.stringify(window.$gameParty.members().map(function (a) { return [a.actorId(), a._level]; }))'
    );
    const before = party();
    const ack = h.rpc('cheat.updateActor', { id: 99999, level: 50 }).ack;
    tap.eq(codeOf(ack), 'cheat_out_of_range',
      'U-16 updateActor id=99999 → cheat_out_of_range（夹具不再凭空造角色）', JSON.stringify(ack));
    tap.eq(party(), before, 'U-17 越界调用后队伍成员与等级不变', party());
  }
});
