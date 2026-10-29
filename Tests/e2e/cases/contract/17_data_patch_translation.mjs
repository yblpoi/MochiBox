/*
 * 17_data_patch_translation.mjs —— 数据回写：运行时拼接文本的片段替换。
 *
 * 缺陷面：displayCurrentState / displayAction / Game_Actor.setup 都是**先拼串再绘制**，
 * 拼好的串（アレンは身を守っている。）从来没有以完整形式进过翻译表，绘制 hook 查表必然失配。
 * 修法是把片段本身换掉（$dataActors[].name、$dataStates[].messageN），这里钉死六件事：
 *
 *   1. 时机：createGameObjects 的原函数**之前**完成回写，setup 拿到的 _name 就是中文；
 *   2. 原子：名字与 message3 同一批落盘（记录里的 batch 必须相等），拼出来全中文；
 *   3. 边界：note / meta 逐字节不变（StateHelp / HzExState 的解析源）；
 *   4. 健壮：索引 0 的 null 与数组里的 null 元素不抛异常；
 *   5. 晚到：译文在 createGameObjects 之后才下发，HUD 用的 _name 也会变中文；
 *   6. 还原：disable 后数据与 _name 全部回原文；setName（剧情改名）被拦成中文。
 */
import { createHarness, sleep } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

const ITEMS = [
  { key: 'ミューテ', translatedRaw: '缪特', segments: [{ kind: 'text', value: '缪特' }] },
  { key: 'リリス', translatedRaw: '莉莉丝', segments: [{ kind: 'text', value: '莉莉丝' }] },
  { key: '黒ミューテ', translatedRaw: '黑缪特', segments: [{ kind: 'text', value: '黑缪特' }] },
  { key: 'ミューテのプロフィール', translatedRaw: '缪特的个人资料',
    segments: [{ kind: 'text', value: '缪特的个人资料' }] },
  { key: 'は身を守っている。', translatedRaw: '正在保护自己。',
    segments: [{ kind: 'text', value: '正在保护自己。' }] },
  { key: 'は拘束されている！', translatedRaw: '被束缚着！',
    segments: [{ kind: 'text', value: '被束缚着！' }] },
  { key: '逃走不可', translatedRaw: '无法逃走', segments: [{ kind: 'text', value: '无法逃走' }] },
  { key: '強撃', translatedRaw: '强击', segments: [{ kind: 'text', value: '强击' }] },
  { key: '敵単体に大打撃を与える', translatedRaw: '给单个敌人造成巨大伤害',
    segments: [{ kind: 'text', value: '给单个敌人造成巨大伤害' }] },
  { key: 'は強撃を放った！', translatedRaw: '释放了强击！',
    segments: [{ kind: 'text', value: '释放了强击！' }] },
  { key: 'に大打撃を与えた！', translatedRaw: '造成了巨大伤害！',
    segments: [{ kind: 'text', value: '造成了巨大伤害！' }] },
  { key: 'ポーション', translatedRaw: '药水', segments: [{ kind: 'text', value: '药水' }] },
  { key: 'HPを50回復する', translatedRaw: '回复50点HP',
    segments: [{ kind: 'text', value: '回复50点HP' }] },
  { key: '銅の剣', translatedRaw: '铜剑', segments: [{ kind: 'text', value: '铜剑' }] },
  { key: 'ありふれた片手剣', translatedRaw: '随处可见的单手剑',
    segments: [{ kind: 'text', value: '随处可见的单手剑' }] },
  { key: '旅人の服', translatedRaw: '旅人的衣服', segments: [{ kind: 'text', value: '旅人的衣服' }] },
  { key: '動きやすい上着', translatedRaw: '便于活动的上衣',
    segments: [{ kind: 'text', value: '便于活动的上衣' }] },
  { key: '剣士', translatedRaw: '剑士', segments: [{ kind: 'text', value: '剑士' }] },
  { key: 'スライム', translatedRaw: '史莱姆', segments: [{ kind: 'text', value: '史莱姆' }] },
  // 黑名单专用：这两条即使有译文也**不得**落到 note / meta 上。
  { key: '前衛で戦う', translatedRaw: '在前排战斗', segments: [{ kind: 'text', value: '在前排战斗' }] },
  { key: '拘束', translatedRaw: '束缚', segments: [{ kind: 'text', value: '束缚' }] }
];

const NOTE_HELP = '<STATE_HELP:1:98:抵抗不能>拘束状態</STATE_HELP>';
const META_JSON = '{"hzExState_auto":1,"hzExState_text":"拘束"}';
const KANA = /[\u3040-\u30FF]/;

