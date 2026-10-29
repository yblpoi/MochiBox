/*
 * harness.mjs —— Contract 层共用的 Node `vm` 沙箱。
 *
 * 三种形态（都由这一份实现产出，避免"夹具两份、行为各异"）：
 *   · fixture：把 `Fixtures/mv_stub/index.html` 的内联脚本原样跑起来（真 `$game*` / `$data*`），
 *              用于 rpc / cheat / scan 的语义断言；
 *   · stub：只给最小绘制面（Bitmap / Window_Base / Window_Message，可选 Window_BattleLog），
 *           用于注入幂等、信封协议、分句与去重 —— 这些用例不需要假引擎，越小越不容易被夹具行为干扰；
 *   · bare：同 stub，但没有 `$game*` / `$data*`，用于"游戏尚未进入场景"的降级路径。
 *
 * 时钟一律注入（`performance.now` + `Date`），用例显式步进：
 * 采集抑制窗口、Store 的 800ms 判据都靠它，绝不读真实时间。
 *
 * 不读网络、不读 `~/Library`、不写磁盘。
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

export const REPO_ROOT = path.resolve(fileURLToPath(new URL('../../..', import.meta.url)));
export const AGENT_PATH = path.join(REPO_ROOT, 'Resources/agent_mvmz.js');
export const FIXTURE_PATH = path.join(REPO_ROOT, 'Fixtures/mv_stub/index.html');

/** 可步进时钟。所有断言只依赖它，因此同一命令跑两次结果逐字节一致。 */
export function createClock(start = 1_000_000) {
  let value = start;
  return {
    now: () => value,
    advance(ms) { value += ms; return value; },
    set(ms) { value = ms; return value; }
  };
}

/**
 * 可步进的 setInterval 桩：只**登记**回调，绝不自动触发。
 *
 * 现有用例依赖"不触发"的语义（替身页的 400ms 重绘循环、媒体的 500ms 轮询、Agent 的
 * 200ms/500ms 补装），所以默认行为与旧的 `() => 0` 完全一致；需要补装定时器的用例
 * 显式调 `h.tickIntervals(n)` 步进。真实等待仍走 setTimeout（见 waitFor）。
 */
export function createIntervals() {
  const timers = new Map();
  let seq = 0;
  return {
    setInterval(fn) { seq += 1; timers.set(seq, fn); return seq; },
    clearInterval(id) { timers.delete(id); },
    /** 跑 n 轮：每轮把当前在册的回调各调一次（回调自己 clearInterval 的下一轮就没了）。 */
    tick(n = 1) {
      for (let round = 0; round < n; round++) {
        for (const fn of Array.from(timers.values())) {
          try { fn(); } catch (e) { /* 补装回调抛异常不该打断用例 */ }
        }
      }
    },
    pending: () => timers.size
  };
}

/** 2d 上下文替身：绘制调用不报错即可（本层不验像素）。 */
function makeContext2d() {
  return new Proxy({}, {
    get(target, property) {
      if (property === 'measureText') { return () => ({ width: 10 }); }
      return () => {};
    },
    set() { return true; }
  });
}

/**
 * 记录一次绘制调用。`fontSize` 取**真正执行绘制那一层**的字号：
 *   · Bitmap.drawText → 自己的 `this.fontSize`；
 *   · Window_Base.drawText/drawTextEx → `this.contents.fontSize`（RM 的绘制面就在这里读字号）。
 * 只读值、不改行为：Agent 的 hook 若在调用前改了字号，这里量到的就是改后的值。
 */
function recordDraw(captured, fn, receiver, text) {
  if (!captured) { return; }
  const holder = (receiver && receiver.contents) ? receiver.contents : receiver;
  captured.value = String(text);
  captured.fn = fn;
  captured.fontSize = (holder && typeof holder.fontSize === 'number') ? holder.fontSize : null;
  captured.calls.push({ fn, text: String(text), fontSize: captured.fontSize });
}

