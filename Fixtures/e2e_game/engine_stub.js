/*
 * engine_stub.js —— E2E 夹具的**假 MZ 运行时**（不是引擎，也不追求兼容）。
 *
 * 只实现 agent_mvmz.js 会 hook 的四面 + cheat / text.scan 需要的 $game* / $data*：
 *   Bitmap.drawText / Window_Base.drawText / Window_Base.drawTextEx / Window_Message.startMessage
 *
 * 三条刻意的设计：
 *   1) startMessage **不调用** drawTextEx。真实 MZ 在这里准备分页，绘制发生在 update 里；
 *      夹具若在这里再走一次 drawTextEx，同一句会被两个 surface 各采一次，E2E 计数就没法判定。
 *   2) __stubRepaint() 直接写 canvas 上下文，**不经过任何被 hook 的函数**：
 *      它只模拟"屏幕刷新"，绝不产生新的 TextEvent。
 *   3) 所有状态都是进程内常量：无网络、无随机、无定时器。同一串输入 → 同一串输出。
 */
(function (global) {
  'use strict';

  var VERSION = 1;
  var FONT_FACE = '"Hiragino Sans", "Noto Sans CJK JP", sans-serif';
  var canvas = document.getElementById('game');
  var ctx = canvas ? canvas.getContext('2d') : null;

  // ---------- 绘制记录（E2E 的"屏幕上到底画了什么"）----------
  // 只记**消息窗**（Window_Message 实例）经 Window_Base.drawText/drawTextEx 的绘制调用：
  // 采集断言看的是 Agent 上报（$gameMessage._texts），与消息窗是否真的画了无关；
  // 这两条记录必须分开，否则"消息窗不绘制"这种故障在内核层零反应（H2）。
  //
  // fontSize 取 `this.contents.fontSize`：Agent 的 drawText/drawTextEx wrapper 在调基类前
  // 按 fontScale 改这个值、调用后还原，所以这里量到的就是**真正落到绘制层**的字号。
  var drawLog = [];
  var DRAW_LOG_LIMIT = 200;
  var drawTotal = 0;

  function recordMessageDraw(kind, receiver, text, x, y) {
    try {
      var holder = receiver && receiver.contents;
      drawTotal += 1;
      drawLog.push({
        kind: kind,
        text: String(text == null ? '' : text),
        fontSize: (holder && typeof holder.fontSize === 'number') ? holder.fontSize : null,
        x: x || 0,
        y: y || 0
      });
      if (drawLog.length > DRAW_LOG_LIMIT) { drawLog.shift(); }
    } catch (e) { /* 记录失败不能影响绘制 */ }
  }

  // ---------- 控制码（夹具只负责"画得像"）----------
  // 真实引擎在绘制时吞掉 \C[2] 这类码；Agent 不吞（它要保留原文身份）。
  function stripControlCodes(text) {
    var input = String(text == null ? '' : text);
    var out = '';
    var i = 0;
    var single = '{}|!.$><^\\G';
    while (i < input.length) {
      var ch = input.charAt(i);
      if (ch === '\\' && i + 1 < input.length) {
        var rest = input.slice(i);
        var bracket = /^\\[A-Za-z]{1,2}\[[^\]]*\]/.exec(rest);
        if (bracket) { i += bracket[0].length; continue; }
        if (single.indexOf(input.charAt(i + 1)) >= 0) { i += 2; continue; }
      }
      out += ch;
      i += 1;
    }
    return out;
  }

  // ---------- Bitmap / Window ----------
  function Bitmap(width, height) {
    this.width = width || 0;
    this.height = height || 0;
    this.fontSize = 28;
    this.fontFace = FONT_FACE;
    this.textColor = '#ffffff';
    this._lines = [];
  }
  /// 与 MV 真源（rpg_core.js:1521）同型：Agent 会重写它来注入中文字体链。
  Bitmap.prototype._makeFontNameText = function () {
    return (this.fontItalic ? 'italic ' : '') + this.fontSize + 'px ' + this.fontFace;
  };
  Bitmap.prototype.measureTextWidth = function (text) {
    if (!ctx) { return stripControlCodes(text).length * 14; }
    ctx.font = this._makeFontNameText();
    return ctx.measureText(stripControlCodes(text)).width;
  };
  Bitmap.prototype.drawText = function (text, x, y, maxWidth, lineHeight, align) {
    var display = stripControlCodes(text);
    var left = x || 0;
    var top = y || 0;
    if (ctx) {
      ctx.font = this._makeFontNameText();
      ctx.fillStyle = this.textColor;
      var width = ctx.measureText(display).width;
      if (align === 'center') { left = (x || 0) + ((maxWidth || width) - width) / 2; }
      else if (align === 'right') { left = (x || 0) + (maxWidth || width) - width; }
      ctx.fillText(display, left, top + this.fontSize);
    }
    this._lines.push({ text: display, x: left, y: top, lineHeight: lineHeight || this.fontSize });
    return true;
  };
  Bitmap.prototype.clear = function () { this._lines = []; };

  function Window_Base() {
    this.contents = new Bitmap(Graphics.boxWidth, Graphics.boxHeight);
    this.openness = 255;
    this.active = true;
  }
  Window_Base.prototype.drawText = function (text, x, y, maxWidth, lineHeight, align) {
    // 只有消息窗的绘制计入 drawLog：其它 Window_* 的字幕/菜单不参与 K12 的判据。
    if (this instanceof Window_Message) { recordMessageDraw('drawText', this, text, x, y); }
    return this.contents.drawText(text, x || 0, y || 0, maxWidth, lineHeight, align);
  };
  Window_Base.prototype.drawTextEx = function (text, x, y) {
    if (this instanceof Window_Message) { recordMessageDraw('drawTextEx', this, text, x, y); }
    return this.contents.drawText(text, x || 0, y || 0) ? 36 : 0;
  };
  Window_Base.prototype.refresh = function () { return true; };
  Window_Base.prototype.close = function () { this.openness = 0; };

  function Window_Message() {
    Window_Base.call(this);
    this._texts = [];
  }
  Window_Message.prototype = Object.create(Window_Base.prototype);
  Window_Message.prototype.constructor = Window_Message;
  /// 真实 MZ 的 startMessage 负责分页与状态准备；**绘制在 update 里发生**。
  Window_Message.prototype.startMessage = function () {
    var texts = (global.$gameMessage && global.$gameMessage._texts) || [];
    this._texts = texts.slice();
    this.openness = 255;
    return true;
  };

  // ---------- 场景 ----------
  function Scene_Base() {}
  Scene_Base.prototype.update = function () {};
  function Scene_Map() {
    Scene_Base.call(this);
    this._messageWindow = null;
    this._windowLayer = { children: [] };
  }
  Scene_Map.prototype = Object.create(Scene_Base.prototype);
  Scene_Map.prototype.constructor = Scene_Map;
  function Scene_Boot() { Scene_Base.call(this); }
  Scene_Boot.prototype = Object.create(Scene_Base.prototype);
  Scene_Boot.prototype.constructor = Scene_Boot;
  function Scene_Menu() { Scene_Base.call(this); }
  Scene_Menu.prototype = Object.create(Scene_Base.prototype);
  Scene_Menu.prototype.constructor = Scene_Menu;
  function Scene_Battle() { Scene_Base.call(this); }
  Scene_Battle.prototype = Object.create(Scene_Base.prototype);
  Scene_Battle.prototype.constructor = Scene_Battle;

  function instantiate(scene) {
    if (typeof scene === 'function') { return new scene(); }
    var named = global[String(scene)];
    return (typeof named === 'function') ? new named() : new Scene_Map();
  }

  var SceneManager = {
    _scene: null,
    _stack: [],
    goto: function (scene) { this._scene = instantiate(scene); return this._scene; },
    push: function (scene) {
      if (this._scene) { this._stack.push(this._scene); }
      this._scene = instantiate(scene);
      return this._scene;
    },
    pop: function () { this._scene = this._stack.pop() || new Scene_Map(); return this._scene; },
    isSceneActive: function (scene) {
      if (!this._scene) { return false; }
      if (typeof scene === 'function') { return this._scene instanceof scene; }
      return this._scene.constructor.name === String(scene);
    }
  };

  var Graphics = { boxWidth: 816, boxHeight: 624, width: 816, height: 624, frameCount: 0 };

  // ---------- 数据表（只放到 cheat 用得到的大小）----------
  var switchNames = [null];
  var variableNames = [null];
  for (var n = 1; n <= 20; n++) { switchNames.push('スイッチ' + n); variableNames.push('変数' + n); }
  var dataSystem = {
    gameTitle: 'E2E Fixture', locale: 'ja_JP', currencyUnit: 'G', versionId: 1,
    switches: switchNames, variables: variableNames, terms: { basic: ['レベル', 'Lv'] }
  };
  var dataActors = [null,
    { id: 1, name: 'アルス', nickname: '勇者', profile: 'E2E 用アクター', classId: 1 },
    { id: 2, name: 'ミナ', nickname: '賢者', profile: 'E2E 用アクター', classId: 2 }];
  var dataItems = [null,
    { id: 1, name: 'ポーション', description: 'HPを少し回復する', price: 50, consumable: true },
    { id: 2, name: 'エーテル', description: 'MPを少し回復する', price: 80, consumable: true }];
  var dataWeapons = [null, { id: 1, name: 'ロングソード', description: '使いやすい剣', price: 300 }];
  var dataArmors = [null, { id: 1, name: '革の鎧', description: '軽い鎧', price: 200 }];
  var dataMap = { displayName: 'E2E Map', width: 2, height: 2, note: '', tilesetId: 1, data: [0, 0, 0, 0], events: [null] };

  // ---------- 游戏状态 ----------
  function Game_Switches() { this._data = [false]; }
  Game_Switches.prototype.value = function (id) { return !!this._data[id]; };
  Game_Switches.prototype.setValue = function (id, value) { this._data[id] = !!value; };
  function Game_Variables() { this._data = [0]; }
  Game_Variables.prototype.value = function (id) { return this._data[id]; };
  Game_Variables.prototype.setValue = function (id, value) { this._data[id] = value; };
  function Game_SelfSwitches() { this._data = {}; }
  Game_SelfSwitches.prototype.value = function (key) { return !!this._data[String(key)]; };
  Game_SelfSwitches.prototype.setValue = function (key, value) { this._data[String(key)] = !!value; };

  var gameSwitches = new Game_Switches();
  var gameVariables = new Game_Variables();
  var gameSelfSwitches = new Game_SelfSwitches();

  var gameActors = {
    _data: {},
    actor: function (id) {
      if (!this._data[id]) {
        var data = dataActors[id];
        if (!data) { return null; }
        this._data[id] = {
          actorId: id, _name: data.name, _nickname: data.nickname, _level: 1, _hp: 100, _mp: 20,
          name: function () { return this._name; },
          nickname: function () { return this._nickname; },
          level: function () { return this._level; },
          hp: function () { return this._hp; },
          mp: function () { return this._mp; },
          param: function () { return 10; },
          changeHp: function (value) { this._hp = value; },
          changeMp: function (value) { this._mp = value; }
        };
      }
      return this._data[id];
    }
  };

  function Game_Party() {
    this._gold = 0;
    this._actors = [1];
    this._items = {};
    this._weapons = {};
    this._armors = {};
  }
  Game_Party.prototype.gold = function () { return this._gold; };
  Game_Party.prototype.gainGold = function (amount) { this._gold = Math.max(0, this._gold + (Number(amount) || 0)); };
  Game_Party.prototype.members = function () {
    var list = [];
    for (var i = 0; i < this._actors.length; i++) {
      var actor = gameActors.actor(this._actors[i]);
      if (actor) { list.push(actor); }
    }
    return list;
  };
  Game_Party.prototype.allItems = function () {
    var list = [];
    function collect(table, bag, type) {
      for (var key in bag) {
        if (!Object.prototype.hasOwnProperty.call(bag, key)) { continue; }
        var data = table[Number(key)];
        if (data) { list.push({ item: data, count: bag[key], type: type }); }
      }
    }
    collect(dataItems, this._items, 'item');
    collect(dataWeapons, this._weapons, 'weapon');
    collect(dataArmors, this._armors, 'armor');
    return list;
  };

  var gameParty = new Game_Party();
  var gameMessage = {
    _texts: [],
    _choiceCancelType: 0,
    clear: function () { this._texts = []; },
    newPage: function () { this._texts = []; },
    add: function (text) { this._texts.push(String(text)); },
    hasText: function () { return this._texts.length > 0; }
  };
  var gameMap = {
    _mapId: 1,
    displayName: function () { return dataMap.displayName; },
    events: function () { return dataMap.events; },
    event: function (id) { return dataMap.events[id] || null; }
  };
  var gamePlayer = { _x: 0, _y: 0, _direction: 2, _through: false };
  var BattleManager = { _phase: 'start', isBattle: function () { return false; }, setup: function () { return true; }, update: function () { return true; } };
  var gameSystem = { _locale: 'ja_JP', versionId: 1, isJapanese: function () { return true; } };

  // ---------- 绘制（不经过 hook）----------
  var messageWindow = new Window_Message();
  var mapScene = new Scene_Map();
  mapScene._messageWindow = messageWindow;
  mapScene._windowLayer.children.push(messageWindow);
  SceneManager._scene = mapScene;

  var lastPainted = [];
  var lastRendered = [];
  function repaint() {
    if (!ctx) { return false; }
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#101418';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    var scene = SceneManager._scene;
    var win = scene && (scene._messageWindow || (scene._windowLayer && scene._windowLayer.children[0]));
    var lines = win ? win._texts : (gameMessage._texts || []);
    lastPainted = [];
    for (var i = 0; i < lines.length; i++) {
      var display = stripControlCodes(lines[i]);
      ctx.font = '28px ' + FONT_FACE;
      ctx.fillStyle = '#ffffff';
      ctx.fillText(display, 24, 64 + i * 40);
      lastPainted.push(display);
    }
    Graphics.frameCount += 1;
    return true;
  }

  // ---------- 测试驱动 API ----------
  var e2e = {
    version: VERSION,
    /// install() 之前的原始函数引用。K8 用它判定 uninstall() 是否真的把原型还回去了。
    originals: {
      startMessage: Window_Message.prototype.startMessage,
      drawTextEx: Window_Base.prototype.drawTextEx,
      drawText: Window_Base.prototype.drawText,
      bitmapDrawText: Bitmap.prototype.drawText
    },
    push: function (text) { return e2e.pushMany([text]); },
    pushMany: function (list) {
      var texts = [];
      for (var i = 0; i < list.length; i++) { texts.push(String(list[i])); }
      gameMessage._texts = texts;
      Window_Message.prototype.startMessage.call(messageWindow);
      repaint();
      return true;
    },
    /// 把第 index 行换成 text 后重新分页（其余行保持原样）。
    pushAt: function (index, text) {
      var at = Math.max(0, Math.floor(Number(index) || 0));
      while (gameMessage._texts.length < at) { gameMessage._texts.push(''); }
      gameMessage._texts[at] = String(text);
      Window_Message.prototype.startMessage.call(messageWindow);
      repaint();
      return true;
    },
    /// 直接走 Window_Base.drawTextEx（第二个采集 surface）。
    drawTextEx: function (text) { new Window_Base().drawTextEx(String(text), 0, 0); return true; },
    /// 直接走 Bitmap.drawText（第三个采集 surface）。
    drawBitmap: function (text) { (new Window_Base()).contents.drawText(String(text), 0, 0); return true; },
    /// 消息窗真的画一次（等价于玩家在译文就绪后重新看到同一页）。
    ///
    /// 顺序与真实引擎一致：**先**重新分页（Agent 的 startMessage hook 会把已缓存的译文
    /// 写回 `$gameMessage._texts`，基类再拷进 `this._texts`），**再**逐行走消息窗的
    /// drawTextEx。绘制必须经过被 Agent hook 的 Window_Base 面 —— 这样量到的 fontSize
    /// 才是 fontScale 生效后的值（recordMessageDraw 在基类里，位于 wrapper 内层）。
    /// 返回本次画出的行数。
    render: function () {
      Window_Message.prototype.startMessage.call(messageWindow);
      var lines = (messageWindow._texts || []).slice();
      lastRendered = [];
      for (var i = 0; i < lines.length; i++) {
        messageWindow.drawTextEx(String(lines[i]), 0, 24 + i * 40);
        lastRendered.push(String(lines[i]));
      }
      repaint();
      return lines.length;
    },
    repaint: repaint,
    /// 最近一次 render() 画出的文本；还没 render 过则回落到 repaint() 涂到 canvas 的行。
    lastDrawn: function () {
      var source = lastRendered.length ? lastRendered : lastPainted;
      return source.slice();
    },
    /// 消息窗绘制调用记录（最多 DRAW_LOG_LIMIT 条，防止长会话把窗口数组撑爆）。
    drawLog: function () { return drawLog.slice(); },
    /// 消息窗绘制**总次数**（不受日志上限影响）。
    drawCount: function () { return drawTotal; },
    /// 消息窗 contents 的基准字号（未缩放）；K12 用它算 fontScale 的期望值。
    messageFontSize: function () { return messageWindow.contents.fontSize; },
    messageTexts: function () { return (gameMessage._texts || []).slice(); }
  };

  // ---------- 挂到 window ----------
  global.Bitmap = Bitmap;
  global.Window_Base = Window_Base;
  global.Window_Message = Window_Message;
  global.Scene_Base = Scene_Base;
  global.Scene_Map = Scene_Map;
  global.Scene_Boot = Scene_Boot;
  global.Scene_Menu = Scene_Menu;
  global.Scene_Battle = Scene_Battle;
  global.SceneManager = SceneManager;
  global.Graphics = Graphics;
  global.BattleManager = BattleManager;
  global.$dataSystem = dataSystem;
  global.$dataActors = dataActors;
  global.$dataItems = dataItems;
  global.$dataWeapons = dataWeapons;
  global.$dataArmors = dataArmors;
  global.$dataMap = dataMap;
  global.$gameSystem = gameSystem;
  global.$gameSwitches = gameSwitches;
  global.$gameVariables = gameVariables;
  global.$gameSelfSwitches = gameSelfSwitches;
  global.$gameParty = gameParty;
  global.$gameActors = gameActors;
  global.$gameMessage = gameMessage;
  global.$gameMap = gameMap;
  global.$gamePlayer = gamePlayer;
  global.__e2e = e2e;
  global.__stubRepaint = repaint;

  repaint();
})(typeof window !== 'undefined' ? window : this);