function deliver(h, items = ITEMS) {
  h.inbox({ type: 'setTranslations', payload: { items } });
  h.drainAll();
}

function records(h) {
  return JSON.parse(h.run('JSON.stringify(window.__mochibox.dataPatch.records())'));
}

function stats(h) {
  return JSON.parse(h.run('JSON.stringify(window.__mochibox.dataPatch.stats())'));
}

/** 轮询等待防抖回调落地（真实 setTimeout，不用假时钟硬等）。 */
async function waitFor(predicate, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) { return true; }
    await sleep(25);
  }
  return predicate();
}

runCase('data-patch', async (tap) => {
  // DP1 —— 时机 + 名字：createGameObjects 之前回写，setup 直接拿到中文。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    tap.eq(h.probe().hooks.includes('DataManager.createGameObjects'), true,
      'DP1 安装 DataManager.createGameObjects hook');
    tap.eq(h.probe().hooks.includes('DataManager.extractSaveContents'), true,
      'DP1 安装 DataManager.extractSaveContents hook（读档时机）');
    tap.eq(h.probe().hooks.includes('Game_Actor.setName'), true,
      'DP1 安装 Game_Actor.setName hook');

    deliver(h);
    h.run('DataManager.createGameObjects()');

    tap.eq(h.run('$gameActors.actor(1)._name'), '缪特',
      'DP1 Game_Actor.setup 后 _name 是中文（先 createGameObjects 后 actor(1)）');
    tap.eq(h.run('__dataStub.snapshots.actorName'), '缪特',
      'DP1 createGameObjects 原函数体内看到的 $dataActors[1].name 已是中文');
    tap.eq(h.run('__dataStub.snapshots.stateMessage3'), '正在保护自己。',
      'DP1 createGameObjects 原函数体内看到的 message3 已是中文');

    // DP2 —— 拼接整句：名字 + message3。
    const composed = h.run('$dataActors[1].name + $dataStates[1].message3');
    tap.eq(composed, '缪特正在保护自己。', 'DP2 名字 + message3 拼出全中文整句');
    tap.eq(KANA.test(composed), false, 'DP2 拼出的整句不含假名');

    const recs = records(h);
    const nameRec = recs.find((r) => r.table === '$dataActors' && r.index === 1 && r.field === 'name');
    const msgRec = recs.find((r) => r.table === '$dataStates' && r.index === 1 && r.field === 'message3');
    tap.eq(!!nameRec && !!msgRec, true, 'DP2 名字与 message3 都有回写记录');
    tap.eq(nameRec && msgRec ? nameRec.batch === msgRec.batch : false, true,
      'DP2 名字与 message3 同一批落盘（不存在半日文中间态）');
    tap.eq(nameRec && nameRec.original, 'ミューテ', 'DP2 记录保存了原文（还原依据）');

    // DP3 —— 黑名单：note / meta 逐字节不变。
    tap.eq(h.run('__dataStub.dataStates[1].note'), NOTE_HELP,
      'DP3 状态 note（含 <STATE_HELP>）逐字节不变');
    tap.eq(h.run('JSON.stringify(__dataStub.dataStates[1].meta)'), META_JSON,
      'DP3 状态 meta（hzExState_*）逐字节不变');
    tap.eq(h.run('__dataStub.dataClasses[1].note'), '前衛で戦う',
      'DP3 class note 即使词表里有译文也不回写');

    // 白名单其它表也生效（不是只处理 Actors / States）。
    tap.eq(h.run('$dataStates[1].name'), '无法逃走', 'DP3 状态 name 回写（窄框小标签）');
    tap.eq(h.run('$dataStates[1].message4'), '被束缚着！', 'DP3 message4 回写');
    tap.eq(h.run('$dataSkills[1].message1'), '释放了强击！', 'DP3 技能 message1 回写');
    tap.eq(h.run('$dataItems[1].description'), '回复50点HP', 'DP3 道具 description 回写');
    tap.eq(h.run('$dataWeapons[1].name'), '铜剑', 'DP3 武器 name 回写');
    tap.eq(h.run('$dataEnemies[1].name'), '史莱姆', 'DP3 敌人 name 回写');

    // DP4 —— 索引 0 的 null 占位与数组里的 null 元素。
    tap.eq(h.run('$dataStates[0] === null && $dataStates[2] === null'), true,
      'DP4 索引 0 / null 元素保持原样');
    tap.eq(h.probe().errors, 0, 'DP4 回写全程无异常');

    // DP9 —— 数据回写不得污染文本流。
    tap.eq(h.drainAll().filter((e) => e && e.type === 'text').length, 0,
      'DP9 回写不发 text 事件');

    // DP8 —— 幂等：重复触发不叠加、中文不会被当成原文再翻一次。
    const before = stats(h);
    h.run('DataManager.createGameObjects()');
    deliver(h);
    const after = stats(h);
    tap.eq(after.applied, before.applied, 'DP8 二次 createGameObjects / 重发译文都不新增写入');
    tap.eq(after.batches, before.batches, 'DP8 没有新字段就不产生新批次');
    tap.eq(h.run('$dataActors[1].name'), '缪特', 'DP8 中文不会被二次翻译');

    h.run('window.__mochibox.install(); window.__mochibox.install();');
    const hooks = h.probe().hooks;
    tap.eq(hooks.length, new Set(hooks).size, 'DP8 重复 install() 的 hooks 无重复项');
    tap.eq(stats(h).applied, before.applied, 'DP8 重复 install() 不重复回写');
  }

  // DP5 —— 译文晚到：先 createGameObjects，后 setTranslations，HUD 的 _name 仍要变中文。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    h.run('DataManager.createGameObjects()');
    tap.eq(h.run('$gameActors.actor(1)._name'), 'ミューテ', 'DP5 译文未到时 _name 是原文');
    tap.eq(h.run('$dataStates[1].message3'), 'は身を守っている。', 'DP5 译文未到时 message3 是原文');

    deliver(h);
    const ok = await waitFor(() => h.run('$gameActors.actor(1)._name') === '缪特');
    tap.eq(ok, true, 'DP5 译文晚到后 HUD 用的 _name 防抖补写成中文');
    tap.eq(h.run('$dataStates[1].message3'), '正在保护自己。', 'DP5 译文晚到后 message3 补写成中文');
    tap.eq(h.run('__dataStub.snapshots.actorName'), 'ミューテ',
      'DP5 晚到路径确实发生在 createGameObjects 之后（首次快照仍是原文）');
  }

  // DP6 / DP10 / DP11 —— 还原路径：disable、uninstall、再 enable。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    tap.eq(h.run('$gameActors.actor(1)._name'), '缪特', 'DP6 基线：_name 已中文');

    h.inbox({ type: 'config', payload: { enabled: false } });
    h.drainAll();
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP6 disable 后 $dataActors.name 还原');
    tap.eq(h.run('$dataStates[1].message3'), 'は身を守っている。', 'DP6 disable 后 message3 还原');
    tap.eq(h.run('$dataStates[1].name'), '逃走不可', 'DP6 disable 后状态 name 还原');
    tap.eq(h.run('$dataSkills[1].message1'), 'は強撃を放った！', 'DP6 disable 后技能 message1 还原');
    tap.eq(h.run('$gameActors.actor(1)._name'), 'ミューテ', 'DP6 disable 后 Game_Actor._name 还原');
    tap.eq(h.run('__dataStub.dataStates[1].note'), NOTE_HELP, 'DP6 还原不碰 note');
    tap.eq(h.run('JSON.stringify(__dataStub.dataStates[1].meta)'), META_JSON, 'DP6 还原不碰 meta');
    tap.eq(stats(h).applied, 0, 'DP6 还原后账本清空');

    deliver(h);
    await sleep(500);
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP6 关闭状态下新译文不触发回写');

    h.inbox({ type: 'config', payload: { enabled: true } });
    h.drainAll();
    tap.eq(h.run('$dataActors[1].name'), '缪特', 'DP11 重新 enable 后数据再次回写');
    tap.eq(h.run('$gameActors.actor(1)._name'), '缪特', 'DP11 重新 enable 后 _name 同步');

    h.run('window.__mochibox.uninstall()');
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP10 uninstall 后 $dataActors.name 还原');
    tap.eq(h.run('$dataStates[1].message3'), 'は身を守っている。', 'DP10 uninstall 后 message3 还原');
    tap.eq(h.run('$gameActors.actor(1)._name'), 'ミューテ', 'DP10 uninstall 后 _name 还原');
    tap.eq(h.probe().hooks, [], 'DP10 uninstall 后 hooks 清空');
  }

  // DP7 —— setName（事件指令 code 320 的剧情改名）拦截。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');

    h.run("$gameActors.actor(1).setName('黒ミューテ')");
    tap.eq(h.run('$gameActors.actor(1)._name'), '黑缪特', 'DP7 setName 传入日文被换成中文');

    h.run("$gameActors.actor(1).setName('名無し')");
    tap.eq(h.run('$gameActors.actor(1)._name'), '名無し', 'DP7 未收录的名字原样写入');

    h.inbox({ type: 'config', payload: { enabled: false } });
    h.drainAll();
    // P1：账本记的是"我们写进去的值"。第二次 setName('名無し') 之后游戏当前值比账本新，
    // 还原必须让位（旧行为会把它改回 黒ミューテ，即比游戏当前值更早的名字）。
    tap.eq(h.run('$gameActors.actor(1)._name'), '名無し',
      'DP7 disable 不覆盖游戏后来改的名字（数据名/剧情名/中文都不写回）');
    h.run("$gameActors.actor(1).setName('黒ミューテ')");
    tap.eq(h.run('$gameActors.actor(1)._name'), '黒ミューテ', 'DP7 关闭后 setName 直通');
  }

  // DP12 —— clear（清理假译文后重发）：先撤回，再按新译文回写（旧账本不能挡住新译文）。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    tap.eq(h.run('$dataActors[1].name'), '缪特', 'DP12 基线：名字已回写');

    h.inbox({ type: 'clear' });
    h.drainAll();
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP12 clear 后数据字段还原');
    tap.eq(h.run('$gameActors.actor(1)._name'), 'ミューテ', 'DP12 clear 后 _name 还原');
    tap.eq(stats(h).applied, 0, 'DP12 clear 后账本清空');

    deliver(h, [{ key: 'ミューテ', translatedRaw: '繆特', segments: [{ kind: 'text', value: '繆特' }] }]);
    const ok = await waitFor(() => h.run('$dataActors[1].name') === '繆特');
    tap.eq(ok, true, 'DP12 重发的新译文能再次回写（账本已清）');
    tap.eq(h.run('$gameActors.actor(1)._name'), '繆特', 'DP12 新译文同步到 _name');
  }

  // DP13 —— clear 不得抹掉剧情改名（code 320 不会重放，还原了就再也回不来）。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    h.run("$gameActors.actor(1).setName('黒ミューテ')");
    tap.eq(h.run('$gameActors.actor(1)._name'), '黑缪特', 'DP13 基线：剧情改名已译');

    h.inbox({ type: 'clear' });
    h.drainAll();
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP13 clear 后数据字段仍整体还原');
    tap.eq(h.run('$gameActors.actor(1)._name'), '黑缪特', 'DP13 clear 保留剧情改名');
    tap.eq(stats(h).actorNames, 1, 'DP13 剧情改名的账仍在（留给 disable 还原）');

    deliver(h);
    const ok = await waitFor(() => h.run('$dataActors[1].name') === '缪特');
    tap.eq(ok, true, 'DP13 重发后数据字段重新回写');
    tap.eq(h.run('$gameActors.actor(1)._name'), '黑缪特', 'DP13 重发不会用数据名盖掉剧情名');

    h.inbox({ type: 'config', payload: { enabled: false } });
    h.drainAll();
    tap.eq(h.run('$gameActors.actor(1)._name'), '黒ミューテ', 'DP13 disable 后回到日文剧情名');
  }

  // DP14 —— 顺序反过来：先 sync 记账（译文晚到），再 setName（剧情改名）。
  // 两条账落在同一个 actor 上，剧情入参必须覆盖 sync 记下的数据原文。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    h.run('DataManager.createGameObjects()');
    h.run('$gameActors.actor(1)');           // 先把角色建出来（_name = ミューテ）
    deliver(h);
    const synced = await waitFor(() => h.run('$gameActors.actor(1)._name') === '缪特');
    tap.eq(synced, true, 'DP14 晚到译文把已建角色的 _name 同步成中文');
    tap.eq(stats(h).actorNames, 1, 'DP14 sync 已记下一条账');

    h.run("$gameActors.actor(1).setName('黒ミューテ')");
    tap.eq(h.run('$gameActors.actor(1)._name'), '黑缪特', 'DP14 剧情改名仍被翻译');

    h.inbox({ type: 'config', payload: { enabled: false } });
    h.drainAll();
    tap.eq(h.run('$gameActors.actor(1)._name'), '黒ミューテ',
      'DP14 disable 后是日文剧情名（剧情入参覆盖了 sync 的数据原文）');
  }

  // DP15 —— 读档：存档里的 Game_Actor 不经过 setup，_name 是存档中的日文拷贝。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    tap.eq(h.run('$gameActors.actor(1)._name'), '缪特', 'DP15 新游戏基线：_name 中文');

    h.run("DataManager.extractSaveContents({ actors: [null, " +
      "{ _actorId: 1, _name: 'ミューテ', _nickname: 'ミューテ' }] })");
    tap.eq(h.run('$gameActors.actor(1)._name'), '缪特', 'DP15 读档后日文 _name 同步成中文');

    h.inbox({ type: 'config', payload: { enabled: false } });
    h.drainAll();
    tap.eq(h.run('$gameActors._data[1]._name'), 'ミューテ', 'DP15 disable 后读档角色的 _name 也还原');
  }

  // DP16 —— P1：账本只还原"我们写进去的那个值"。游戏后来自己改的名字不许被覆盖。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    h.run('DataManager.createGameObjects()');
    deliver(h);
    tap.eq(await waitFor(() => h.run('$gameActors.actor(1)._name') === '缪特'), true,
      'DP16 基线：sync 把已建角色的 _name 写成中文');

    h.run("$gameActors.actor(1).setName('勇者アレン')");
    tap.eq(h.run('$gameActors.actor(1)._name'), '勇者アレン', 'DP16 表里没有的名字由游戏原样写入');

    h.inbox({ type: 'config', payload: { enabled: false } });
    h.drainAll();
    tap.eq(h.run('$gameActors.actor(1)._name'), '勇者アレン',
      'DP16 关翻译不覆盖游戏改的名字（账本里更早的 缪特 不许写回）');
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP16 数据表仍按账本还原');
  }

  // DP17 —— P2：回写之后全文扫描必须拿日文原文（中文不许顶着"原文"进语料）。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    tap.eq(h.run('$dataStates[1].name'), '无法逃走', 'DP17 基线：数据表已是中文');

    const start = h.rpc('text.scanStart', { includeMaps: false, includeRuntime: false }).ack;
    tap.eq(!!start && start.ok === true, true, 'DP17 scanStart 返回 ok', JSON.stringify(start).slice(0, 200));
    const scanId = start && start.data ? start.data.scanId : null;
    const { events, done } = scanId ? await h.collectScan(scanId) : { events: [], done: null };
    const items = [];
    for (const envelope of events) {
      if (envelope.type === 'scanChunk' && Array.isArray(envelope.payload.items)) {
        items.push(...envelope.payload.items);
      }
    }
    const raws = items.map((item) => item && item.raw);
    tap.eq(!!done, true, 'DP17 scanDone 到达', 'scanId=' + scanId + ' items=' + items.length);
    tap.eq(['ミューテ', '逃走不可', 'は身を守っている。'].filter((raw) => raws.includes(raw)).length, 3,
      'DP17 扫描条目是被回写字段的日文原文', 'items=' + items.length);
    const polluted = raws.filter((raw) => raw === '缪特' || raw === '无法逃走' || raw === '正在保护自己。');
    tap.eq(polluted.length, 0, 'DP17 扫描条目里没有回写写入的中文', JSON.stringify(polluted));
  }

  // DP18 —— P3：无 segments 的译文带控制码时放弃回写（原文不含码）。
  // DP19 —— P7：回写查表不污染 mergeFallback（那是绘制路径的降级指标）。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    const before = h.probe().mergeFallback;
    // 两条都没有 segments → 走 lookup 出口 2（直接给 translatedRaw）。
    deliver(h, [
      { key: '逃走不可', translatedRaw: '\\c[27]无法逃走' },
      { key: 'ポーション', translatedRaw: '药水' }
    ]);
    const ok = await waitFor(() => h.run('$dataItems[1].name') === '药水');
    tap.eq(ok, true, 'DP18 同批里无控制码的译文照常回写（防御不过度）');
    tap.eq(h.run('$dataStates[1].name'), '逃走不可',
      'DP18 带控制码的译文不写进 $dataStates.name（不会被当字面量画出来）');
    tap.eq(stats(h).applied, 1, 'DP18 同批只有一条落盘');
    tap.eq(h.probe().mergeFallback, before,
      'DP19 回写查表不改 mergeFallback（' + before + '→' + h.probe().mergeFallback + '）');
  }

  // DP20 —— P4：install 自己也要排一次回写（uninstall 已把数据表还原、账本清空）。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    tap.eq(h.run('$dataActors[1].name'), '缪特', 'DP20 基线：数据已回写');

    h.run('window.__mochibox.uninstall()');
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP20 uninstall 后数据回到原文');
    tap.eq(h.run('$gameActors.actor(1)._name'), 'ミューテ', 'DP20 uninstall 后 _name 回到原文');

    h.run('window.__mochibox.install()');
    const ok = await waitFor(() => h.run('$dataActors[1].name') === '缪特');
    tap.eq(ok, true, 'DP20 重新 install 自己排期回写（不依赖 createGameObjects / 新译文）');
    tap.eq(h.run('$gameActors.actor(1)._name'), '缪特', 'DP20 重新 install 后 _name 也同步');
  }

  // DP21 —— P6：disable 保留剧情改名的账，re-enable 要能重新译回中文。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    h.run("$gameActors.actor(1).setName('黒ミューテ')");
    tap.eq(h.run('$gameActors.actor(1)._name'), '黑缪特', 'DP21 基线：剧情改名已译');

    h.inbox({ type: 'config', payload: { enabled: false } });
    h.drainAll();
    tap.eq(h.run('$gameActors.actor(1)._name'), '黒ミューテ', 'DP21 关翻译后是日文剧情名');
    tap.eq(stats(h).actorNames, 1, 'DP21 剧情改名的账保留（不清空）');

    h.inbox({ type: 'config', payload: { enabled: true } });
    h.drainAll();
    const ok = await waitFor(() => h.run('$gameActors.actor(1)._name') === '黑缪特');
    tap.eq(ok, true, 'DP21 重新开启后剧情名重新译回中文');
    tap.eq(h.run('$dataActors[1].name'), '缪特', 'DP21 数据表照常回写（剧情名不串到数据表）');
  }

  // DP22 —— 覆盖缺口：两个补装定时器（scheduleDataPatchHook 200ms / scheduleBattleLogHook 500ms）。
  // 可步进的 setInterval 桩触发，不烧真实时间。
  {
    const h = createHarness();           // 不装数据引擎，也不定义 Window_BattleLog
    h.drainAll();
    tap.eq(h.probe().hooks.includes('DataManager.createGameObjects'), false,
      'DP22 注入时 DataManager 尚不存在 → 数据 hook 没装上');
    tap.ok(h.pendingIntervals() >= 2, 'DP22 补装定时器已排期（数据 + 战斗日志）',
      'pending=' + h.pendingIntervals());

    h.run(`DataManager = {
      createGameObjects: function () {},
      extractSaveContents: function () {}
    };
    Game_Actor = function () {};
    Game_Actor.prototype.setName = function (name) { this._name = name; };
    Window_BattleLog = function () {};
    Window_BattleLog.prototype.drawTextEx = function (text) { return text; };`);

    h.tickIntervals(1);
    const hooks = h.probe().hooks;
    tap.eq(hooks.includes('DataManager.createGameObjects'), true, 'DP22 200ms 补装 createGameObjects');
    tap.eq(hooks.includes('DataManager.extractSaveContents'), true, 'DP22 200ms 补装 extractSaveContents');
    tap.eq(hooks.includes('Game_Actor.setName'), true, 'DP22 200ms 补装 Game_Actor.setName');
    tap.eq(hooks.includes('Window_BattleLog.drawTextEx'), true, 'DP22 500ms 补装 Window_BattleLog.drawTextEx');
    tap.eq(h.pendingIntervals(), 0, 'DP22 全部命中后定时器自行停掉');
    h.run('window.__mochibox.uninstall()');
  }

  // DP23 —— 总开关 dataPatchEnabled=false：一个字段都不写（Live2DInterfaceMZ 一类
  // 把 $dataArmors[].name 当服装动效表 key 的游戏靠它整块退场）。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    h.inbox({ type: 'config', payload: { dataPatchEnabled: false } });
    h.drainAll();
    tap.eq(h.probe().dataPatchEnabled, false, 'DP23 config 下发总开关关闭');

    deliver(h);
    h.run('DataManager.createGameObjects()');
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP23 关闭时 $dataActors.name 不写');
    tap.eq(h.run('$dataActors[1].nickname'), 'ミューテ', 'DP23 关闭时 nickname 不写');
    tap.eq(h.run('$dataStates[1].message3'), 'は身を守っている。', 'DP23 关闭时 message3 不写');
    tap.eq(h.run('$dataItems[1].description'), 'HPを50回復する', 'DP23 关闭时 description 不写');
    tap.eq(h.run('$dataArmors[1].name'), '旅人の服', 'DP23 关闭时装备名不写（插件的表 key）');
    tap.eq(h.run('$gameActors.actor(1)._name'), 'ミューテ', 'DP23 关闭时 Game_Actor._name 不翻');
    tap.eq(stats(h).applied, 0, 'DP23 账本为空（没有写入可还原）');

    h.run("$gameActors.actor(1).setName('黒ミューテ')");
    tap.eq(h.run('$gameActors.actor(1)._name'), '黒ミューテ',
      'DP23 关闭时 setName 直接透传（不查表、不记账）');
    tap.eq(stats(h).actorNames, 0, 'DP23 透传不留 _name 账');
  }

  // DP24 —— true → false：已写字段全部还原（含 _name），之后新译文也不写。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    tap.eq(h.run('$dataActors[1].name'), '缪特', 'DP24 基线：数据已回写');

    h.inbox({ type: 'config', payload: { dataPatchEnabled: false } });
    h.drainAll();
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP24 关闭后 $dataActors.name 还原');
    tap.eq(h.run('$dataActors[1].nickname'), 'ミューテ', 'DP24 关闭后 nickname 还原');
    tap.eq(h.run('$dataStates[1].name'), '逃走不可', 'DP24 关闭后状态 name 还原');
    tap.eq(h.run('$dataStates[1].message3'), 'は身を守っている。', 'DP24 关闭后 message3 还原');
    tap.eq(h.run('$dataItems[1].description'), 'HPを50回復する', 'DP24 关闭后 description 还原');
    tap.eq(h.run('$dataArmors[1].name'), '旅人の服', 'DP24 关闭后装备名还原');
    tap.eq(h.run('$gameActors.actor(1)._name'), 'ミューテ', 'DP24 关闭后 _name 还原（含）');
    tap.eq(stats(h).applied, 0, 'DP24 还原后账本清空');
  }

  // DP25 —— 子开关 dataPatchNames=false：name / nickname / _name 不写，
  // message / description / profile 照常写。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    h.inbox({ type: 'config', payload: { dataPatchNames: false } });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');

    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP25 name 不写');
    tap.eq(h.run('$dataActors[1].nickname'), 'ミューテ', 'DP25 nickname 不写');
    tap.eq(h.run('$dataActors[1].profile'), '缪特的个人资料', 'DP25 profile 照常写（不属于名字类）');
    tap.eq(h.run('$dataStates[1].name'), '逃走不可', 'DP25 状态 name 也不写（同一字段名一视同仁）');
    tap.eq(h.run('$dataStates[1].message3'), '正在保护自己。', 'DP25 message3 照常写');
    tap.eq(h.run('$dataStates[1].message4'), '被束缚着！', 'DP25 message4 照常写');
    tap.eq(h.run('$dataItems[1].description'), '回复50点HP', 'DP25 description 照常写');
    tap.eq(h.run('$dataArmors[1].name'), '旅人の服', 'DP25 装备名不写（Live2D 的表 key）');
    tap.eq(h.run('$gameActors.actor(1)._name'), 'ミューテ', 'DP25 _name 不翻');
    tap.eq(stats(h).actorNames, 0, 'DP25 没有 _name 账');

    h.run("$gameActors.actor(1).setName('黒ミューテ')");
    tap.eq(h.run('$gameActors.actor(1)._name'), '黒ミューテ', 'DP25 setName 透传');
    tap.eq(stats(h).applied > 0, true, 'DP25 非名字字段确实写进了一批', 'applied=' + stats(h).applied);
  }

  // DP26 —— true → false（子开关）：只还原名字类，message / description 保持中文。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    tap.eq(h.run('$dataActors[1].name'), '缪特', 'DP26 基线：名字已回写');
    const before = stats(h);

    h.inbox({ type: 'config', payload: { dataPatchNames: false } });
    h.drainAll();
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP26 子开关关闭后 name 还原');
    tap.eq(h.run('$dataActors[1].nickname'), 'ミューテ', 'DP26 nickname 还原');
    tap.eq(h.run('$dataStates[1].name'), '逃走不可', 'DP26 状态 name 还原');
    tap.eq(h.run('$dataWeapons[1].name'), '銅の剣', 'DP26 武器名还原');
    tap.eq(h.run('$gameActors.actor(1)._name'), 'ミューテ', 'DP26 _name 还原');
    tap.eq(h.run('$dataStates[1].message3'), '正在保护自己。', 'DP26 message3 保持中文（不整块还原）');
    tap.eq(h.run('$dataItems[1].description'), '回复50点HP', 'DP26 description 保持中文');
    tap.eq(h.run('$dataActors[1].profile'), '缪特的个人资料', 'DP26 profile 保持中文');
    tap.eq(stats(h).applied > 0 && stats(h).applied < before.applied, true,
      'DP26 只撤掉名字类账目，其余条目还在', 'applied ' + before.applied + '→' + stats(h).applied);
    tap.eq(stats(h).actorNames, 0, 'DP26 _name 账已清');

    // 再打开：名字类重新回写，非名字类不重复写（账还在）。
    h.inbox({ type: 'config', payload: { dataPatchNames: true } });
    const ok = await waitFor(() => h.run('$dataActors[1].name') === '缪特');
    tap.eq(ok, true, 'DP26 重新打开子开关后名字类恢复中文（走防抖）');
    tap.eq(h.run('$gameActors.actor(1)._name'), '缪特', 'DP26 重新打开后 _name 同步');
    tap.eq(stats(h).applied, before.applied, 'DP26 非名字字段没有被重写一遍',
      'applied=' + stats(h).applied + ' 基线=' + before.applied);
  }

  // DP27 —— 占位符守卫：原文 %1..%9 的多重集必须与译文完全一致，否则放弃回写。
  // 只在这个静默出口检查；正常绘制路径允许换顺序（这里用"顺序换了但多重集相同"做阳性对照）。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    h.run("$dataSkills.push({ id: 2, name: '%1の剣', description: '敵に%1のダメージ', " +
      "message1: 'は%1に%2のダメージを与えた！', note: '' })");
    deliver(h, [
      // 丢占位符：%1 → 无
      { key: '%1の剣', translatedRaw: '剑', segments: [{ kind: 'text', value: '剑' }] },
      // 多占位符：%1 → %1 %2
      { key: '敵に%1のダメージ', translatedRaw: '造成%1%2伤害',
        segments: [{ kind: 'text', value: '造成%1%2伤害' }] },
      // 多重集一致、顺序调换：允许
      { key: 'は%1に%2のダメージを与えた！', translatedRaw: '%2受到了%1的伤害！',
        segments: [{ kind: 'text', value: '%2受到了%1的伤害！' }] }
    ]);
    h.run('DataManager.createGameObjects()');

    tap.eq(h.run('$dataSkills[2].name'), '%1の剣', 'DP27 译文丢了 %1 → 不写（保持日文）');
    tap.eq(h.run('$dataSkills[2].description'), '敵に%1のダメージ', 'DP27 译文多出 %2 → 不写');
    tap.eq(h.run('$dataSkills[2].message1'), '%2受到了%1的伤害！',
      'DP27 占位符多重集一致（仅顺序不同）→ 正常写');
    tap.eq(stats(h).applied, 1, 'DP27 三条译文只有一条落盘');
  }

  // DP28 —— 开关切换的即时语义：打开走防抖、重复推送同一份 config 不产生额外还原/回写。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h);
    h.run('DataManager.createGameObjects()');
    const base = stats(h);

    h.inbox({ type: 'config', payload: { dataPatchEnabled: true, dataPatchNames: true } });
    h.inbox({ type: 'config', payload: { dataPatchEnabled: true, dataPatchNames: true } });
    h.drainAll();
    const same = stats(h);
    tap.eq([same.applied, same.batches, same.restored, same.actorNames],
      [base.applied, base.batches, base.restored, base.actorNames],
      'DP28 重复推送相同 config 不产生额外回写/还原', JSON.stringify({ base, same }));
    tap.eq(h.run('$dataActors[1].name'), '缪特', 'DP28 重复 config 后数据仍是中文');

    // 关：第一次真还原，第二次空转。
    h.inbox({ type: 'config', payload: { dataPatchEnabled: false } });
    h.drainAll();
    const off1 = stats(h);
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP28 切 false 立即还原');
    h.inbox({ type: 'config', payload: { dataPatchEnabled: false } });
    h.drainAll();
    const off2 = stats(h);
    tap.eq([off2.applied, off2.restored], [off1.applied, off1.restored],
      'DP28 重复推送 false 不重复还原', JSON.stringify({ off1, off2 }));

    // 开：不能同步直写（config 处理里扫整库），要等防抖。
    h.inbox({ type: 'config', payload: { dataPatchEnabled: true } });
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP28 切 true 后"立刻"仍是原文（走防抖，不是同步写）');
    const back = await waitFor(() => h.run('$dataActors[1].name') === '缪特');
    tap.eq(back, true, 'DP28 防抖回调落地后重新回写');
    tap.eq(h.run('$gameActors.actor(1)._name'), '缪特', 'DP28 重新打开后 _name 也补写');
  }

  // DP29 —— 切子开关不得吞掉「待落地的批次」：新译文刚到、300ms 防抖还没到就下发
  // dataPatchNames=false，非名字字段仍要补写（名字类由计划过滤掉）。
  {
    const h = createHarness({ data: true });
    h.drainAll();
    deliver(h, [{ key: 'は身を守っている。', translatedRaw: '正在保护自己。',
      segments: [{ kind: 'text', value: '正在保护自己。' }] }]);
    h.inbox({ type: 'config', payload: { dataPatchNames: false } });   // 防抖窗口内
    const ok = await waitFor(() => h.run('$dataStates[1].message3') === '正在保护自己。');
    tap.eq(ok, true, 'DP29 切子开关不会吞掉未落地的非名字字段');
    tap.eq(h.run('$dataActors[1].name'), 'ミューテ', 'DP29 名字类仍不写');
  }
});