/**
 * 数据回写用例用的最小数据库（**默认不装**）。
 *
 * 结构与 MV/MZ 同形，只为三件事存在：
 *   · 白名单字段有日文原文可翻；
 *   · note / meta 带 `<STATE_HELP>` 与 `hzExState_*`，用来钉死"逐字节不变"；
 *   · `DataManager.createGameObjects` 在**函数体第一行**就快照 `$dataActors[1].name` 与
 *     `$dataStates[1].message3` —— 这是"名字与 message 同批生效"的唯一客观现场。
 */
function installDataEngine(sandbox) {
  const dataActors = [null,
    { id: 1, name: 'ミューテ', nickname: 'ミューテ', profile: 'ミューテのプロフィール',
      note: '', meta: {} },
    { id: 2, name: 'リリス', nickname: 'リリス', profile: 'リリスのプロフィール',
      note: '', meta: {} }
  ];
  const dataStates = [null,
    { id: 1, name: '逃走不可', message1: '', message2: '',
      message3: 'は身を守っている。', message4: 'は拘束されている！',
      note: '<STATE_HELP:1:98:抵抗不能>拘束状態</STATE_HELP>',
      meta: { hzExState_auto: 1, hzExState_text: '拘束' } },
    // 删条目后留下的洞：回写必须跳过而不是抛异常。
    null
  ];
  const dataSkills = [null,
    { id: 1, name: '強撃', description: '敵単体に大打撃を与える', message1: 'は強撃を放った！',
      message2: 'に大打撃を与えた！', note: '', meta: {} }
  ];
  const dataItems = [null,
    { id: 1, name: 'ポーション', description: 'HPを50回復する', note: '' }
  ];
  const dataWeapons = [null,
    { id: 1, name: '銅の剣', description: 'ありふれた片手剣', note: '' }
  ];
  const dataArmors = [null,
    { id: 1, name: '旅人の服', description: '動きやすい上着', note: '' }
  ];
  const dataClasses = [null,
    { id: 1, name: '剣士', note: '前衛で戦う' }
  ];
  const dataEnemies = [null,
    { id: 1, name: 'スライム', note: '' }
  ];

  const snapshots = { calls: 0, actorName: null, stateMessage3: null };

  function Game_Actors() { this._data = []; }
  Game_Actors.prototype.actor = function (actorId) {
    if (!this._data[actorId] && sandbox.$dataActors[actorId]) {
      this._data[actorId] = new Game_Actor(actorId);
    }
    return this._data[actorId] || null;
  };
  function Game_Actor(actorId) { this.setup(actorId); }
  Game_Actor.prototype.setup = function (actorId) {
    // 与 rpg_objects.js:3435 同形：名字是 $dataActors[].name 的**拷贝**。
    const actor = sandbox.$dataActors[actorId];
    this._actorId = actorId;
    this._name = actor.name;
    this._nickname = actor.nickname;
  };
  Game_Actor.prototype.name = function () { return this._name; };
  Game_Actor.prototype.setName = function (name) { this._name = name; };
  Game_Actor.prototype.actorId = function () { return this._actorId; };

  sandbox.DataManager = {
    createGameObjects: function () {
      snapshots.calls += 1;
      // 快照必须在建对象之前取：Agent 的回写包装应该在原函数之前完成。
      snapshots.actorName = sandbox.$dataActors[1] ? sandbox.$dataActors[1].name : null;
      snapshots.stateMessage3 = sandbox.$dataStates[1] ? sandbox.$dataStates[1].message3 : null;
      sandbox.$gameActors = new Game_Actors();
    },
    // 与 rpg_managers.js 同形：读档把存档里的 Game_Actor **直接灌进** _data，
    // 不经过 setup，所以 _name 是存档里的拷贝。
    extractSaveContents: function (contents) {
      sandbox.$gameActors = new Game_Actors();
      sandbox.$gameActors._data = contents.actors;
    }
  };
  sandbox.Game_Actor = Game_Actor;
  sandbox.Game_Actors = Game_Actors;
  sandbox.$dataActors = dataActors;
  sandbox.$dataClasses = dataClasses;
  sandbox.$dataSkills = dataSkills;
  sandbox.$dataItems = dataItems;
  sandbox.$dataWeapons = dataWeapons;
  sandbox.$dataArmors = dataArmors;
  sandbox.$dataEnemies = dataEnemies;
  sandbox.$dataStates = dataStates;
  sandbox.__dataStub = {
    dataActors, dataClasses, dataSkills, dataItems,
    dataWeapons, dataArmors, dataEnemies, dataStates, snapshots
  };
}

/**
 * 最小绘制面：足以让 Agent 装上四个 hook，但不带任何 `$game*`。
 *
 * `battleLog`：`'own'` = `Window_BattleLog.prototype` 自带 `drawTextEx`（模拟
 * `NRP_WindowBattleLogLayout`）；`'inherit'` = 不定义、继承 `Window_Base` 的版本。
 * `data`：装上 `$data*` + `DataManager` + `Game_Actor`（见 `installDataEngine`）。
 */
function installMinimalEngine(sandbox, captured, throwing, battleLog, data) {
  function Bitmap() { this.fontSize = 24; this.fontFace = 'x'; }
  // 与 MV 真源同型：字体名由 _makeFontNameText 拼（Agent 会重写它来注入中文字体链）。
  Bitmap.prototype._makeFontNameText = function () {
    return (this.fontItalic ? 'italic ' : '') + this.fontSize + 'px ' + this.fontFace;
  };
  Bitmap.prototype.drawText = function (text) {
    if (throwing) { throw new Error('game bug'); }
    recordDraw(captured, 'Bitmap.drawText', this, text);
    return true;
  };
  function Window_Base() { this.contents = new Bitmap(); }
  Window_Base.prototype.drawText = function (text) {
    if (throwing) { throw new Error('game bug'); }
    recordDraw(captured, 'Window_Base.drawText', this, text);
    return true;
  };
  Window_Base.prototype.drawTextEx = function (text) {
    if (throwing) { throw new Error('game bug'); }
    recordDraw(captured, 'Window_Base.drawTextEx', this, text);
    return true;
  };
  Window_Base.prototype.refresh = function () {};
  function Window_Message() { Window_Base.call(this); }
  Window_Message.prototype = Object.create(Window_Base.prototype);
  Window_Message.prototype.constructor = Window_Message;
  Window_Message.prototype.startMessage = function () { return true; };
  if (battleLog) {
    function Window_BattleLog() { Window_Base.call(this); }
    Window_BattleLog.prototype = Object.create(Window_Base.prototype);
    Window_BattleLog.prototype.constructor = Window_BattleLog;
    if (battleLog === 'own') {
      // 与 NRP_WindowBattleLogLayout 同形：自己逐字 processCharacter，最终落到
      // `contents.drawText`，不经过 `Window_Base.prototype.drawTextEx`。
      Window_BattleLog.prototype.drawTextEx = function (text) {
        if (throwing) { throw new Error('game bug'); }
        this.contents.drawText(text, 0, 0);
        return true;
      };
    }
    sandbox.Window_BattleLog = Window_BattleLog;
  }

  sandbox.Bitmap = Bitmap;
  sandbox.Window_Base = Window_Base;
  sandbox.Window_Message = Window_Message;
  sandbox.SceneManager = { _scene: { constructor: { name: 'Scene_Map' } } };
  sandbox.$gameMessage = { _texts: [] };
  if (data) { installDataEngine(sandbox); }
  return { Bitmap, Window_Base, Window_Message };
}

/**
 * 造一个沙箱并注入 Agent。
 *
 * @param {{ fixture?: boolean, capture?: boolean, clock?: object, agentPath?: string }} options
 * @returns 见文件末尾的返回对象
 */
export function createHarness(options = {}) {
  const {
    fixture = false,
    capture = false,
    throwing = false,
    battleLog = null,
    data = false,
    clock = createClock(),
    agentPath = AGENT_PATH
  } = options;

  let sandbox;
  const captured = capture ? { value: null, fn: null, fontSize: null, calls: [] } : null;
  const intervals = createIntervals();

  if (fixture) {
    const html = fs.readFileSync(FIXTURE_PATH, 'utf8');
    const matched = /<script>([\s\S]*)<\/script>/.exec(html);
    if (!matched) { throw new Error(FIXTURE_PATH + ' 里没有 <script> 块'); }
    const canvas = { width: 816, height: 400, getContext: () => makeContext2d() };
    sandbox = {
      console,
      setTimeout,
      clearTimeout,
      // 夹具的 400ms 重绘循环在探针里关掉：需要重绘时显式调 `__stubRepaint()`。
      setInterval: intervals.setInterval,
      clearInterval: intervals.clearInterval,
      document: { getElementById: () => canvas },
      performance: { now: () => clock.now() },
      navigator: { userAgent: 'e2e-contract' },
      location: { href: 'file:///e2e/contract/index.html' }
    };
    sandbox.window = sandbox;
    sandbox.global = sandbox;
    installDateProxy(sandbox, clock);
    vm.createContext(sandbox);
    vm.runInContext(matched[1], sandbox, { filename: FIXTURE_PATH });
  } else {
    sandbox = {
      console,
      setTimeout,
      clearTimeout,
      setInterval: intervals.setInterval,
      clearInterval: intervals.clearInterval,
      performance: { now: () => clock.now() },
      navigator: { userAgent: 'e2e-contract' },
      location: { href: 'file:///e2e/contract/index.html' }
    };
    sandbox.window = sandbox;
    sandbox.global = sandbox;
    installDateProxy(sandbox, clock);
    installMinimalEngine(sandbox, captured, throwing, battleLog, data);
    vm.createContext(sandbox);
  }

  const agentCode = fs.readFileSync(agentPath, 'utf8');
  vm.runInContext(agentCode, sandbox, { filename: agentPath });

  function run(expression) {
    return vm.runInContext(expression, sandbox, { filename: 'e2e-inline' });
  }

  if (!sandbox.__mochibox || typeof sandbox.__mochibox.version !== 'number') {
    throw new Error('agent 未安装：window.__mochibox 不可用（' + agentPath + '）');
  }

  function inbox(message) {
    const json = (typeof message === 'string') ? message : JSON.stringify(message);
    run('window.__mochibox.inbox(' + JSON.stringify(json) + ')');
  }

  function drain() {
    const raw = run('window.__mochibox.drain()');
    if (typeof raw !== 'string' || raw === '') { return []; }
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      return [];
    }
  }

  function drainAll(maxBatches = 80) {
    const all = [];
    for (let i = 0; i < maxBatches; i++) {
      const batch = drain();
      if (batch.length === 0) { break; }
      all.push(...batch);
    }
    return all;
  }

  let rpcSeq = 0;

  /** 同步 rpc：Agent 的 handler 若返回 Promise，用 rpcWait。 */
  function rpc(method, args = {}) {
    const id = 'e2e-' + (++rpcSeq);
    inbox({ type: 'rpc', payload: { id, method, args } });
    const events = drainAll();
    const hit = events.find((envelope) => envelope && envelope.type === 'rpcResult' &&
      envelope.payload && envelope.payload.id === id);
    return { id, ack: hit ? hit.payload : null, events };
  }

  async function rpcWait(method, args = {}, timeoutMs = 5000) {
    const id = 'e2e-' + (++rpcSeq);
    inbox({ type: 'rpc', payload: { id, method, args } });
    const collected = [];
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      for (const envelope of drainAll(8)) {
        collected.push(envelope);
        if (envelope && envelope.type === 'rpcResult' && envelope.payload && envelope.payload.id === id) {
          return { id, ack: envelope.payload, events: collected };
        }
      }
      await sleep(5);
    }
    return { id, ack: null, events: collected };
  }

  async function collectScan(scanId, timeoutMs = 20000, seed = []) {
    const events = [];
    let done = null;
    for (const envelope of seed) {
      if (!envelope || !envelope.payload || envelope.payload.scanId !== scanId) { continue; }
      events.push(envelope);
      if (envelope.type === 'scanDone') { done = envelope.payload; }
    }
    const deadline = Date.now() + timeoutMs;
    while (!done && Date.now() < deadline) {
      for (const envelope of drainAll(8)) {
        if (!envelope || !envelope.payload || envelope.payload.scanId !== scanId) { continue; }
        events.push(envelope);
        if (envelope.type === 'scanDone') { done = envelope.payload; }
      }
      if (done) { break; }
      await sleep(8);
    }
    return { events, done };
  }

  return {
    sandbox,
    clock,
    run,
    inbox,
    drain,
    drainAll,
    rpc,
    rpcWait,
    collectScan,
    now: () => clock.now(),
    advance: (ms) => clock.advance(ms),
    setNow: (ms) => clock.set(ms),
    /** 步进 setInterval 桩（补装定时器）。默认不触发，现有用例行为不变。 */
    tickIntervals: (n = 1) => { intervals.tick(n); return intervals.pending(); },
    /** 在册的 interval 回调数（断言"补装定时器已排期"）。 */
    pendingIntervals: () => intervals.pending(),
    /** 画一行（走 Window_Base.drawTextEx 的 hook 路径）。 */
    draw(raw) {
      if (captured) { captured.value = null; captured.fontSize = null; }
      run('new Window_Base().drawTextEx(' + JSON.stringify(raw) + ', 0, 0)');
      return captured ? captured.value : null;
    },
    /** 直接画 Bitmap.drawText（不同 surface）。 */
    drawBitmap(raw) {
      if (captured) { captured.value = null; captured.fontSize = null; }
      run('(new Window_Base()).contents.drawText(' + JSON.stringify(raw) + ', 0, 0)');
      return captured ? captured.value : null;
    },
    /** 画一行战斗日志（走 Window_BattleLog.prototype.drawTextEx）。 */
    drawBattleLog(raw) {
      if (captured) { captured.value = null; captured.fontSize = null; }
      run('new Window_BattleLog().drawTextEx(' + JSON.stringify(raw) + ', 0, 0)');
      return captured ? captured.value : null;
    },
    lastDraw: () => (captured ? captured.value : null),
    /** 上一次绘制**真正到达绘制层时**的字号（P0-15 的唯一客观量）。 */
    lastFontSize: () => (captured ? captured.fontSize : null),
    /** 全部绘制调用（含 surface 名），按发生顺序。 */
    drawCalls: () => (captured ? captured.calls.slice() : []),
    resetCalls() { if (captured) { captured.calls.length = 0; } },
    emit(type, payload) {
      run('window.__mochibox.emit(' + JSON.stringify(type) + ',' + JSON.stringify(payload || {}) + ')');
    },
    requeue(items) {
      const json = JSON.stringify(Array.isArray(items) ? JSON.stringify(items) : items);
      const raw = run('window.__mochibox.requeue(' + json + ')');
      try { return JSON.parse(raw); } catch (e) { return null; }
    },
    probe() { return JSON.parse(run('window.__mochibox.probe()')); },
    state() { return JSON.parse(run('JSON.stringify(window.__mochibox.state)')); },
    version: () => run('window.__mochibox.version'),
    caps: () => JSON.parse(run('JSON.stringify(window.__mochibox.caps)'))
  };
}

function installDateProxy(sandbox, clock) {
  const RealDate = Date;
  sandbox.Date = new Proxy(RealDate, {
    construct(target, args) { return new target(...(args.length ? args : [clock.now()])); },
    get(target, property) {
      if (property === 'now') { return () => clock.now(); }
      return Reflect.get(target, property);
    }
  });
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
