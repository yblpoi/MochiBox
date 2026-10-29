/*
 * agent_mvmz.js —— MochiBox 页面内 Agent（RPG Maker MV / MZ 共用）
 *
 * 职责：
 *   1. hook 引擎绘制函数，采集待翻译原文（TextEvent）
 *   2. 命中译文时替换 text 形参后交给原函数（不阻塞绘制）
 *   3. 提供 window.__mochibox.{version,installed,state,drain,inbox,install,uninstall,hello,probe}
 *
 * 约束（docs/architecture.md §6）：
 *   - 不引用任何 Host 概念（不知道端口、不知道缓存文件）
 *   - 整体 try/catch，任何异常都不得抛给游戏
 *   - 幂等：install() 重复调用不会叠 hook
 *   - **不做哈希、不做文本归一化**（docs/architecture.md §6.2.1）：
 *     页面侧只用 `mapKey`（text 段以 U+001F 连接的原串）作译文 Map 的键；
 *     `sha256(engine|from|to|text)` 这类持久化缓存键**只由 Host 计算**。
 *     手写 JS 加密算法在页面里收益为零、风险为正，因此本文件不含任何哈希实现。
 */
(function (global) {
  'use strict';

  if (!global) { return; }

  var VERSION = 3;
  /// **信封协议版本**，与脚本能力版本（`VERSION`）是两件事。
  ///
  /// Host 的 `K.protocolVersion` 只认同这个值。发成 `VERSION` 的代价不是"新字段被忽略"，
  /// 而是**每一条消息都被 Host 丢弃**：文本流永远是 0 句、作弊面板全部 `rpc_timeout`，
  /// 日志里反复出现"协议版本不匹配，丢弃消息 type=text v=2"。
  var PROTOCOL = 1;
  var US = '\u001F';
  /// 转义码码表版本。与 Swift 的 `K.escapeTableVersion` **必须同值**（架构 §8.4 第 2 条），
  /// 供 `grep` 对比与 selftest 断言。
  var ESCAPE_TABLE_VERSION = 2;
  var SINGLE_CODES = '{}|!.$><^\\G';
  var BRACKET_CODES = ['FS', 'PX', 'PY', 'X', 'N', 'V', 'P', 'C', 'I'];
  var MAX_OUTBOX = 2000;
  var DRAIN_LIMIT = 50;
  var DEDUPE_CAP = 1024;
  /// 同一 `surface + raw` 的采集抑制窗口（毫秒）。见 `shouldEmitFor`。
  /// **是 `raw` 不是 `key`**：`key`（mapKey）剥掉了控制码，拿它做去重会把
  /// `350` 与 `\C[2]350` 压成一条（BUG-8 回归点）。行身份用 raw、翻译身份用 key。
  var EMIT_DEDUPE_MS = 800;

  // 重复注入（页面刷新 / 重新 attach / 上次 uninstall 之后）：补齐 hook 并再发一次 hello。
  if (global.__mochibox && global.__mochibox.version === VERSION) {
    try {
      if (typeof global.__mochibox.install === 'function') { global.__mochibox.install(); }
    } catch (e) { /* ignore */ }
    try {
      if (typeof global.__mochibox.hello === 'function') { global.__mochibox.hello(); }
    } catch (e) { /* ignore */ }
    return;
  }

  // 旧版 Agent 已在页面里（升级后不刷新页面就重连）：先卸载旧 hook 再装新的。
  //
  // 为什么必须卸载：hook 包装函数是**闭包**，它调用的是旧版的 `processText`/`translations`。
  // 只替换 `global.__mochibox` 而不解包，新对象能应答 RPC，但绘制路径永远走旧闭包 ——
  // 表现为"作弊面板有数据、译文却还是上一版"，排查成本极高。
  if (global.__mochibox && global.__mochibox.version !== VERSION) {
    try {
      if (typeof global.__mochibox.uninstall === 'function') { global.__mochibox.uninstall(); }
    } catch (e) { /* ignore */ }
  }

  // ------------------------------------------------------------------
  // 状态
  // ------------------------------------------------------------------

  var state = {
    enabled: true,
    fontScale: 1.0,
    /// 用户选的游戏字体族（空 = 自动：苹方系回退链）。config 下发，动态生效。
    fontFamily: '',
    /// 数据回写总开关：把译文写进 `$data*` 的 name / messageN 等字段（见「数据回写」一节）。
    /// 默认开；关掉时一个字段都不写，并立刻还原已写的。
    dataPatchEnabled: true,
    /// 数据回写的子开关：是否连 `name` / `nickname`（含 `Game_Actor._name`）一起回写。
    /// Live2DInterfaceMZ 一类插件把 `$dataArmors[].name` 当服装动效表的 key、把 `_name`
    /// 拿去做换装联动比较，这些游戏要关的是**这个**，而不是整个数据回写。
    dataPatchNames: true,
    mapSize: 0,
    errors: 0,
    emitted: 0,
    replaced: 0,
    skipped: 0,
    /// 因分段信息不可用/自相矛盾而退回 `translatedRaw` 的次数（BUG-11 的可观测面）。
    /// 正常会话恒为 0；变大说明 Host 下发的 `segments` 与本行 raw 对不上。
    mergeFallback: 0
  };

  var installed = false;
  var installedHooks = [];
  var outbox = [];
  /// 上一批 `requeue()` 回灌成功的信封签名（见 `requeue`）。
  /// 只留**最近一批**，用来吸收"evaluate 其实执行了、但 Host 侧超时了"这种重放：
  /// 协议信封没有全局 id，长期指纹表反而会在正常重绘时误杀同签名的新行。
  var lastRequeueSignatures = {};
  var translations = {};
  var mapOrder = [];
  /**
   * 消息窗里被原地替换的原文：数组下标 -> raw。
   *
   * 必须按**下标**存，不能拿译文字符串当 key：两句不同原文译成同一句时会串味，
   * 关闭翻译的瞬间把 A 的原文还原到 B 上。环形上限 200 条，够覆盖一屏多段对白。
   */
  var replacedTextsByIndex = {};
  var replacedIndexOrder = [];
  var REPLACED_TEXTS_LIMIT = 200;
  var sessionToken = (typeof global.__mochiboxSessionToken === 'string') ? global.__mochiboxSessionToken : '';
  var srcLang = 'ja';
  var tgtLang = 'zh-Hans';
  var maxMapSize = 20000;
  /// `surface\u0000raw → 最近一次 emit 的时间戳`（滑动窗口去重）。
  /// 第二个分量是**实际画到屏幕的串 raw**（含控制码），不是 mapKey（见 `shouldEmitFor`）。
  var lastEmitAt = {};
  var lastEmitCount = 0;
  var inDrawDepth = 0;
  /// 战斗日志 hook 的延迟补装定时器（插件可能晚于 Agent 早装才定义 `drawTextEx`）。
  var battleLogHookTimer = null;
  var config = { useBinding: false };

  /// 运行期见过的原文（全文扫描的第三源）。
  /// **不是**译文缓存：这里只回答"这局游戏实际画出过哪些串"，供 `text.scanStart` 合并。
  /// 上限 20000 条，超限按 FIFO 丢最旧的 —— 扫描是一次性动作，丢老串只会少翻一句，
  /// 不会影响当前屏幕（当前屏幕的串每次重绘都会重新进入队尾）。
  var runtimeSeen = [];
  var runtimeSeenSet = {};
  var RUNTIME_SEEN_LIMIT = 20000;

  var orig = {
    drawText: null,
    drawTextEx: null,
    battleLogDrawTextEx: null,
    bitmapDrawText: null,
    startMessage: null,
    /// 数据回写（见下文「数据回写」一节）：`DataManager.createGameObjects` 与剧情改名的 `setName`。
    createGameObjects: null,
    extractSaveContents: null,
    setName: null,
    makeFontNameText: null,
    standardFontFace: null,
    /// `HTMLMediaElement.prototype.play / load` 的原生函数（见 `patchMediaCompat`）。
    /// **没有 loop 描述符**：补丁不读写 loop，保留它只会诱使下一个人再改回去。
    mediaPlay: null,
    mediaLoad: null
  };

  /// 采集抑制窗口用的时钟：优先 `performance.now()`（单调，不受对时/改表影响）。
  /// **不得用 `Date.now()`**：系统校正会制造负间隔（窗口被无限压抑，文本流卡住）
  /// 或巨间隔（每次重绘都新增行），两者都不报错。仅在引擎无 performance 时退化。
  function nowMs() {
    try {
      if (typeof performance !== 'undefined' && performance && typeof performance.now === 'function') {
        return performance.now();
      }
    } catch (e) { /* 退化到 Date */ }
    try { return Date.now(); } catch (e) { return 0; }
  }

  function frameBucket() {
    return Math.floor(nowMs() / 16);
  }

  function sceneClassName() {
    try {
      var scene = global.SceneManager && global.SceneManager._scene;
      if (scene && scene.constructor && scene.constructor.name) { return scene.constructor.name; }
    } catch (e) { /* ignore */ }
    return null;
  }

  // ------------------------------------------------------------------
  // 分段 / 译文映射键（纯字符串，无哈希 —— docs/architecture.md §6.2.1）
  // ------------------------------------------------------------------

  /**
   * 把字符按 **ASCII** 折叠成大写（其它字符原样返回）。
   *
   * 不用 `toUpperCase()`：Unicode 大小写映射（土耳其 ı、德文 ß、希腊终结 sigma）
   * 在不同运行时下结果不同，而码表里只有 ASCII 字母。
   * **只用于比对，绝不改写段值**：`\c[3]` 仍以 `\c[3]` 拼回（上转会让 mapKey 双端全错）。
   */
  function asciiUpper(ch) {
    if (typeof ch !== 'string' || ch.length === 0) { return ch; }
    var code = ch.charCodeAt(0);
    return (code >= 97 && code <= 122) ? String.fromCharCode(code - 32) : ch;
  }

  function bracketCodeLength(text, start) {
    for (var p = 0; p < BRACKET_CODES.length; p++) {
      var letters = BRACKET_CODES[p];
      var matched = true;
      for (var l = 0; l < letters.length; l++) {
        if (asciiUpper(text.charAt(start + 1 + l)) !== letters.charAt(l)) { matched = false; break; }
      }
      if (!matched) { continue; }
      var bracket = start + 1 + letters.length;
      if (text.charAt(bracket) !== '[') { continue; }
      var close = text.indexOf(']', bracket + 1);
      if (close < 0) { return -1; }
      return close - start + 1;
    }
    return 0;
  }

  function splitSegments(raw) {
    var segments = [];
    if (typeof raw !== 'string' || raw.length === 0) { return segments; }
    var buffer = '';
    var i = 0;
    while (i < raw.length) {
      var ch = raw.charAt(i);
      if (ch === '\\' && i + 1 < raw.length) {
        var length = bracketCodeLength(raw, i);
        if (length > 0) {
          if (buffer !== '') { segments.push({ kind: 'text', value: buffer }); buffer = ''; }
          segments.push({ kind: 'code', value: raw.substring(i, i + length) });
          i += length;
          continue;
        }
        if (length === -1) {
          // 有 '[' 无 ']'：整段按文本处理
          buffer += ch;
          i += 1;
          continue;
        }
        var nextChar = raw.charAt(i + 1);
        if (SINGLE_CODES.indexOf(asciiUpper(nextChar)) >= 0) {
          if (buffer !== '') { segments.push({ kind: 'text', value: buffer }); buffer = ''; }
          segments.push({ kind: 'code', value: raw.substring(i, i + 2) });
          i += 2;
          continue;
        }
      }
      buffer += ch;
      i += 1;
    }
    if (buffer !== '') { segments.push({ kind: 'text', value: buffer }); }
    return segments;
  }

  function textSegments(segments) {
    var out = [];
    for (var i = 0; i < segments.length; i++) {
      if (segments[i].kind === 'text') { out.push(segments[i].value); }
    }
    return out;
  }

  function textOf(segments) {
    return textSegments(segments).join(US);
  }

  /**
   * 页面侧译文映射键（**纯字符串，无哈希、无归一化**）。
   * 与 Host 的 `Segmenter.joinForBackend(segments)` 完全一致：
   * 取 `kind === 'text'` 的片段用 U+001F 连接；全是 code 段时退回原串本身。
   * Host 的持久化缓存键（sha256）与此无关，也不得由页面计算。
   */
  /// 文本段计数（只数 `kind === 'text'`）。
  ///
  /// `mergeBySkeleton` 与 `lookup` 都靠它回答"本行还有没有可替换的文本段"。
  /// **只留一处实现**：本项目的历史教训是同一判据写两遍必然漂移。
  function countTextSegments(segments) {
    var count = 0;
    if (!segments || typeof segments.length !== 'number') { return 0; }
    for (var i = 0; i < segments.length; i++) {
      if (segments[i] && segments[i].kind === 'text') { count++; }
    }
    return count;
  }

  /// `key` 的**唯一实现**：骨架已在手时用这个，避免再切一次段。
  function mapKeyOfSegments(segments, raw) {
    var text = textOf(segments);
    if (text === '') { return raw; }
    return text;
  }

  function mapKeyOf(raw) {
    return mapKeyOfSegments(splitSegments(raw), raw);
  }

  // ------------------------------------------------------------------
  // 出站队列
  // ------------------------------------------------------------------

  function emit(type, payload) {
    try {
      var envelope = { v: PROTOCOL, type: type, sessionToken: sessionToken, payload: payload };
      outbox.push(envelope);
      if (outbox.length > MAX_OUTBOX) {
        outbox.shift();
        state.errors++;
      }
      if (type === 'text') { state.emitted++; }
      // 可选加速通道：Host 未显式启用时绝不发，避免与 drain 双到。
      if (config.useBinding && typeof global.__mochiboxEmit === 'function') {
        try { global.__mochiboxEmit(JSON.stringify(envelope)); } catch (e) { /* ignore */ }
      }
    } catch (e) {
      state.errors++;
    }
  }

  function drain() {
    try {
      if (!outbox.length) { return '[]'; }
      var items = outbox.splice(0, DRAIN_LIMIT);
      return JSON.stringify(items);
    } catch (e) {
      state.errors++;
      return '[]';
    }
  }

  /**
   * 信封签名。协议里**没有**全局 id：text 靠 `ts`/`frame`/`surface`/`raw`，
   * rpc 有 `payload.id`，scanChunk 有 `scanId`+`seq`，其余靠 type + 少量特征字段。
   * 拼不出来（异常）就返回空串 —— 空签名不参与去重，宁可重复也不丢。
   */
  function envelopeSignature(envelope) {
    try {
      if (!envelope || typeof envelope !== 'object') { return ''; }
      // 没有 type 的项不是信封（Host 侧也只按 type 分发）。缺了它，`{}` 会拼出
      // "undefined\u0001undefined\u0001undefined" 这种恒定签名，被当成"同一个信封"
      // 去重、还被记进去重表 —— 畸形批于是能清掉上一批的签名。
      if (typeof envelope.type !== 'string' || envelope.type === '') { return ''; }
      var payload = envelope.payload;
      var parts = [String(envelope.v), String(envelope.type), String(envelope.sessionToken)];
      if (payload && typeof payload === 'object') {
        if (typeof payload.ts === 'number') { parts.push('ts=' + payload.ts); }
        if (typeof payload.frame === 'number') { parts.push('f=' + payload.frame); }
        if (typeof payload.surface === 'string') { parts.push('s=' + payload.surface); }
        if (typeof payload.raw === 'string') { parts.push('r=' + payload.raw); }
        if (typeof payload.id === 'string') { parts.push('id=' + payload.id); }
        if (typeof payload.method === 'string') { parts.push('m=' + payload.method); }
        if (typeof payload.scanId === 'string') { parts.push('scan=' + payload.scanId); }
        if (typeof payload.seq === 'number') { parts.push('seq=' + payload.seq); }
        if (typeof payload.code === 'string') { parts.push('c=' + payload.code); }
      }
      return parts.join('\u0001');
    } catch (e) {
      return '';
    }
  }

  /**
   * 把一批信封按原序**放回队首**（握手期 Host 读走但没消费的那些）。
   *
   * 为什么需要它：`install()` 成功后页面立刻开始 emit（`state.enabled` 默认 true，
   * 不等 Host），而 Host 的握手循环只认 `hello`。它用 `drain()` 把整个队列 splice 走，
   * 非 hello 的信封就此消失 —— 真游戏上表现为首屏几句被吃掉、Host 侧 `captured=0`。
   *
   * 语义边界（`emit()` / `drain()` 一个字都没改）：
   *   - **队首**插入：这批是整个队列里最旧的；放队尾会让文本流乱序。
   *   - 容量沿用 `emit()` 的"丢最旧"（`shift()`），并同样计 `state.errors`。
   *     溢出只在 Host 长期不 drain（积压已 ≥ MAX_OUTBOX）时发生；那种情况下
   *     这 50 条本来也是最旧的，与既有取舍一致。
   *   - 去重只与**上一批**比对：Host 侧的失败处理是"记 warn 不重试"，
   *     真正的重复只可能来自同一次回灌被执行两遍。
   *
   * @param {string|Array} json 信封数组（或它的 JSON 文本）
   * @returns {string} `{"total":n,"accepted":n,"duplicate":n,"dropped":n}`
   */
  function requeue(json) {
    var report = { total: 0, accepted: 0, duplicate: 0, dropped: 0 };
    try {
      var items = (typeof json === 'string') ? JSON.parse(json) : json;
      if (!items || typeof items.length !== 'number') { return JSON.stringify(report); }
      report.total = items.length;
      var seen = {};
      var restored = [];
      var signed = 0;
      for (var i = 0; i < items.length; i++) {
        var item = items[i];
        if (!item || typeof item !== 'object') { continue; }
        var signature = envelopeSignature(item);
        if (signature !== '') {
          if (lastRequeueSignatures[signature] || seen[signature]) {
            report.duplicate++;
            continue;
          }
          seen[signature] = 1;
          signed++;
        }
        restored.push(item);
      }
      if (restored.length) {
        outbox = restored.concat(outbox);
        while (outbox.length > MAX_OUTBOX) {
          outbox.shift();
          report.dropped++;
          state.errors++;
        }
        report.accepted = restored.length - report.dropped;
        // 只记**活下来**的那部分签名：被容量挤掉的若是签名仍留在表里，
        // 下一次真回灌会被误判成重复而永久丢失。
        //
        // 两种情况**不**改写记忆：
        //   · 整批全重复（restored 为空）—— 这一批没有投递任何东西，"最近一次被
        //     接受的批次"仍然是上一批；在这里清空会让第三次重放又变成新信封，
        //     形成 accepted → duplicate → accepted 循环。
        //   · 整批全是无签名的畸形项（signed === 0）—— 它们不是可消费的信封，
        //     清空签名表等于忘掉上一批真投递过的内容，下一次重放原批会再投一遍。
        if (signed > 0) {
          lastRequeueSignatures = {};
          for (var j = report.dropped; j < restored.length; j++) {
            var survivor = envelopeSignature(restored[j]);
            if (survivor !== '') { lastRequeueSignatures[survivor] = 1; }
          }
        }
      }
      return JSON.stringify(report);
    } catch (e) {
      state.errors++;
      return JSON.stringify(report);
    }
  }

  function reportHookError(error) {
    try {
      emit('error', {
        code: 'hook_error',
        message: String(error),
        stack: (error && error.stack) ? String(error.stack) : null
      });
    } catch (e) { /* ignore */ }
  }

  // ------------------------------------------------------------------
  // 译文 Map
  // ------------------------------------------------------------------

  /// 译文条数缓存。
  ///
  /// **不能**在 `putTranslation` 里每次 `countKeys()`：全文翻译一次下发 1 万条时，
  /// 每次 O(n) 计数会退化成 O(n²)（1 亿次属性遍历），把游戏主线程卡住数秒 ——
  /// 而 `inbox` 是在 `Runtime.evaluate` 里同步执行的，卡的就是渲染线程。
  var translationCount = 0;

  function countKeys() {
    return translationCount;
  }

  function bumpMapLimit() {
    if (translationCount <= maxMapSize) { return; }
    var overflow = translationCount - maxMapSize;
    var removed = mapOrder.splice(0, overflow);
    for (var i = 0; i < removed.length; i++) {
      if (Object.prototype.hasOwnProperty.call(translations, removed[i])) {
        translationCount--;
        try { delete translations[removed[i]]; } catch (e) { translations[removed[i]] = undefined; }
      }
    }
  }

  function putTranslation(item) {
    if (!item || typeof item.key !== 'string' || typeof item.translatedRaw !== 'string') { return; }
    var isNew = !Object.prototype.hasOwnProperty.call(translations, item.key);
    if (isNew) { mapOrder.push(item.key); translationCount++; }
    translations[item.key] = {
      translatedRaw: item.translatedRaw,
      segments: item.segments || null
    };
    if (translationCount > maxMapSize) { bumpMapLimit(); }
    state.mapSize = translationCount;
  }

  /**
   * 用**本行 raw 的分段骨架**重组译文（BUG-11 的修复点）。
   *
   * 为什么只能本地重组：Host 的 `delivered[cacheKey]` 命中分支只写 stream 后 `return`，
   * **不再下发** —— 所以"同一 mapKey、不同 raw 各自推一条"这条路根本不存在。
   * Agent 手里只有**先到那一行**的 `translatedRaw`（里面带着**别的行**的控制码）
   * 和一份 `segments`；而 `segments` 是 `Segmenter.translatedSegments(...)` 的产物
   * （code 段沿用原文码值、text 段换成译文，段数与顺序与原文一致），正好够用。
   *
   * 规则一句话：**`segments` 只当"译文文本段队列"用；code 段一律丢弃，改发本行 raw 自己的码值。**
   *
   * 不抛异常，用返回值表达结局：
   *   - 返回字符串 = 重组成功（可能是空串，由调用方决定是否采用）；
   *   - 返回 null   = 不该/无法重组（无文本段、无 `segments`、元素畸形、文本段数对不上）。
   * 段数对不上时**绝不猜**：宁可让调用方降级，也不要拼出一个错码串。
   *
   * @param {string|Array} rawOrSegments 本行 raw，或已切好的骨架（`splitSegments(raw)`）
   * @param {Array} translatedSegments Host 下发的 `entry.segments`
   * @returns {string|null}
   */
  function mergeBySkeleton(rawOrSegments, translatedSegments) {
    var rawSegments, i;
    try {
      rawSegments = (typeof rawOrSegments === 'string') ? splitSegments(rawOrSegments) : rawOrSegments;
    } catch (e) {
      return null;
    }
    if (!rawSegments || typeof rawSegments.length !== 'number') { return null; }

    var textCount = countTextSegments(rawSegments);
    // 全 code 行（`\i[17]` / `\g`）：没有可替换的文本段，本函数无可贡献。
    if (textCount === 0) { return null; }

    // 老 Host / 未带 segments：拿不到译文文本段队列。
    if (!translatedSegments || typeof translatedSegments.length !== 'number') { return null; }

    var pieces = [];
    for (i = 0; i < translatedSegments.length; i++) {
      var seg = translatedSegments[i];
      if (!seg || typeof seg.kind !== 'string' || typeof seg.value !== 'string') { return null; }
      // 只收 text 段；code 段**故意丢弃** —— 那是先到那一行的码值，不是本行的。
      if (seg.kind === 'text') { pieces.push(seg.value); }
    }
    // 文本段数与骨架不一致：不猜，交调用方（本工程 = 画原文，见 `lookup` 出口 1）。
    if (pieces.length !== textCount) { return null; }

    var out = '';
    var cursor = 0;
    for (i = 0; i < rawSegments.length; i++) {
      if (rawSegments[i].kind === 'text') {
        out += pieces[cursor];
        cursor++;
      } else {
        // ★ code 段：只用本行 raw 自己的值，大小写原样（`\c[3]` 绝不上转）。
        out += rawSegments[i].value;
      }
    }
    return out;
  }

  /// 取本行该画的译文。
  ///
  /// **`raw` 必须真正参与**：翻译身份是 `mapKey`（剥码后的 text），行身份是 `raw`（含控制码）。
  /// 拿 `mapKey` 直接返回 `translatedRaw`，画上屏幕的就是**别的行**的控制码（BUG-11 本体）。
  ///
  /// 三条出口，按"手里有多少段证据"分（**不要合并成一条降级路**）：
  ///   1. 有 `segments`（非空数组）：只信 `mergeBySkeleton`。它返 null（段数不符 / 骨架无
  ///      text 段）就**画原文**（返回 null）。理由：`translatedRaw` 的码值属于**第一个**产生
  ///      该 mapKey 的行；同 mapKey 的两行文本段必然相同，所以段数不符只可能来自病态数据
  ///      （正文里真出现 U+001F 与分隔符撞车）。此时拿别人的串就是把 BUG-11 在本行重放一遍，
  ///      **画错人名比不翻译严重得多**。
  ///   2. `segments` 缺失/为空（旧 Host 或防御路径）：回退 `translatedRaw` —— 没有任何段证据，
  ///      整串回退是唯一可用信息，且不得因此退化成"永远不翻译"。
  ///   3. 空串视为未命中（保持 v0.2 判据）。

  /// AddBattleLogEC 的战斗日志控制前缀（4 个字符，大小写敏感）。
  var ABL_PREFIX = '_ABL';

  /// `_ABL` 命中路径专用：译文开头的 `_ABL` 是给 AddBattleLogEC 看的控制前缀，
  /// 文本进入战斗日志前已被插件剥掉，画到屏幕上只会多出这四个字符。
  function stripABLPrefix(text, stripped) {
    return (stripped && text.slice(0, 4) === ABL_PREFIX) ? text.slice(4) : text;
  }

  /// 回退路径专用：Host 的 `segments` 是按**带 `_ABL` 的原文**切段的。`_ABL` 后面紧跟
  /// `\c[23]` 这类码时，它会独立成一个 text 段 —— 比运行期 raw 多一段，`mergeBySkeleton`
  /// 会判"段数不符"而拒拼。先把前缀从第一个 text 段里去掉；剥成空串的段丢掉
  /// （整条译文只有 `_ABL` 时保留空段，让出口 3 的"剥完为空 → 画原文"生效）。
  function stripABLFromSegments(segments) {
    var out = [];
    var stripped = false;
    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i];
      if (!stripped && seg && seg.kind === 'text' && typeof seg.value === 'string'
          && seg.value.slice(0, 4) === ABL_PREFIX) {
        var value = seg.value.slice(4);
        stripped = true;
        if (value !== '') {
          out.push({ kind: 'text', value: value });
        } else if (countTextSegments(segments) === 1) {
          // 整条译文就只有 `_ABL`：保留空段，让 mergeBySkeleton 返回空串
          // （出口 3 的"剥完为空 → 画原文"，与段数不符是两回事）。
          out.push({ kind: 'text', value: '' });
        }
        continue;
      }
      out.push(seg);
    }
    return out;
  }

  function lookup(raw, key, rawSegments) {
    var entry = translations[key];
    if (!entry || typeof entry.translatedRaw !== 'string' || entry.translatedRaw === '') {
      entry = null;
    }
    var strippedABL = false;
    // `_ABL` 回退：AddBattleLogEC 在文本进入战斗日志前剥掉前缀，翻译表的 key 却仍带它。
    // 用**同一个**切段/建键实现补回前缀再查，命中后只在这一条回退路径里剥结果。
    if (entry === null && typeof raw === 'string' && raw.length > 0 && raw.slice(0, 4) !== ABL_PREFIX) {
      var prefixed = ABL_PREFIX + raw;
      var ablKey = mapKeyOfSegments(splitSegments(prefixed), prefixed);
      var ablEntry = translations[ablKey];
      if (ablEntry && typeof ablEntry.translatedRaw === 'string' && ablEntry.translatedRaw !== '') {
        entry = ablEntry;
        strippedABL = true;
      }
    }
    if (entry === null) { return null; }

    var skeleton = (rawSegments === undefined || rawSegments === null) ? splitSegments(raw) : rawSegments;
    // 本行没有文本段（全 code）：不需要替换，也不算一次"降级"。
    if (countTextSegments(skeleton) === 0) { return null; }

    var hasSegments = Object.prototype.toString.call(entry.segments) === '[object Array]'
      && entry.segments.length > 0;
    if (!hasSegments) {
      // 出口 2：无段证据 → v0.2 行为（可观测：`probe().mergeFallback`）。
      state.mergeFallback++;
      var fallback = stripABLPrefix(entry.translatedRaw, strippedABL);
      return fallback === '' ? null : fallback;
    }

    var translatedSegments = strippedABL ? stripABLFromSegments(entry.segments) : entry.segments;
    var merged = mergeBySkeleton(skeleton, translatedSegments);
    if (merged === null) {
      // 出口 1：有段证据但自相矛盾 → 拒绝拼接，画原文（绝不重放别人的码值）。
      state.mergeFallback++;
      return null;
    }
    var result = stripABLPrefix(merged, strippedABL);
    return result === '' ? null : result;
  }

  // ------------------------------------------------------------------
  // 采集
  // ------------------------------------------------------------------

  // 判定用空白集合 = 与 normalizeForKey 折叠白名单**同一份**的 5 个码位
  // （U+0009 / U+000A / U+000D / U+0020 / U+3000）。
  // 判据里**不出现任何平台/方言相关的字符类**（`\s`、`CharacterSet` 之类）：
  // `\p{P}` / `\p{S}` 是 Unicode 类别，两端语义相同；`\s` 在 JS 里含 U+FEFF、
  // 在 Swift `.whitespaces` 里不含，用它只会把一个不一致换成另一个。
  function isFoldableSpaceCode(code) {
    return code === 0x09 || code === 0x0A || code === 0x0D || code === 0x20 || code === 0x3000;
  }

  /**
   * **只用于跳过判定的**归一化（NFKC + 空白折叠 + trim），与 Swift `Segmenter.normalizeForKey` 同义。
   *
   * 注意：它产出的串**绝不**用于绘制、也不用于 mapKey —— 否则会改变屏幕上要显示的文字
   * （§6.2.1 契约 1）。它只在这里回答一个问题："这串值不值得送翻译"。
   * 没有它，`"３５０"`（全角）和 `"350 "`（尾空格）判不出纯数字 → 漏跳 → 多花一次请求。
   */
  function normalizeForSkip(text) {
    var normalized = text;
    try {
      if (typeof normalized.normalize === 'function') { normalized = normalized.normalize('NFKC'); }
    } catch (e) { /* 老引擎没有 normalize：保持原串，宁可多译不可漏译 */ }
    var out = '';
    var pendingSpace = false;
    var started = false;
    for (var i = 0; i < normalized.length; i++) {
      var code = normalized.charCodeAt(i);
      if (isFoldableSpaceCode(code)) {
        if (started) { pendingSpace = true; }
        continue;
      }
      if (pendingSpace) { out += ' '; pendingSpace = false; }
      out += normalized.charAt(i);
      started = true;
    }
    return out;
  }

  // `\p{P}` / `\p{S}` 需要 `u` 标志（ES2018）。现代 Chromium/NW.js 都支持；
  // 不支持时**保守地不跳过**（多译一句只花一点钱，漏译一整句用户无从发现）。
  var PUNCT_SYMBOL_RE = null;
  var PUNCT_SYMBOL_SUPPORTED = false;
  try {
    PUNCT_SYMBOL_RE = new RegExp('^[\\p{P}\\p{S}]+$', 'u');
    PUNCT_SYMBOL_SUPPORTED = true;
  } catch (e) {
    PUNCT_SYMBOL_RE = null;
    PUNCT_SYMBOL_SUPPORTED = false;
  }

  /**
   * 与 Swift SkipRules.isPredominantlyChinese 同义：无假名 + 汉字 ≥ 8 +
   * 至少 2 个**不同**的中文虚词。
   *
   * 虚词表刻意不含 我 / 他 / 了 / 是：它们在日文汉字词里太常见（目的 / 了解 / 我々），
   * 收进来会把日文汉字句误判成中文而整句漏译。与 Swift 侧逐条一致（parity 探针会钉住）。
   */
  var CHINESE_FUNCTION_CHARS = '的们吗吧呢这那你您着过把被给让';

  function isPredominantlyChinese(text) {
    if (typeof text !== 'string' || text === '') { return false; }
    var hanzi = 0;
    var seen = {};
    var distinct = 0;
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i);
      if ((code >= 0x3040 && code <= 0x309F) ||
          (code >= 0x30A0 && code <= 0x30FF) ||
          (code >= 0xFF66 && code <= 0xFF9D)) {
        return false;
      }
      if ((code >= 0x3400 && code <= 0x4DBF) || (code >= 0x4E00 && code <= 0x9FFF)) { hanzi++; }
      var ch = text.charAt(i);
      if (CHINESE_FUNCTION_CHARS.indexOf(ch) >= 0 && !seen[ch]) { seen[ch] = 1; distinct++; }
    }
    return hanzi >= 8 && distinct >= 2;
  }


  /**
   * 跳过判据（与 Swift `SkipRules` 同义，两端**同一份判据**）。
   * 返回 `null` 表示需要翻译，否则返回理由串（`numeric` / `punctuation` / `whitespace`）。
   *
   * 判据（architecture §7.7 / PRD §5.1）：
   *   1) 归一（NFKC + 折叠 5 个空白 + trim）；
   *   2) 空串 → `whitespace`；
   *   3) 整串（锚定）纯数字 → `numeric`；
   *   4) **移除那 5 个码位**后的余串非空且全是 `\p{P}`/`\p{S}` → `punctuation`；
   *   5) 已是中文（无假名 + 汉字 ≥8 + ≥2 个不同虚词）→ `chinese`；
   *   6) 否则不跳过。
   *
   * **不得**用未锚定的 `\d+`：那会把 "第2章" / "10秒後" / "350G" 整句漏译（architecture §7.8）。
   * **不得**用码段范围（如 `\uFF01-\uFF65`）冒充 `\p{P}\p{S}`：那会把全角字母
   * `ＯＫ`、`３５０Ｇ` 当符号误跳（用户永远看到原文），又会漏掉 `♪` / `★`（白白送翻）。
   */
  function skipReasonOf(text) {
    var trimmed = normalizeForSkip(text);
    if (trimmed === '') { return 'whitespace'; }
    if (/^[0-9]+$/.test(trimmed)) { return 'numeric'; }
    // 第 4 步：先移除 5 个码位再测标点 —— `"! !"` 必须与 `"!!"` 同判（否则两端不一致）。
    var core = '';
    for (var i = 0; i < trimmed.length; i++) {
      if (!isFoldableSpaceCode(trimmed.charCodeAt(i))) { core += trimmed.charAt(i); }
    }
    if (core === '') { return 'whitespace'; }
    if (PUNCT_SYMBOL_SUPPORTED && PUNCT_SYMBOL_RE.test(core)) { return 'punctuation'; }
    // 已是中文：整串判（不是逐段），顺序与 Swift 一致：whitespace → numeric → punctuation → chinese。
    if (isPredominantlyChinese(trimmed)) { return 'chinese'; }
    return null;
  }

  /**
   * 采集去重（PRD P0-08）：同一 `surface + raw` 在 `EMIT_DEDUPE_MS` 内**只 emit 一次**。
   *
   * **行身份 = `surface` + `raw`**（实际画出的串），不得用 `mapKey`：`mapKey` 剥掉了控制码，
   * 于是 `350` 与 `\C[2]350` 会撞同一个签名、后者被静默吞掉，原文列再也看不到 `\C[2]350`。
   * 显示身份用 `raw`，翻译身份用 `mapKey`，两者不同层（架构 §6.3）。
   *
   * 用**滑动**窗口而不是固定时间片：只要它还在屏幕上连续重绘，时间戳就不断刷新，
   * 因此一句持续显示的对白只记 1 条；等它离开画面超过窗口再从同一句回来时，
   * 会重新 emit（玩家反复确认同一句是要计入次数的，所以**不能**"内容相同就永久不 emit"）。
   *
   * 之前按 `frameBucket()`（16ms 桶）去重，等于每帧都是新签名 —— 替代页每 400ms 重绘，
   * 3 句对白 8 秒能刷出 66 条，5000 行环形缓冲几秒就滚完。
   */
  /// 重置采集窗口。
  ///
  /// 必须在新会话开始时调用：滑动窗口的语义是"只要还在屏幕上就不重复上报"，
  /// 因此上一轮 `--attach` 结束后页面仍在重绘，窗口会被一直续期 ——
  /// 新一轮 Host 上来若不清零，会看到 `captured=0`（"连上了但一句都没有"）。
  function resetCaptureWindow() {
    lastEmitAt = {};
    lastEmitCount = 0;
  }

  /// 去重签名用 **surface + 原始串**，不是 mapKey。
  /// mapKey 已剥掉控制码，`350` 与 `\C[2]350` 会算成同一个 key，
  /// 800ms 内只留先到的那条 → `\C[2]350` 整行消失（P0-09 反例，QA BUG-8）。
  /// raw 含控制码，同一条消息重绘时 raw 不变，仍能压住重绘风暴。
  function shouldEmitFor(surface, identity) {
    var now = nowMs();
    var signature = surface + '\u0000' + identity;
    var last = lastEmitAt[signature];
    // 时钟回拨防护：Date.now() 可被对时/用户改表向前回拨，
    // 若直接比较会让"距上次绘制"变成负数，窗口被无限压抑（表现为整段游戏不再出行）。
    // 回拨时把基准夹到 last，等价于"这段时间没有流逝"，而不是"很久以前"。
    if (typeof last === 'number' && now < last) { now = last; }
    if (typeof last === 'number' && (now - last) < EMIT_DEDUPE_MS) {
      lastEmitAt[signature] = now;   // 仍在屏幕上 → 续期，继续抑制
      return false;
    }
    lastEmitAt[signature] = now;
    lastEmitCount++;
    if (lastEmitCount > DEDUPE_CAP) {
      lastEmitAt = {};
      lastEmitCount = 0;
    }
    return true;
  }

  /**
   * 记住一条"游戏真的画过"的原文（全文扫描的第三源）。
   *
   * 只做去重与 FIFO 淘汰，不做任何归一化：进入扫描后要和 `$data*` 的原文**逐字节**
   * 对比才能去重，改一个字符就会变成两条译文（一条用不上）。
   */
  function rememberRuntime(raw) {
    try {
      if (typeof raw !== 'string' || raw.length < 2) { return; }
      var key = 'k:' + raw;
      if (runtimeSeenSet[key]) { return; }
      runtimeSeenSet[key] = 1;
      runtimeSeen.push(raw);
      if (runtimeSeen.length > RUNTIME_SEEN_LIMIT) {
        var dropped = runtimeSeen.shift();
        try { delete runtimeSeenSet['k:' + dropped]; } catch (e) { runtimeSeenSet['k:' + dropped] = 0; }
      }
    } catch (e) { /* ignore */ }
  }

  /**
   * 采集一条绘制字符串（PRD P0-08：**每个绘制字符串产生 1 条 TextEvent**）。
   *
   * 跳过句（纯数字 / 纯符号 / 空白）同样要上报，只是额外带上 `status = 'skipped'` 与
   * `skipReason`：跳过是功能，不是异常 —— 若直接丢弃，宿主文本流里会凭空少一行，
   * 用户看到一句日文没被翻译、工具里却查不到任何痕迹（P0-09 还要求原文列保留 `\C[2]350`）。
   * 事件只在这里产生一条；宿主侧 `SkipRules` 会独立再判一次（双端判定），但**不会**再增行。
   */
  function collect(raw, surface, key, replaced, skeleton) {
    try {
      if (typeof raw !== 'string' || raw.length === 0) { return; }
      // 骨架由调用方（`processText`）切一次传进来；直接调用时原地切（行为与 v0.2 一致）。
      var segments = (skeleton === undefined || skeleton === null) ? splitSegments(raw) : skeleton;
      var text = textOf(segments);
      // 去重与跳过共用一个窗口：重绘不能把计数刷爆，也不能让跳过句刷屏。
      if (!shouldEmitFor(surface, raw)) { return; }
      // 判定对象必须与 Host **逐字节相同**：`key`（= mapKeyOf(raw)，全 code 段时退回原串）。
      //
      // v0.2 修正：早期这里判的是 `text`（剥码后的段内容）。对"全是 code 段"的串
      // （`\i[17]` / `\g`）text 是空串 → Agent 报 `whitespace`，而 Host 的
      // `SkipRules.skipReason(for: Segmenter.mapKey(...))` 看到的是原串 → 判"该翻译"。
      // status 以 Host 为准（SessionController），于是 Agent 的 skipReason 变成一句假话，
      // 双端 parity 探针直接红（`Tests/qa/skip_parity.mjs` 的 `\i[17]` 样例）。
      var reason = skipReasonOf(key);
      if (reason !== null) { state.skipped++; }

      var payload = {
        ts: nowMs(),
        frame: frameBucket(),
        surface: surface,
        sceneClass: sceneClassName(),
        raw: raw,
        segments: segments,
        text: text,
        key: key,
        status: (reason === null) ? 'pending' : 'skipped'
      };
      if (reason !== null) { payload.skipReason = reason; }
      emit('text', payload);
      // 全文扫描的第三源：只记"真的画出来过"的串；跳过句（纯数字/符号）也记，
      // 由扫描侧统一过滤 —— 这里再判一次会让两处判据漂移。
      rememberRuntime(raw);
      if (replaced) { /* 已由调用方计入 replaced */ }
    } catch (e) {
      state.errors++;
    }
  }

  /// 返回替换用的译文（无命中返回 null），同时采集原文。
  ///
  /// `splitSegments(raw)` **只切一次**：骨架同时喂给 `lookup`（重组）与 `collect`（采集），
  /// 否则每帧每行要切两遍（`drawTextEx` 是每帧调用的热点路径）。
  function processText(raw, surface) {
    if (typeof raw !== 'string' || raw.length === 0) { return null; }
    var segments, key;
    try {
      segments = splitSegments(raw);
      key = mapKeyOfSegments(segments, raw);
    } catch (e) {
      state.errors++;
      return null;
    }
    var hit = null;
    if (state.enabled) {
      hit = lookup(raw, key, segments);
      if (hit !== null) { state.replaced++; }
    }
    collect(raw, surface, key, hit !== null, segments);
    return hit;
  }

  // ------------------------------------------------------------------
  // RPC：Host → Agent 的请求/应答
  //
  // 为什么不用 `inbox` 的 fire-and-forget：作弊面板要"调用 → 拿到结果/错误码"，
  // 单向消息只能靠再发一条 `text` 事件回传，既污染文本流也无法关联请求。
  // 协议见 docs/architecture-v0.6-cheat-and-fulltext.md §2.2。
  // ------------------------------------------------------------------

  var rpcSeq = 0;
  var speedState = { multiplier: 1, base: null, wrapped: false, acc: 0 };
  var godModeState = { on: false, lockHp: true, lockMp: false, baseSetHp: null, baseSetMp: null, wrapped: false };
  var cheatLog = [];

  function rpcError(code, message) {
    var error = new Error(message || code);
    error.code = code;
    return error;
  }

  function logCheat(method, detail) {
    try {
      cheatLog.push({ t: nowMs(), method: method, detail: detail || '' });
      if (cheatLog.length > 50) { cheatLog.shift(); }
    } catch (e) { /* ignore */ }
  }

  function clampInt(value, fallback, min, max) {
    var n = (typeof value === 'number' && isFinite(value)) ? Math.floor(value) : fallback;
    if (typeof min === 'number' && n < min) { n = min; }
    if (typeof max === 'number' && n > max) { n = max; }
    return n;
  }

  /// 严格 id 校验：**不夹取**。越界必须报错 —— 夹到上界会让 `setVariable(9999)`
  /// 静默写到最后一个变量上，用户看到"改了但没生效/改错了"，比报错难查得多。
  function requireId(value, max, label) {
    if (typeof value !== 'number' || !isFinite(value)) {
      throw rpcError('cheat_bad_args', label + ' 必须是数字');
    }
    var n = Math.floor(value);
    if (n < 1 || n > max) { throw rpcError('cheat_out_of_range', label + ' 越界: ' + value); }
    return n;
  }

  /// 可省略的 id：**缺省**走调用方给的默认对象（面板总是显式传 id），
  /// 但**一旦传了**就必须满足 requireId —— 不能夹取。
  /// `clampInt(undefined, -1, 1, …)` 会把"没传"和"传了 'abc'"压成同一个 1，
  /// 后者是用户输入错误，静默改到 #1 上比报错难查得多。
  function optionalId(value, max, label, fallback) {
    if (value === undefined || value === null) { return fallback; }
    return requireId(value, max, label);
  }

  /// 可省略的**槽位下标**：0 是合法槽，所以不能用 requireId（它要求 >= 1）。
  /// 缺失返回 null（调用方跳过该条），一旦传了就必须是 [0, max] 内的数字 ——
  /// 夹取会把 slotId:9 静默写到 4 号槽上（U-07/U-08）。
  function optionalSlotId(value, max, label) {
    if (value === undefined || value === null) { return null; }
    if (typeof value !== 'number' || !isFinite(value)) {
      throw rpcError('cheat_bad_args', label + ' 必须是数字');
    }
    var n = Math.floor(value);
    if (n < 0 || n > max) { throw rpcError('cheat_out_of_range', label + ' 越界: ' + value); }
    return n;
  }

  function requireGame() {
    if (!global.$gameParty && !global.$gameSystem) {
      throw rpcError('cheat_unavailable', '游戏尚未进入场景（$gameParty 不存在）');
    }
  }

  /// 把任意值压成可 JSON 化的浅结构。**不**调用 toJSON / 不触发 getter 链。
  function safeValue(value, depth) {
    var level = depth || 0;
    if (level > 2) { return null; }
    if (value === null || value === undefined) { return null; }
    var type = typeof value;
    if (type === 'number') { return isFinite(value) ? value : null; }
    if (type === 'boolean') { return value; }
    if (type === 'string') { return value.length > 500 ? value.slice(0, 500) + '…' : value; }
    if (type === 'function') { return null; }
    if (Object.prototype.toString.call(value) === '[object Array]') {
      var list = [];
      var limit = Math.min(value.length, 100);
      for (var i = 0; i < limit; i++) { list.push(safeValue(value[i], level + 1)); }
      return list;
    }
    if (type === 'object') {
      var out = {};
      var count = 0;
      for (var key in value) {
        if (!Object.prototype.hasOwnProperty.call(value, key)) { continue; }
        if (key === '__proto__' || key === 'constructor' || key === 'prototype') { continue; }
        out[key] = safeValue(value[key], level + 1);
        count++;
        if (count >= 40) { break; }
      }
      return out;
    }
    return null;
  }

  function dataTableOf(kind) {
    if (kind === 'weapon') { return global.$dataWeapons || []; }
    if (kind === 'armor') { return global.$dataArmors || []; }
    if (kind === 'skill') { return global.$dataSkills || []; }
    if (kind === 'state') { return global.$dataStates || []; }
    return global.$dataItems || [];
  }

  function dataEntryOf(kind, id) {
    var table = dataTableOf(kind);
    var entry = table[id];
    if (!entry) {
      throw rpcError('cheat_out_of_range', '数据 id 越界: ' + kind + '#' + id);
    }
    return entry;
  }

  /// changeEquip 可接受的 kind。未知 kind 不能落进 dataTableOf 的默认分支
  /// （那会把 $dataItems 里的道具当武器装到槽上）。
  var EQUIP_KINDS = { weapon: 1, armor: 1, item: 1, skill: 1, state: 1 };

  /// 把 equips 全量校验成 [{slotId, item}]。**先全部校验、再统一写入**：
  /// 边验边写会在第 N 条出错时留下前 N-1 条已生效的半成品装备（U-10 抓的就是这个）。
  function resolveEquips(actor, equips) {
    var slots = (typeof actor.equips === 'function') ? actor.equips() : [];
    var maxSlot = slots.length > 0 ? slots.length - 1 : 4;
    var plan = [];
    for (var i = 0; i < equips.length; i++) {
      var slot = equips[i];
      if (!slot || typeof slot !== 'object') {
        throw rpcError('cheat_bad_args', 'equips[' + i + '] 必须是对象');
      }
      var slotId = optionalSlotId(slot.slotId, maxSlot, 'equips[' + i + '].slotId');
      if (slotId === null) { continue; }
      var item = null;
      // itemId 缺失（undefined/null）= 卸下；存在（含 0/空串）就必须是合法 id。
      if (slot.itemId !== undefined && slot.itemId !== null) {
        var kind = (slot.kind === undefined || slot.kind === null) ? 'weapon' : slot.kind;
        if (typeof kind !== 'string' || !EQUIP_KINDS[kind]) {
          throw rpcError('cheat_bad_args', 'equips[' + i + '].kind 不支持: ' + String(kind));
        }
        item = dataEntryOf(kind, requireId(slot.itemId, 99999, 'equips[' + i + '].itemId'));
      }
      plan.push({ slotId: slotId, item: item });
    }
    return plan;
  }

  function actorOf(id) {
    requireGame();
    var actor = global.$gameActors && global.$gameActors.actor(id);
    if (!actor) { throw rpcError('cheat_out_of_range', 'アクター id 越界: ' + id); }
    return actor;
  }

  /// 读一个"可能是 getter、也可能是方法、也可能不存在"的数值属性。
  ///
  /// MV/MZ 原版把 `mhp`/`mmp`/`hp`/`mp` 定义成 **getter**（`rmmz_objects.js:2418`
  /// `Object.defineProperties(Game_BattlerBase.prototype, { mhp: { get: … } })`），
  /// 但插件（YEP、VisuStella）经常把它们改写成方法。两种形态都必须能读：
  /// 只写 `obj.mhp` 在方法实现下拿到的是函数，`JSON.stringify` 会把它整个丢掉 ——
  /// 出站 payload 里连字段都没有，Host 侧非可选解码直接失败。
  function numericProp(object, name, fallback) {
    try {
      var value = object ? object[name] : undefined;
      if (typeof value === 'function') { value = value.call(object); }
      if (typeof value === 'number' && isFinite(value)) { return value; }
    } catch (e) { /* 半初始化对象：走 fallback */ }
    return (typeof fallback === 'number') ? fallback : 0;
  }

  function mapIdOf(map) {
    if (!map) { return 0; }
    try { return (typeof map.mapId === 'function') ? map.mapId() : (map._mapId || 0); } catch (e) { return 0; }
  }

  function currentEvent() {
    try {
      var map = global.$gameMap;
      if (!map) { return null; }
      var interp = map._interpreter;
      if (!interp) { return null; }
      var eventId = (typeof interp.eventId === 'function') ? interp.eventId() : interp._eventId;
      if (!eventId) { return null; }
      return (typeof map.event === 'function') ? map.event(eventId) : null;
    } catch (e) { return null; }
  }

  function sceneName() {
    try {
      var scene = global.SceneManager && global.SceneManager._scene;
      if (scene && scene.constructor && scene.constructor.name) { return scene.constructor.name; }
    } catch (e) { /* ignore */ }
    return '';
  }

  // ---- 只读 ----

  function cheatSnapshot() {
    var out = {
      scene: sceneName(),
      mapId: 0,
      mapName: '',
      gold: 0,
      frames: 0,
      speed: speedState.multiplier,
      godMode: godModeState.on,
      player: null,
      party: [],
      cheats: cheatLog.slice(0)
    };
    try {
      if (global.Graphics && typeof global.Graphics.frameCount === 'number') { out.frames = global.Graphics.frameCount; }
    } catch (e) { /* ignore */ }
    if (!global.$gameParty) { return out; }
    try {
      out.gold = global.$gameParty._gold || 0;
      var map = global.$gameMap;
      out.mapId = mapIdOf(map);
      out.mapName = (map && typeof map.displayName === 'function') ? (map.displayName() || '') : '';
      var player = global.$gamePlayer;
      if (player) {
        out.player = {
          x: player._x || 0,
          y: player._y || 0,
          dir: player._direction || 2,
          through: !!player._through
        };
      }
      var members = (typeof global.$gameParty.members === 'function') ? global.$gameParty.members() : [];
      for (var i = 0; i < members.length; i++) {
        var member = members[i];
        out.party.push({
          id: numericProp(member, 'actorId', (member && member._actorId) || 0),
          name: (member && typeof member.name === 'function') ? (member.name() || '') : '',
          level: numericProp(member, 'level', (member && member._level) || 1),
          hp: numericProp(member, 'hp', (member && member._hp) || 0),
          mhp: numericProp(member, 'mhp', 0),
          mp: numericProp(member, 'mp', (member && member._mp) || 0),
          mmp: numericProp(member, 'mmp', 0)
        });
      }
    } catch (e) { /* 半初始化状态：返回已有字段 */ }
    return out;
  }

  function cheatListVariables(args) {
    requireGame();
    var names = (global.$dataSystem && global.$dataSystem.variables) || [];
    var from = clampInt(args.from, 1, 1);
    var count = clampInt(args.count, 200, 1, 500);
    var out = [];
    for (var i = from; i < from + count && i < names.length; i++) {
      out.push({ id: i, name: names[i] || '', value: safeValue(global.$gameVariables.value(i), 1) });
    }
    return out;
  }

  function cheatListSwitches(args) {
    requireGame();
    var names = (global.$dataSystem && global.$dataSystem.switches) || [];
    var from = clampInt(args.from, 1, 1);
    var count = clampInt(args.count, 200, 1, 500);
    var onlyOn = !!args.onlyOn;
    var out = [];
    for (var i = from; i < from + count && i < names.length; i++) {
      var value = !!global.$gameSwitches.value(i);
      if (onlyOn && !value) { continue; }
      out.push({ id: i, name: names[i] || '', value: value });
    }
    return out;
  }

  function cheatListItems(args) {
    requireGame();
    var kind = args.kind || 'item';
    var table = dataTableOf(kind);
    var ownedOnly = !!args.ownedOnly;
    var out = [];
    for (var i = 1; i < table.length && out.length < 1000; i++) {
      var entry = table[i];
      if (!entry) { continue; }
      var count = 0;
      try { count = global.$gameParty.numItems(entry); } catch (e) { count = 0; }
      if (ownedOnly && count <= 0) { continue; }
      out.push({
        id: i,
        kind: kind,
        name: entry.name || '',
        description: entry.description || '',
        iconIndex: entry.iconIndex || 0,
        price: entry.price || 0,
        count: count
      });
    }
    return out;
  }

  function cheatListActors() {
    requireGame();
    var table = global.$dataActors || [];
    var out = [];
    for (var i = 1; i < table.length && out.length < 200; i++) {
      var data = table[i];
      if (!data) { continue; }
      var actor = null;
      try { actor = global.$gameActors.actor(i); } catch (e) { actor = null; }
      var item = {
        id: i,
        name: data.name || '',
        nickname: data.nickname || '',
        classId: data.classId || 0,
        className: '',
        level: 1,
        exp: 0,
        hp: 0, mhp: 0, mp: 0, mmp: 0, tp: 0,
        params: [],
        equips: [],
        states: []
      };
      if (actor) {
        try {
          item.nickname = actor.nickname ? actor.nickname() : item.nickname;
          item.classId = numericProp(actor, 'classId', actor._classId || item.classId);
          item.level = numericProp(actor, 'level', (actor._level) || 1);
          item.exp = (typeof actor.currentExp === 'function') ? actor.currentExp() : 0;
          item.hp = numericProp(actor, 'hp', (actor._hp) || 0);
          item.mhp = numericProp(actor, 'mhp', 0);
          item.mp = numericProp(actor, 'mp', (actor._mp) || 0);
          item.mmp = numericProp(actor, 'mmp', 0);
          item.tp = numericProp(actor, 'tp', (actor._tp) || 0);
          if (typeof actor.param === 'function') {
            for (var p = 0; p < 8; p++) { item.params.push(actor.param(p)); }
          }
          var equips = (typeof actor.equips === 'function') ? actor.equips() : [];
          for (var e = 0; e < equips.length; e++) {
            item.equips.push(equips[e] ? { slotId: e, id: equips[e].id, name: equips[e].name || '' } : null);
          }
          var states = (typeof actor.states === 'function') ? actor.states() : [];
          for (var s = 0; s < states.length; s++) { item.states.push({ id: states[s].id, name: states[s].name || '' }); }
          var dataClass = global.$dataClasses && global.$dataClasses[item.classId];
          item.className = dataClass ? (dataClass.name || '') : '';
        } catch (err) { /* 单个角色异常不影响整表 */ }
      }
      out.push(item);
    }
    return out;
  }

  function pad3(n) {
    var s = String(n);
    while (s.length < 3) { s = '0' + s; }
    return s;
  }

  function loadMapData(mapId) {
    if (!mapId) { return Promise.resolve(global.$dataMap || null); }
    if (mapId === mapIdOf(global.$gameMap) && global.$dataMap) { return Promise.resolve(global.$dataMap); }
    if (typeof fetch !== 'function') { return Promise.resolve(null); }
    return fetch('data/Map' + pad3(mapId) + '.json').then(function (response) {
      return response && response.ok ? response.json() : null;
    })['catch'](function () { return null; });
  }

  function cheatListMapEvents(args) {
    var mapId = clampInt(args.mapId, 0, 0, 9999);
    return loadMapData(mapId).then(function (map) {
      if (!map || !map.events) { return []; }
      var out = [];
      for (var i = 1; i < map.events.length && out.length < 500; i++) {
        var event = map.events[i];
        if (!event) { continue; }
        out.push({
          id: i,
          name: event.name || '',
          x: event.x || 0,
          y: event.y || 0,
          note: event.note || ''
        });
      }
      return out;
    });
  }

  /// 传送点：命令码 201（場所移動）或注释里写了 `<TP>` 的事件。
  function cheatTransferPoints(args) {
    var mapId = clampInt(args.mapId, 0, 0, 9999);
    return loadMapData(mapId).then(function (map) {
      if (!map || !map.events) { return []; }
      var out = [];
      for (var i = 1; i < map.events.length && out.length < 500; i++) {
        var event = map.events[i];
        if (!event) { continue; }
        var isTp = (event.note || '').indexOf('<TP>') >= 0;
        var target = null;
        var pages = event.pages || [];
        for (var p = 0; p < pages.length && !isTp; p++) {
          var list = pages[p].list || [];
          for (var c = 0; c < list.length; c++) {
            if (list[c].code === 201) { isTp = true; break; }
          }
        }
        if (!isTp) { continue; }
        out.push({
          mapId: mapId || mapIdOf(global.$gameMap),
          mapName: (global.$dataMapInfos && global.$dataMapInfos[mapId]) ? (global.$dataMapInfos[mapId].name || '') : '',
          eventId: i,
          name: event.name || '',
          x: event.x || 0,
          y: event.y || 0,
          kind: 'event',
          target: target
        });
      }
      return out;
    });
  }

  // ---- 写入 ----

  function cheatSetGold(args) {
    requireGame();
    var current = global.$gameParty._gold || 0;
    var target;
    if (typeof args.value === 'number') { target = Math.floor(args.value); }
    else if (typeof args.delta === 'number') { target = current + Math.floor(args.delta); }
    else { throw rpcError('cheat_bad_args', '需要 value 或 delta'); }
    if (target < 0) { target = 0; }
    if (target > 99999999) { target = 99999999; }
    if (typeof global.$gameParty.gainGold === 'function') {
      global.$gameParty.gainGold(target - current);
    } else {
      global.$gameParty._gold = target;
    }
    logCheat('setGold', current + '→' + target);
    return { gold: global.$gameParty._gold || 0 };
  }

  function cheatSetVariable(args) {
    requireGame();
    var names = (global.$dataSystem && global.$dataSystem.variables) || [];
    var id = requireId(args.id, names.length - 1, '変数 id');
    global.$gameVariables.setValue(id, args.value === undefined ? 0 : args.value);
    logCheat('setVariable', id + '=' + String(args.value));
    return { id: id, value: safeValue(global.$gameVariables.value(id), 1) };
  }

  function cheatSetSwitch(args) {
    requireGame();
    var names = (global.$dataSystem && global.$dataSystem.switches) || [];
    var id = requireId(args.id, names.length - 1, 'スイッチ id');
    var on = !!args.on;
    global.$gameSwitches.setValue(id, on);
    logCheat('setSwitch', id + '=' + on);
    return { id: id, value: on };
  }

  function cheatSetSelfSwitch(args) {
    requireGame();
    var mapId = clampInt(args.mapId, mapIdOf(global.$gameMap), 1, 9999);
    var eventId = requireId(args.eventId, 9999, 'eventId');
    var letter = String(args.letter || 'A').toUpperCase().charAt(0);
    if (['A', 'B', 'C', 'D'].indexOf(letter) < 0) { throw rpcError('cheat_bad_args', 'letter 必须是 A-D'); }
    var on = !!args.on;
    global.$gameSelfSwitches.setValue([mapId, eventId, letter], on);
    logCheat('setSelfSwitch', mapId + '/' + eventId + '/' + letter + '=' + on);
    return { mapId: mapId, eventId: eventId, letter: letter, value: on };
  }

  function cheatToggleAllSwitches(args) {
    requireGame();
    var names = (global.$dataSystem && global.$dataSystem.switches) || [];
    var on = !!args.on;
    var changed = 0;
    for (var i = 1; i < names.length && i < 5000; i++) {
      global.$gameSwitches.setValue(i, on);
      changed++;
    }
    logCheat('toggleAllSwitches', on + ' ×' + changed);
    return { changed: changed, on: on };
  }

  function cheatToggleAllSelfSwitches(args) {
    requireGame();
    var on = !!args.on;
    var mapId = mapIdOf(global.$gameMap);
    var events = (global.$gameMap && typeof global.$gameMap.events === 'function') ? global.$gameMap.events() : [];
    var letters = ['A', 'B', 'C', 'D'];
    var changed = 0;
    for (var e = 0; e < events.length && changed < 2000; e++) {
      var event = events[e];
      if (!event) { continue; }
      var eventId = event.eventId ? event.eventId() : event._eventId;
      for (var i = 0; i < letters.length; i++) {
        global.$gameSelfSwitches.setValue([mapId, eventId, letters[i]], on);
        changed++;
      }
    }
    logCheat('toggleAllSelfSwitches', on + ' ×' + changed);
    return { changed: changed, on: on, mapId: mapId };
  }

  function cheatGiveItem(args) {
    requireGame();
    var kind = args.kind || 'item';
    var entry = dataEntryOf(kind, optionalId(args.id, 99999, 'id', 1));
    var count = clampInt(args.count, 1, -999, 9999);
    global.$gameParty.gainItem(entry, count);
    logCheat('giveItem', kind + '#' + args.id + ' x' + count);
    return { id: entry.id, kind: kind, count: global.$gameParty.numItems(entry) };
  }

  function cheatSetItemCount(args) {
    requireGame();
    var kind = args.kind || 'item';
    var entry = dataEntryOf(kind, optionalId(args.id, 99999, 'id', 1));
    var target = clampInt(args.count, 0, 0, 9999);
    var current = global.$gameParty.numItems(entry);
    if (target > current) { global.$gameParty.gainItem(entry, target - current); }
    else if (target < current) { global.$gameParty.loseItem(entry, current - target); }
    logCheat('setItemCount', kind + '#' + args.id + '=' + target);
    return { id: entry.id, kind: kind, count: global.$gameParty.numItems(entry) };
  }

  function cheatUpdateActor(args) {
    requireGame();
    var actor = actorOf(optionalId(args.id, 99999, 'id', 1));
    // 装备清单在任何状态改动之前先全量校验：非法批次整批拒绝，
    // 不会留下 level 已改、装备只装了一半的中间态。
    var equipPlan = (Object.prototype.toString.call(args.equips) === '[object Array]' &&
                     typeof actor.changeEquip === 'function')
      ? resolveEquips(actor, args.equips) : null;
    var changed = [];
    if (typeof args.level === 'number' && typeof actor.changeLevel === 'function') {
      actor.changeLevel(clampInt(args.level, actor._level || 1, 1, 99), false);
      changed.push('level');
    }
    if (typeof args.exp === 'number' && typeof actor.changeExp === 'function') {
      actor.changeExp(clampInt(args.exp, 0, 0, 99999999), false);
      changed.push('exp');
    }
    if (typeof args.hp === 'number' && typeof actor.setHp === 'function') {
      actor.setHp(clampInt(args.hp, 0, 0, 999999)); changed.push('hp');
    }
    if (typeof args.mp === 'number' && typeof actor.setMp === 'function') {
      actor.setMp(clampInt(args.mp, 0, 0, 999999)); changed.push('mp');
    }
    if (typeof args.tp === 'number' && typeof actor.setTp === 'function') {
      actor.setTp(clampInt(args.tp, 0, 0, 100)); changed.push('tp');
    }
    if (typeof args.nickname === 'string' && typeof actor.changeNickname === 'function') {
      actor.changeNickname(args.nickname); changed.push('nickname');
    }
    if (args.classId !== undefined && args.classId !== null && typeof actor.changeClass === 'function') {
      var classMax = ((global.$dataClasses && global.$dataClasses.length) || 1) - 1;
      actor.changeClass(requireId(args.classId, classMax, 'classId'), true); changed.push('classId');
    }
    if (Object.prototype.toString.call(args.params) === '[object Array]' && typeof actor.addParam === 'function') {
      actor._paramPlus = [0, 0, 0, 0, 0, 0, 0, 0];
      for (var p = 0; p < args.params.length && p < 8; p++) {
        if (typeof args.params[p] === 'number') { actor.addParam(p, Math.floor(args.params[p])); }
      }
      changed.push('params');
    }
    if (Object.prototype.toString.call(args.states) === '[object Array]') {
      if (typeof actor.clearStates === 'function') { actor.clearStates(); }
      for (var s = 0; s < args.states.length; s++) {
        var stateId = clampInt(args.states[s], 0, 0, 9999);
        if (stateId > 0 && typeof actor.addState === 'function') { actor.addState(stateId); }
      }
      changed.push('states');
    }
    if (equipPlan) {
      for (var e = 0; e < equipPlan.length; e++) {
        actor.changeEquip(equipPlan[e].slotId, equipPlan[e].item);
      }
      changed.push('equips');
    }
    logCheat('updateActor', '#' + args.id + ' ' + changed.join(','));
    return { id: args.id, changed: changed };
  }

  function cheatRecoverAll(args) {
    requireGame();
    var scope = args.scope || 'party';
    var members = (typeof global.$gameParty.members === 'function') ? global.$gameParty.members() : [];
    for (var i = 0; i < members.length; i++) {
      try { members[i].recoverAll(); } catch (e) { /* ignore */ }
    }
    logCheat('recoverAll', scope);
    return { count: members.length };
  }

  function cheatPartyMember(args) {
    requireGame();
    var actorId = requireId(args.actorId, 99999, 'actorId');
    var add = !!args.add;
    if (add && typeof global.$gameParty.addActor === 'function') { global.$gameParty.addActor(actorId); }
    if (!add && typeof global.$gameParty.removeActor === 'function') { global.$gameParty.removeActor(actorId); }
    logCheat('partyMember', (add ? 'add ' : 'remove ') + actorId);
    var members = (typeof global.$gameParty.members === 'function') ? global.$gameParty.members() : [];
    var ids = [];
    for (var i = 0; i < members.length; i++) { ids.push(members[i].actorId ? members[i].actorId() : 0); }
    return { members: ids };
  }

  function cheatGodMode(args) {
    requireGame();
    godModeState.on = !!args.on;
    if (typeof args.lockHp === 'boolean') { godModeState.lockHp = args.lockHp; }
    if (typeof args.lockMp === 'boolean') { godModeState.lockMp = args.lockMp; }
    patchGodMode();
    logCheat('godMode', godModeState.on + ' hp=' + godModeState.lockHp + ' mp=' + godModeState.lockMp);
    return { on: godModeState.on, lockHp: godModeState.lockHp, lockMp: godModeState.lockMp };
  }

  function patchGodMode() {
    try {
      var GA = global.Game_Actor;
      if (!GA || !GA.prototype) { return false; }
      if (!godModeState.baseSetHp && typeof GA.prototype.setHp === 'function') { godModeState.baseSetHp = GA.prototype.setHp; }
      if (!godModeState.baseSetMp && typeof GA.prototype.setMp === 'function') { godModeState.baseSetMp = GA.prototype.setMp; }
      if (!godModeState.wrapped && godModeState.baseSetHp) {
        var baseHp = godModeState.baseSetHp;
        GA.prototype.setHp = function (hp) {
          if (godModeState.on && godModeState.lockHp) {
            // 必须用 numericProp：MV 的部分版本/插件把 `mhp` 实现成方法，
            // 直接 `this.mhp` 拿到的是函数，`setHp(函数)` 会被引擎算成 0 ——
            // 表现是"开无敌当场把血清零"，比不开还危险。
            hp = numericProp(this, 'mhp', hp);
          }
          return baseHp.call(this, hp);
        };
        var baseMp = godModeState.baseSetMp;
        if (baseMp) {
          GA.prototype.setMp = function (mp) {
            if (godModeState.on && godModeState.lockMp) {
              mp = numericProp(this, 'mmp', mp);
            }
            return baseMp.call(this, mp);
          };
        }
        godModeState.wrapped = true;
      }
      return true;
    } catch (e) { return false; }
  }

  // ---- 世界/流程 ----

  function cheatNoclip(args) {
    requireGame();
    var on = !!args.on;
    if (!global.$gamePlayer || typeof global.$gamePlayer.setThrough !== 'function') {
      throw rpcError('cheat_unavailable', '$gamePlayer.setThrough 不存在');
    }
    global.$gamePlayer.setThrough(on);
    logCheat('noclip', on);
    return { on: on };
  }

  function cheatEncounter(args) {
    requireGame();
    var on = !!args.on;                    // on = 允许遇敌
    var system = global.$gameSystem;
    if (!system) { throw rpcError('cheat_unavailable', '$gameSystem 不存在'); }
    if (typeof system._encounterEnabled === 'boolean') { system._encounterEnabled = on; }
    try {
      if (on && typeof system.enableEncounter === 'function') { system.enableEncounter(); }
      if (!on && typeof system.disableEncounter === 'function') { system.disableEncounter(); }
    } catch (e) { /* ignore */ }
    logCheat('encounter', 'enabled=' + on);
    return { encounterEnabled: on };
  }

  function cheatAlwaysDash(args) {
    requireGame();
    var on = !!args.on;
    try { global.$gameSystem._alwaysDash = on; } catch (e) { /* ignore */ }
    try { if (global.ConfigManager) { global.ConfigManager.alwaysDash = on; } } catch (e2) { /* ignore */ }
    logCheat('alwaysDash', on);
    return { on: on };
  }

  function cheatFollowers(args) {
    requireGame();
    var on = !!args.on;
    var player = global.$gamePlayer;
    var followers = null;
    try {
      followers = (player && typeof player.followers === 'function') ? player.followers() : (player && player._followers);
    } catch (e) { followers = null; }
    if (!followers) { throw rpcError('cheat_unavailable', 'followers 不存在（MV 需开启跟随）'); }
    if (typeof followers._visible === 'boolean') { followers._visible = on; }
    else if (typeof followers.setVisible === 'function') { followers.setVisible(on); }
    if (typeof followers.refresh === 'function') { followers.refresh(); }
    logCheat('followers', on);
    return { on: on };
  }

  function cheatUnlockEquip() {
    requireGame();
    var table = global.$dataActors || [];
    var touched = 0;
    for (var i = 1; i < table.length; i++) {
      if (!table[i]) { continue; }
      var actor = null;
      try { actor = global.$gameActors.actor(i); } catch (e) { actor = null; }
      if (!actor || !(Object.prototype.toString.call(actor._equipSlots) === '[object Array]')) { continue; }
      try {
        var slots = actor._equipSlots || [];
        var changed = false;
        for (var s = 0; s < 5; s++) {
          if (slots.indexOf(s) < 0) { slots.push(s); changed = true; }
        }
        if (changed) {
          slots.sort(function (a, b) { return a - b; });
          while (actor._equips.length < slots.length) { actor._equips.push(null); }
          touched++;
        }
      } catch (err) { /* ignore */ }
    }
    logCheat('unlockEquip', '×' + touched);
    return { touched: touched };
  }

  function cheatUnlockChoice() {
    requireGame();
    try { if (global.$gameSystem) { global.$gameSystem._choiceLock = false; } } catch (e) { /* ignore */ }
    try {
      if (global.ConfigManager) {
        global.ConfigManager.alwaysDash = true;
        global.ConfigManager.commandRemember = true;
      }
    } catch (e2) { /* ignore */ }
    logCheat('unlockChoice', '');
    return { ok: true };
  }

  function cheatSpeed(args) {
    requireGame();
    var multiplier = (typeof args.multiplier === 'number' && isFinite(args.multiplier)) ? args.multiplier : 1;
    if (multiplier < 0.25) { multiplier = 0.25; }
    if (multiplier > 8) { multiplier = 8; }
    applySpeed(multiplier);
    logCheat('speed', '×' + multiplier);
    return { multiplier: multiplier };
  }

  function applySpeed(multiplier) {
    var SM = global.SceneManager;
    if (!SM || typeof SM.update !== 'function') { throw rpcError('cheat_unavailable', 'SceneManager.update 不存在'); }
    if (!speedState.base) { speedState.base = SM.update; }
    var base = speedState.base;
    speedState.multiplier = multiplier;
    if (multiplier === 1) {
      SM.update = base;
      speedState.base = null;
      speedState.wrapped = false;
      speedState.acc = 0;
      return;
    }
    if (!speedState.wrapped) {
      SM.update = function (delta) {
        var times = Math.floor(speedState.multiplier);
        for (var i = 0; i < times; i++) { base.call(this, delta); }
        var fraction = speedState.multiplier - times;
        if (fraction > 0) {
          speedState.acc += fraction;
          if (speedState.acc >= 1) { speedState.acc -= 1; base.call(this, delta); }
        }
      };
      speedState.wrapped = true;
    }
  }

  function cheatMoveSpeed(args) {
    requireGame();
    var player = global.$gamePlayer;
    if (!player) { throw rpcError('cheat_unavailable', '$gamePlayer 不存在'); }
    var base = (typeof player._moveSpeed === 'number') ? player._moveSpeed : 4;
    var target = (typeof args.value === 'number') ? args.value : base + (typeof args.delta === 'number' ? args.delta : 0);
    target = Math.max(1, Math.min(6, Math.round(target)));
    player._moveSpeed = target;
    logCheat('moveSpeed', String(target));
    return { moveSpeed: target };
  }

  function cheatTeleport(args) {
    requireGame();
    var mapId = requireId(args.mapId, 9999, 'mapId');
    var x = clampInt(args.x, 0, 0, 999);
    var y = clampInt(args.y, 0, 0, 999);
    var dir = clampInt(args.dir, 0, 0, 9);
    if (typeof global.$gamePlayer.reserveTransfer !== 'function') {
      throw rpcError('cheat_unavailable', 'reserveTransfer 不存在');
    }
    global.$gamePlayer.reserveTransfer(mapId, x, y, dir, 0);
    if (sceneName() !== 'Scene_Map' && typeof global.Scene_Map === 'function') {
      global.SceneManager.goto(global.Scene_Map);
    }
    logCheat('teleport', mapId + ',' + x + ',' + y);
    return { mapId: mapId, x: x, y: y };
  }

  var SCENE_NAMES = {
    menu: 'Scene_Menu', save: 'Scene_Save', load: 'Scene_Load', options: 'Scene_Options',
    status: 'Scene_Status', equip: 'Scene_Equip', skill: 'Scene_Skill', item: 'Scene_Item',
    formation: 'Scene_Formation', debug: 'Scene_Debug', title: 'Scene_Title', map: 'Scene_Map',
    gameover: 'Scene_Gameover', shop: 'Scene_Shop'
  };

  function cheatScene(args) {
    requireGame();
    var name = String(args.name || '');
    var ctor = global[SCENE_NAMES[name] || name];
    if (typeof ctor !== 'function') { throw rpcError('cheat_bad_args', '未知场景: ' + name); }
    if (name === 'title' || name === 'map' || name === 'gameover') {
      global.SceneManager.goto(ctor);
    } else {
      global.SceneManager.push(ctor);
    }
    logCheat('scene', name);
    return { scene: name };
  }

  function cheatScenePop() {
    requireGame();
    global.SceneManager.pop();
    logCheat('scenePop', '');
    return { scene: sceneName() };
  }

  function cheatBattle(args) {
    requireGame();
    var op = String(args.op || '');
    var BM = global.BattleManager;
    if (!BM) { throw rpcError('cheat_unavailable', 'BattleManager 不存在'); }
    var inBattle = !!BM._phase;
    if (op === 'killAll' || op === 'win') {
      try {
        var troop = global.$gameTroop;
        if (troop && typeof troop.members === 'function') {
          var members = troop.members();
          for (var i = 0; i < members.length; i++) {
            try { members[i].setHp(0); } catch (e) { /* ignore */ }
            try { members[i].die(); } catch (e2) { /* ignore */ }
          }
        }
      } catch (e3) { /* ignore */ }
      if (op === 'win' && inBattle && typeof BM.processVictory === 'function') { BM.processVictory(); }
    } else if (op === 'escape') {
      if (typeof BM.processEscape === 'function') { BM.processEscape(); }
    } else if (op === 'lose') {
      try {
        var party = global.$gameParty.members();
        for (var p = 0; p < party.length; p++) { try { party[p].setHp(1); } catch (e) { /* ignore */ } }
      } catch (e4) { /* ignore */ }
      if (typeof BM.processDefeat === 'function') { BM.processDefeat(); }
    } else {
      throw rpcError('cheat_bad_args', '未知战斗操作: ' + op);
    }
    logCheat('battle', op);
    return { op: op, inBattle: inBattle };
  }

  function cheatClearPictures() {
    requireGame();
    if (!global.$gameScreen || typeof global.$gameScreen.clearPictures !== 'function') {
      throw rpcError('cheat_unavailable', 'clearPictures 不存在');
    }
    global.$gameScreen.clearPictures();
    logCheat('clearPictures', '');
    return { ok: true };
  }

  function cheatClearEvent() {
    requireGame();
    var event = currentEvent();
    if (!event) { return { erased: false }; }
    if (typeof event.erase === 'function') { event.erase(); }
    logCheat('clearEvent', '');
    return { erased: true };
  }

  function cheatClearMoveRoute() {
    requireGame();
    var cleared = 0;
    try { global.$gamePlayer.clearMoveRoute(); cleared++; } catch (e) { /* ignore */ }
    try {
      var event = currentEvent();
      if (event && typeof event.clearMoveRoute === 'function') { event.clearMoveRoute(); cleared++; }
    } catch (e2) { /* ignore */ }
    logCheat('clearMoveRoute', '×' + cleared);
    return { cleared: cleared };
  }

  function cheatCloseAllWindows() {
    requireGame();
    var closed = 0;
    try {
      var scene = global.SceneManager._scene;
      var layer = scene && scene._windowLayer;
      var children = (layer && layer.children) ? layer.children : [];
      for (var i = 0; i < children.length; i++) {
        if (children[i] && typeof children[i].close === 'function') { children[i].close(); closed++; }
      }
    } catch (e) { /* ignore */ }
    logCheat('closeAllWindows', '×' + closed);
    return { closed: closed };
  }

  function cheatFadeIn() {
    requireGame();
    if (!global.$gameScreen || typeof global.$gameScreen.startFadeIn !== 'function') {
      throw rpcError('cheat_unavailable', 'startFadeIn 不存在');
    }
    global.$gameScreen.startFadeIn(30);
    logCheat('fadeIn', '');
    return { ok: true };
  }

  function cheatRecover() {
    return cheatRecoverAll({ scope: 'party' });
  }

  function cheatRepair() {
    requireGame();
    var fixed = [];
    try {
      var scene = global.SceneManager._scene;
      if (scene && typeof scene._waitCount === 'number' && scene._waitCount > 0) {
        scene._waitCount = 0; fixed.push('scene.wait');
      }
      var interp = global.$gameMap && global.$gameMap._interpreter;
      if (interp && typeof interp._waitCount === 'number' && interp._waitCount > 0) {
        interp._waitCount = 0; fixed.push('interpreter.wait');
      }
      if (global.Graphics) {
        if (global.Graphics._errorShowed) { global.Graphics._errorShowed = false; fixed.push('graphics.error'); }
        if (global.Graphics._errorPrinter && typeof global.Graphics._errorPrinter.clear === 'function') {
          try { global.Graphics._errorPrinter.clear(); fixed.push('graphics.printer'); } catch (e) { /* ignore */ }
        }
      }
      if (scene && typeof scene.refresh === 'function') { try { scene.refresh(); fixed.push('scene.refresh'); } catch (e2) { /* ignore */ } }
    } catch (e3) { /* ignore */ }
    logCheat('repair', fixed.join(','));
    return { fixed: fixed };
  }

  function cheatFixError() {
    var result = cheatRepair();
    try {
      if (global.$gameTemp && typeof global.$gameTemp.clearDestination === 'function') {
        global.$gameTemp.clearDestination();
      }
    } catch (e) { /* ignore */ }
    return result;
  }

  function cheatDevTools() {
    var opened = false;
    try {
      if (typeof global.require === 'function') {
        var nw = null;
        try { nw = global.require('nw.gui'); } catch (e) { nw = null; }
        if (nw && nw.Window && typeof nw.Window.get === 'function') {
          nw.Window.get().showDevTools();
          opened = true;
        } else if (global.nw && global.nw.Window) {
          global.nw.Window.get().showDevTools();
          opened = true;
        }
      }
    } catch (e2) { opened = false; }
    if (!opened) {
      return { opened: false, hint: '当前内核没有 NW.js 菜单；请用 CDP/宿主开发者工具查看控制台' };
    }
    logCheat('devTools', '');
    return { opened: true };
  }

  // ---- 任意对象路径（受控） ----

  function assertSafePath(path) {
    if (typeof path !== 'string' || !path) { throw rpcError('cheat_bad_args', 'path 不能为空'); }
    var parts = path.split('.');
    if (parts.length < 2 || parts.length > 8) { throw rpcError('cheat_bad_args', 'path 深度必须是 2..8'); }
    if (!/^\$game[A-Za-z0-9_]*$/.test(parts[0]) && !/^\$data[A-Za-z0-9_]*$/.test(parts[0]) && parts[0] !== '$gameTemp') {
      throw rpcError('cheat_forbidden', '只允许 $game* / $data* 开头的路径: ' + parts[0]);
    }
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i];
      if (part === '__proto__' || part === 'constructor' || part === 'prototype') {
        throw rpcError('cheat_forbidden', '禁止的路径段: ' + part);
      }
    }
    return parts;
  }

  function resolvePath(parts) {
    var cursor = global;
    for (var i = 0; i < parts.length; i++) {
      if (cursor === null || cursor === undefined) { throw rpcError('cheat_out_of_range', '路径不存在: ' + parts.join('.')); }
      cursor = cursor[parts[i]];
    }
    if (cursor === undefined) { throw rpcError('cheat_out_of_range', '路径不存在: ' + parts.join('.')); }
    return cursor;
  }

  function cheatObjectPath(args) {
    var parts = assertSafePath(args.path);
    var value = resolvePath(parts);
    return { path: args.path, type: typeof value, value: safeValue(value, 0) };
  }

  function cheatSetObjectPath(args) {
    var parts = assertSafePath(args.path);
    var value = args.value;
    if (typeof value !== 'string' && typeof value !== 'number' && typeof value !== 'boolean') {
      throw rpcError('cheat_bad_args', '只允许写入 string/number/boolean');
    }
    var parent = global;
    for (var i = 0; i < parts.length - 1; i++) {
      if (parent === null || parent === undefined) { throw rpcError('cheat_out_of_range', '路径不存在'); }
      parent = parent[parts[i]];
    }
    if (parent === null || parent === undefined) { throw rpcError('cheat_out_of_range', '父路径不存在'); }
    parent[parts[parts.length - 1]] = value;
    logCheat('setObjectPath', args.path + '=' + String(value));
    return { path: args.path, value: safeValue(parent[parts[parts.length - 1]], 0) };
  }

  // ------------------------------------------------------------------
  // 全文扫描（text.scanStart / scanCancel）
  //
  // 三源合并：$data* 递归 + data/Map*.json 全量 + 运行期绘制过的串。
  // 分片 200 条 + setTimeout(0)：原版 MTool 会卡住数秒~数十分钟（`trsLoading`），
  // 我们不允许把主线程焊死 —— 片间让出事件循环，渲染与输入照常。
  // ------------------------------------------------------------------

  var scans = {};
  var scanSeq = 0;

  var EVENT_TEXT_CODES = {
    401: [0],   // 文章
    405: [0],   // スクロール文章
    101: [4],   // 顔グラ付き文章（最后一项才是正文）
    102: [0],   // 選択肢（数组）
    320: [1],   // アクター名の変更（[0]=actorId）
    324: [1],   // 二つ名の変更（[0]=actorId）
    325: [1]    // プロフィールの変更（[0]=actorId）
  };

  function scanCandidate(raw) {
    if (typeof raw !== 'string') { return false; }
    var text = raw.replace(/^\s+|\s+$/g, '');
    if (text.length < 2 || text.length > 2000) { return false; }
    if (/^[0-9]+$/.test(text)) { return false; }
    if (/^(https?:|file:|\/|\.\/|\.\.\/)/i.test(text)) { return false; }
    if (/^<[^>]*>$/.test(text)) { return false; }
    // 纯 ASCII 且不含空白：视为标识符/资源名（Window_Base、img/faces/Actor1），不送翻译。
    if (/^[\x20-\x7E]+$/.test(text) && !/\s/.test(text)) { return false; }
    return true;
  }

  function pushScanItem(scan, item) {
    if (!item || !scanCandidate(item.raw)) { scan.skipped++; return; }
    var key = 'k:' + item.raw;
    if (scan.seen[key]) { return; }
    scan.seen[key] = 1;
    scan.pending.push({ raw: item.raw, source: item.source || '', path: item.path || '' });
    scan.total++;
  }

  /// 扫描取串时的"原文旁路"：数据回写之后 $data* 里躺着的是中文，照抄当前值等于把译文
  /// 当原文收进语料（Host 的 SkipRules 判 chinese 直接跳过，这些字段永远拿不到译文，
  /// 原文列也被中文顶掉）。命中账本就换回账本里的 original。
  /// 只有「表 + 索引 + 顶层字段」有账本；深层字段与非白名单表原样返回。
  function dataScanRaw(value, origin, field) {
    if (!origin || !field) { return value; }
    var rec = dataPatchByKey[dataPatchKey(origin.table, origin.index, field)];
    return (rec && typeof rec.original === 'string') ? rec.original : value;
  }

  /// @param {object} origin 本记录在账本里的坐标 `{ table: '$dataActors', index: 1 }`；
  ///                        只有顶层字段（数组/对象的第一层属性）参与原文替换。
  /// @param {string} field  当前值所属的顶层字段名（level 0 的子节点才带）。
  function walkDataStrings(value, source, path, scan, depth, origin, field) {
    var level = depth || 0;
    if (level > 6 || value === null || value === undefined) { return; }
    if (typeof value === 'string') {
      pushScanItem(scan, { raw: dataScanRaw(value, origin, field), source: source, path: path });
      return;
    }
    if (Object.prototype.toString.call(value) === '[object Array]') {
      if (value.length > 5000) { return; }   // 瓦片数据/大数组：不是文本
      for (var i = 0; i < value.length; i++) {
        walkDataStrings(value[i], source, path + '[' + i + ']', scan, level + 1, origin, null);
      }
      return;
    }
    if (typeof value !== 'object') { return; }
    for (var key in value) {
      if (!Object.prototype.hasOwnProperty.call(value, key)) { continue; }
      if (key === '__proto__' || key === 'constructor' || key === 'prototype') { continue; }
      walkDataStrings(value[key], source, path ? (path + '.' + key) : key, scan, level + 1,
        origin, level === 0 ? key : null);
    }
  }

  function collectCommandText(list, source, path, scan) {
    if (!list || !list.length) { return; }
    for (var i = 0; i < list.length; i++) {
      var command = list[i];
      if (!command) { continue; }
      var indexes = EVENT_TEXT_CODES[command.code];
      if (!indexes) { continue; }
      var params = command.parameters || [];
      for (var p = 0; p < indexes.length; p++) {
        var value = params[indexes[p]];
        if (typeof value === 'string') {
          pushScanItem(scan, { raw: value, source: source, path: path + '[' + i + '].p' + indexes[p] });
        } else if (Object.prototype.toString.call(value) === '[object Array]') {
          for (var v = 0; v < value.length; v++) {
            if (typeof value[v] === 'string') {
              pushScanItem(scan, { raw: value[v], source: source, path: path + '[' + i + '].p' + indexes[p] + '[' + v + ']' });
            }
          }
        }
      }
    }
  }

  function collectMapText(map, mapId, scan) {
    if (!map) { return; }
    var events = map.events || [];
    for (var i = 1; i < events.length; i++) {
      var event = events[i];
      if (!event || !event.pages) { continue; }
      for (var p = 0; p < event.pages.length; p++) {
        collectCommandText(event.pages[p].list, 'map', 'map.' + mapId + '.ev' + i + '.p' + p, scan);
      }
    }
    // 地图备注也可能被插件当作文本（`<TP>` 之类会命中，由 scanCandidate 的 <> 规则排除）
    if (typeof map.note === 'string') {
      pushScanItem(scan, { raw: map.note, source: 'map', path: 'map.' + mapId + '.note' });
    }
  }

  function collectDataText(scan) {
    var defs = [
      ['actor', '$dataActors'],
      ['class', '$dataClasses'],
      ['skill', '$dataSkills'],
      ['item', '$dataItems'],
      ['weapon', '$dataWeapons'],
      ['armor', '$dataArmors'],
      ['enemy', '$dataEnemies'],
      ['state', '$dataStates'],
      ['animation', '$dataAnimations'],
      ['tileset', '$dataTilesets']
    ];
    for (var d = 0; d < defs.length; d++) {
      var table = global[defs[d][1]];
      if (!table) { continue; }
      for (var i = 1; i < table.length; i++) {
        if (!table[i]) { continue; }
        walkDataStrings(table[i], defs[d][0], defs[d][0] + '.' + i, scan, 0,
          { table: defs[d][1], index: i }, null);
      }
    }
    if (global.$dataSystem) {
      walkDataStrings(global.$dataSystem, 'system', 'system', scan, 0, null, null);
    }
    if (global.$dataMapInfos) {
      for (var m = 1; m < global.$dataMapInfos.length; m++) {
        var info = global.$dataMapInfos[m];
        if (info && typeof info.name === 'string') {
          pushScanItem(scan, { raw: info.name, source: 'system', path: 'mapInfo.' + m + '.name' });
        }
      }
    }
    var commons = global.$dataCommonEvents || [];
    for (var c = 1; c < commons.length; c++) {
      var common = commons[c];
      if (!common || !common.list) { continue; }
      collectCommandText(common.list, 'common_event', 'common.' + c, scan);
      if (typeof common.name === 'string') {
        pushScanItem(scan, { raw: common.name, source: 'common_event', path: 'common.' + c + '.name' });
      }
    }
    var troops = global.$dataTroops || [];
    for (var t = 1; t < troops.length; t++) {
      var troop = troops[t];
      if (!troop || !troop.pages) { continue; }
      for (var pg = 0; pg < troop.pages.length; pg++) {
        collectCommandText(troop.pages[pg].list, 'troop', 'troop.' + t + '.p' + pg, scan);
      }
    }
    // 当前地图无论如何先收一份（fetch 失败/无 data 目录时的兜底）
    if (global.$dataMap) { collectMapText(global.$dataMap, mapIdOf(global.$gameMap), scan); }
  }

  function fetchAllMaps(scan) {
    if (typeof fetch !== 'function') { return Promise.resolve(); }
    var infos = global.$dataMapInfos || [];
    var ids = [];
    for (var i = 1; i < infos.length; i++) {
      if (infos[i] && typeof infos[i].id === 'number') { ids.push(infos[i].id); }
    }
    var index = 0;
    return new Promise(function (resolve) {
      function next() {
        if (scan.cancelled || index >= ids.length) { resolve(); return; }
        var mapId = ids[index++];
        fetch('data/Map' + pad3(mapId) + '.json')
          .then(function (response) { return (response && response.ok) ? response.json() : null; })
          .then(function (json) {
            if (json) { collectMapText(json, mapId, scan); }
            next();
          })['catch'](function () { next(); });
      }
      next();
    });
  }

  function finishScan(scan, cancelled) {
    if (scan.finished) { return; }
    scan.finished = true;
    if (scan.timer) { try { clearTimeout(scan.timer); } catch (e) { /* ignore */ } scan.timer = null; }
    emit('scanDone', { scanId: scan.id, total: scan.total, skipped: scan.skipped, cancelled: !!cancelled });
    try { delete scans[scan.id]; } catch (e) { scans[scan.id] = null; }
  }

  function pumpScan(scan) {
    if (scan.timer || scan.finished) { return; }
    function step() {
      scan.timer = null;
      if (scan.finished) { return; }
      if (scan.cancelled) { finishScan(scan, true); return; }
      if (scan.pending.length) {
        var chunk = scan.pending.splice(0, 200);
        emit('scanChunk', { scanId: scan.id, seq: scan.seq++, items: chunk });
        scan.timer = setTimeout(step, 0);
        return;
      }
      if (scan.sourcesDone) { finishScan(scan, false); return; }
      scan.timer = setTimeout(step, 50);
    }
    scan.timer = setTimeout(step, 0);
  }

  /// 术语采集：**不走 scanCandidate**。
  ///
  /// 扫描语料会丢弃「纯 ASCII 且无空白」（HP/MP/TP/EXP/Lv）与单字串（運/力），
  /// 而这些恰恰是最需要统一译名的界面术语。这里按引擎真实结构取：
  /// - `terms.basic/commands/params` 是 **0 起、无占位**；
  /// - `elements/skillTypes/weaponTypes/armorTypes/equipTypes` 是 **1 起、[0] 为空**。
  function collectGlossaryTerms() {
    var out = [];
    function add(value, kind, path) {
      if (typeof value !== 'string') { return; }
      var text = value.replace(/^\s+|\s+$/g, '');
      if (!text) { return; }
      out.push({ raw: text, kind: kind, path: path });
    }
    var system = global.$dataSystem || {};
    var terms = system.terms || {};
    var groups = ['basic', 'commands', 'params'];
    for (var g = 0; g < groups.length; g++) {
      var group = groups[g];
      var list = terms[group];
      if (!list || !list.length) { continue; }
      for (var i = 0; i < list.length; i++) {
        add(list[i], 'system', 'system.terms.' + group + '[' + i + ']');
      }
    }
    add(system.currencyUnit, 'system', 'system.currencyUnit');
    var typed = ['elements', 'skillTypes', 'weaponTypes', 'armorTypes', 'equipTypes'];
    for (var t = 0; t < typed.length; t++) {
      var name = typed[t];
      var arr = system[name];
      if (!arr || !arr.length) { continue; }
      for (var k = 1; k < arr.length; k++) {
        add(arr[k], 'type', 'system.' + name + '[' + k + ']');
      }
    }
    return out;
  }

  function textScanStart(args) {
    var scan = {
      id: 'scan-' + (++scanSeq),
      cancelled: false,
      finished: false,
      sourcesDone: false,
      pending: [],
      seen: {},
      seq: 0,
      total: 0,
      skipped: 0,
      timer: null
    };
    scans[scan.id] = scan;
    try { collectDataText(scan); } catch (e) { scan.skipped++; }
    if (!args || args.includeRuntime !== false) {
      for (var i = 0; i < runtimeSeen.length; i++) {
        pushScanItem(scan, { raw: runtimeSeen[i], source: 'runtime', path: 'runtime.' + i });
      }
    }
    var maps = (!args || args.includeMaps !== false) ? fetchAllMaps(scan) : Promise.resolve();
    maps.then(function () {
      scan.sourcesDone = true;
      pumpScan(scan);
    }, function () {
      scan.sourcesDone = true;
      pumpScan(scan);
    });
    return { scanId: scan.id, estimated: scan.total, terms: collectGlossaryTerms() };
  }

  function textScanCancel(args) {
    var scan = scans[args && args.scanId];
    if (!scan) { return { cancelled: false, reason: 'scan_not_found' }; }
    scan.cancelled = true;
    scan.pending = [];
    finishScan(scan, true);
    return { cancelled: true };
  }

  // ------------------------------------------------------------------
  // RPC 分发表
  // ------------------------------------------------------------------

  var RPC = {
    'cheat.snapshot': cheatSnapshot,
    'cheat.listVariables': cheatListVariables,
    'cheat.listSwitches': cheatListSwitches,
    'cheat.listItems': cheatListItems,
    'cheat.listActors': cheatListActors,
    'cheat.listMapEvents': cheatListMapEvents,
    'cheat.transferPoints': cheatTransferPoints,
    'cheat.setGold': cheatSetGold,
    'cheat.setVariable': cheatSetVariable,
    'cheat.setSwitch': cheatSetSwitch,
    'cheat.setSelfSwitch': cheatSetSelfSwitch,
    'cheat.toggleAllSwitches': cheatToggleAllSwitches,
    'cheat.toggleAllSelfSwitches': cheatToggleAllSelfSwitches,
    'cheat.giveItem': cheatGiveItem,
    'cheat.setItemCount': cheatSetItemCount,
    'cheat.updateActor': cheatUpdateActor,
    'cheat.recoverAll': cheatRecoverAll,
    'cheat.addPartyMember': function (args) { return cheatPartyMember({ actorId: args.actorId, add: true }); },
    'cheat.removePartyMember': function (args) { return cheatPartyMember({ actorId: args.actorId, add: false }); },
    'cheat.godMode': cheatGodMode,
    'cheat.noclip': cheatNoclip,
    'cheat.encounter': cheatEncounter,
    'cheat.alwaysDash': cheatAlwaysDash,
    'cheat.followers': cheatFollowers,
    'cheat.unlockEquip': cheatUnlockEquip,
    'cheat.unlockChoice': cheatUnlockChoice,
    'cheat.speed': cheatSpeed,
    'cheat.moveSpeed': cheatMoveSpeed,
    'cheat.teleport': cheatTeleport,
    'cheat.scene': cheatScene,
    'cheat.scenePop': cheatScenePop,
    'cheat.battle': cheatBattle,
    'cheat.clearPictures': cheatClearPictures,
    'cheat.clearEvent': cheatClearEvent,
    'cheat.clearMoveRoute': cheatClearMoveRoute,
    'cheat.closeAllWindows': cheatCloseAllWindows,
    'cheat.fadeIn': cheatFadeIn,
    'cheat.recover': cheatRecover,
    'cheat.repair': cheatRepair,
    'cheat.fixError': cheatFixError,
    'cheat.devTools': cheatDevTools,
    'cheat.objectPath': cheatObjectPath,
    'cheat.setObjectPath': cheatSetObjectPath,
    'text.scanStart': textScanStart,
    'text.scanCancel': textScanCancel
  };

  function rpcReply(id, ok, data, error) {
    emit('rpcResult', {
      id: id,
      ok: !!ok,
      data: ok ? (data === undefined ? null : data) : null,
      error: ok ? null : (error || { code: 'rpc_error', message: 'unknown' })
    });
  }

  function handleRpc(payload) {
    var id = payload && payload.id;
    var method = payload && payload.method;
    var args = (payload && payload.args) || {};
    if (typeof method !== 'string') {
      rpcReply(id, false, null, { code: 'rpc_bad_request', message: 'method 缺失' });
      return;
    }
    var handler = RPC[method];
    if (typeof handler !== 'function') {
      rpcReply(id, false, null, { code: 'rpc_unknown_method', message: 'unknown method: ' + method });
      return;
    }
    var result;
    try {
      result = handler(args);
    } catch (error) {
      state.errors++;
      rpcReply(id, false, null, {
        code: (error && error.code) ? error.code : 'rpc_error',
        message: String((error && error.message) || error)
      });
      return;
    }
    if (result && typeof result.then === 'function') {
      result.then(function (data) {
        rpcReply(id, true, data, null);
      }, function (error) {
        state.errors++;
        rpcReply(id, false, null, {
          code: (error && error.code) ? error.code : 'rpc_error',
          message: String((error && error.message) || error)
        });
      });
      return;
    }
    rpcReply(id, true, result, null);
  }

  // ------------------------------------------------------------------
  // Hooks
  // ------------------------------------------------------------------

  function belongsToUs(fn) {
    return !!(fn && fn.__mochiboxHooked);
  }

  function hookDrawTextEx() {
    if (typeof global.Window_Base === 'undefined' || !global.Window_Base.prototype) { return false; }
    var proto = global.Window_Base.prototype;
    var base = proto.drawTextEx;
    if (typeof base !== 'function') { return false; }
    if (belongsToUs(base)) { orig.drawTextEx = base.__mochiboxOriginal || orig.drawTextEx; return true; }
    orig.drawTextEx = base;
    var wrapper = function (text, x, y) {
      var args = arguments;
      var restore = null;
      try {
        if (this && this.contents && typeof this.contents.fontSize === 'number' && state.fontScale !== 1) {
          restore = this.contents.fontSize;
          this.contents.fontSize = Math.max(1, Math.round(restore * state.fontScale));
        }
        if (typeof text === 'string') {
          var replaced = processText(text, 'Window_Base.drawTextEx');
          if (replaced !== null) { args[0] = replaced; }
        }
      } catch (e) {
        state.errors++;
        reportHookError(e);
      }
      inDrawDepth++;
      try {
        return base.apply(this, args);
      } catch (e2) {
        state.errors++;
        return undefined;
      } finally {
        inDrawDepth--;
        if (restore !== null) {
          try { this.contents.fontSize = restore; } catch (e3) { /* ignore */ }
        }
      }
    };
    wrapper.__mochiboxHooked = true;
    wrapper.__mochiboxOriginal = base;
    proto.drawTextEx = wrapper;
    return true;
  }

  /// 战斗日志的 `drawTextEx` 可能由插件**在 `Window_BattleLog.prototype` 上自建**
  /// （`NRP_WindowBattleLogLayout` 就是这样）：方法查找先命中它，挂在
  /// `Window_Base.prototype.drawTextEx` 上的包装永远不会被调用，日志文本于是逐字符落到
  /// `Bitmap.drawText`（那条路只采集、不改写）。
  ///
  /// 只在**自有**属性时包装：没有自建时继承的就是 `Window_Base` 的版本，已经被
  /// `hookDrawTextEx` 覆盖，再包一层会让同一行处理两次。
  function hookBattleLogDrawTextEx() {
    if (typeof global.Window_BattleLog === 'undefined' || !global.Window_BattleLog.prototype) { return false; }
    var proto = global.Window_BattleLog.prototype;
    if (!Object.prototype.hasOwnProperty.call(proto, 'drawTextEx')) { return false; }
    var base = proto.drawTextEx;
    if (typeof base !== 'function') { return false; }
    if (belongsToUs(base)) {
      orig.battleLogDrawTextEx = base.__mochiboxOriginal || orig.battleLogDrawTextEx;
      return true;
    }
    orig.battleLogDrawTextEx = base;
    var wrapper = function (text, x, y) {
      var args = arguments;
      var restore = null;
      try {
        if (this && this.contents && typeof this.contents.fontSize === 'number' && state.fontScale !== 1) {
          restore = this.contents.fontSize;
          this.contents.fontSize = Math.max(1, Math.round(restore * state.fontScale));
        }
        if (typeof text === 'string') {
          var replaced = processText(text, 'Window_BattleLog.drawTextEx');
          if (replaced !== null) { args[0] = replaced; }
        }
      } catch (e) {
        state.errors++;
        reportHookError(e);
      }
      inDrawDepth++;
      try {
        return base.apply(this, args);
      } catch (e2) {
        state.errors++;
        return undefined;
      } finally {
        inDrawDepth--;
        if (restore !== null) {
          try { this.contents.fontSize = restore; } catch (e3) { /* ignore */ }
        }
      }
    };
    wrapper.__mochiboxHooked = true;
    wrapper.__mochiboxOriginal = base;
    proto.drawTextEx = wrapper;
    return true;
  }

  /// 插件脚本由 `PluginManager.setup` 异步加载，**可能晚于 Agent 早装**；早装那一刻
  /// 看不到自有 `drawTextEx`，只装一次就会永远漏掉战斗日志。500ms 补装，命中即停，
  /// 60s 后放弃（原版 MV/MZ 本来就走继承路径，不需要这个 hook）。
  function scheduleBattleLogHook() {
    if (battleLogHookTimer !== null) { return; }
    if (typeof global.setInterval !== 'function') { return; }
    var tries = 0;
    battleLogHookTimer = global.setInterval(function () {
      tries++;
      var ok = false;
      try { ok = hookBattleLogDrawTextEx(); } catch (e) { ok = false; }
      if (ok && installedHooks.indexOf('Window_BattleLog.drawTextEx') < 0) {
        installedHooks.push('Window_BattleLog.drawTextEx');
      }
      if (ok || tries > 120) {
        try { global.clearInterval(battleLogHookTimer); } catch (e2) { /* ignore */ }
        battleLogHookTimer = null;
      }
    }, 500);
  }

  function hookDrawText() {
    if (typeof global.Window_Base === 'undefined' || !global.Window_Base.prototype) { return false; }
    var proto = global.Window_Base.prototype;
    var base = proto.drawText;
    if (typeof base !== 'function') { return false; }
    if (belongsToUs(base)) { orig.drawText = base.__mochiboxOriginal || orig.drawText; return true; }
    orig.drawText = base;
    var wrapper = function (text, x, y, maxWidth, align) {
      var args = arguments;
      var restore = null;
      try {
        if (this && this.contents && typeof this.contents.fontSize === 'number' && state.fontScale !== 1) {
          restore = this.contents.fontSize;
          this.contents.fontSize = Math.max(1, Math.round(restore * state.fontScale));
        }
        if (typeof text === 'string') {
          var replaced = processText(text, 'Window_Base.drawText');
          if (replaced !== null) { args[0] = replaced; }
        }
      } catch (e) {
        state.errors++;
        reportHookError(e);
      }
      inDrawDepth++;
      try {
        return base.apply(this, args);
      } catch (e2) {
        state.errors++;
        return undefined;
      } finally {
        inDrawDepth--;
        if (restore !== null) {
          try { this.contents.fontSize = restore; } catch (e3) { /* ignore */ }
        }
      }
    };
    wrapper.__mochiboxHooked = true;
    wrapper.__mochiboxOriginal = base;
    proto.drawText = wrapper;
    return true;
  }

  function hookBitmapDrawText() {
    if (typeof global.Bitmap === 'undefined' || !global.Bitmap.prototype) { return false; }
    var proto = global.Bitmap.prototype;
    var base = proto.drawText;
    if (typeof base !== 'function') { return false; }
    if (belongsToUs(base)) { orig.bitmapDrawText = base.__mochiboxOriginal || orig.bitmapDrawText; return true; }
    orig.bitmapDrawText = base;
    var wrapper = function (text, x, y, maxWidth, lineHeight, align) {
      // 只采集不改写；嵌套在 Window_Base 内时直接跳过，避免同一字符串二次采集。
      try {
        if (inDrawDepth === 0 && typeof text === 'string' && state.enabled) {
          processText(text, 'Bitmap.drawText');
        }
      } catch (e) {
        state.errors++;
      }
      return base.apply(this, arguments);
    };
    wrapper.__mochiboxHooked = true;
    wrapper.__mochiboxOriginal = base;
    proto.drawText = wrapper;
    return true;
  }

  function rememberReplaced(index, raw) {
    if (!Object.prototype.hasOwnProperty.call(replacedTextsByIndex, index)) {
      replacedIndexOrder.push(index);
    }
    replacedTextsByIndex[index] = raw;
    while (replacedIndexOrder.length > REPLACED_TEXTS_LIMIT) {
      var oldest = replacedIndexOrder.shift();
      try { delete replacedTextsByIndex[oldest]; } catch (e) { replacedTextsByIndex[oldest] = undefined; }
    }
  }

  /** 清空"下标 → 原文"映射。映射只描述**当前这条消息**，换消息/关闭翻译都必须先清。 */
  function clearReplacedTexts() {
    replacedTextsByIndex = {};
    replacedIndexOrder = [];
  }

  /** 关闭翻译时把消息窗恢复成原文（只动 $gameMessage._texts）。 */
  function restoreReplacedTexts() {
    var message = global.$gameMessage;
    var texts = message && message._texts;
    if (Object.prototype.toString.call(texts) === '[object Array]') {
      for (var i = 0; i < texts.length; i++) {
        if (!Object.prototype.hasOwnProperty.call(replacedTextsByIndex, i)) { continue; }
        try { texts[i] = replacedTextsByIndex[i]; } catch (e) { /* frozen array */ }
      }
    }
    clearReplacedTexts();
  }

  function hookStartMessage() {
    if (typeof global.Window_Message === 'undefined' || !global.Window_Message.prototype) { return false; }
    var proto = global.Window_Message.prototype;
    var base = proto.startMessage;
    if (typeof base !== 'function') { return false; }
    if (belongsToUs(base)) { orig.startMessage = base.__mochiboxOriginal || orig.startMessage; return true; }
    orig.startMessage = base;
    var wrapper = function () {
      try {
        // 映射只描述**当前这条消息**：先清掉上一条的，再开始处理 texts。
        // 关翻译时、或本条一行都没命中时不会再写映射，若不清就会残留上条的下标，
        // 关闭翻译会把上条的原文写进这条消息窗。
        clearReplacedTexts();
        if (state.enabled) {
          var message = global.$gameMessage;
          var texts = message && message._texts;
          if (Object.prototype.toString.call(texts) === '[object Array]' && texts.length > 0) {
            var prepared = [];
            var anyText = false;
            var hit = 0;
            var miss = 0;
            var missKeys = [];
            for (var i = 0; i < texts.length; i++) {
              var raw = texts[i];
              if (typeof raw !== 'string' || raw === '') {
                prepared.push(raw);
                continue;
              }
              anyText = true;
              var replaced = processText(raw, 'Window_Message.startMessage');
              if (replaced !== null) {
                hit++;
                prepared.push(replaced);
              } else {
                // 纯标点占位（？？？/……）按设计不进翻译表；未收录的行同理。
                // 它们只影响自己这一行，不能把整条消息拖回日文。
                miss++;
                if (missKeys.length < 3) { missKeys.push(mapKeyOf(raw).slice(0, 20)); }
                prepared.push(raw);
              }
            }
            // 逐行降级：某个下标有可用译文就写译文，没有就保留原文。
            // 一条消息里混着"能翻的行"和"翻不了的行"是常态（后者多为纯标点），
            // 旧实现要求每行都命中才整条写回，于是这些消息一行都不翻。
            if (anyText) {
              for (var j = 0; j < texts.length; j++) {
                var original = texts[j];
                if (typeof original === 'string' && original !== '' && prepared[j] !== original) {
                  rememberReplaced(j, original);
                }
                try { texts[j] = prepared[j]; } catch (e2) { /* frozen array */ }
              }
            }
            // 只在真有未命中时留痕：真机日志里能直接看出"这句为什么没翻"。
            // 走既有 error 信封（Host 侧落 warn），不为一条诊断新增协议消息类型。
            if (miss > 0) {
              emit('error', {
                code: 'start_message_miss',
                message: 'startMessage lines=' + texts.length + ' hit=' + hit + ' miss=' + miss
                  + ' [' + missKeys.join(' | ') + ']',
                stack: null
              });
            }
          }
        }
      } catch (e) {
        state.errors++;
        reportHookError(e);
      }
      return base.apply(this, arguments);
    };
    wrapper.__mochiboxHooked = true;
    wrapper.__mochiboxOriginal = base;
    proto.startMessage = wrapper;
    return true;
  }

  // ------------------------------------------------------------------
  // 数据回写：静态数据库里的「运行时拼接」文本
  //
  // 有些文本不是绘制时拼出来的，而是**绘制前**就把 $data* 的片段直接拼进了
  // Game_Actor._name 或窗口字符串里：
  //   · displayCurrentState = subject.name() + $dataStates[id].message3（每帧实时读）
  //   · displayAction       = subject.name() + item.message1.format(item.name)
  //   · Game_Actor.setup    = this._name = $dataActors[id].name
  // 这类串**没有任何一个时刻以完整形式存在**，绘制 hook 只能拿到拼好的日文，查表必然失配。
  // 唯一可行的修法是把**片段本身**换掉：译文本来就是按「接在名字后面」翻的，
  // 片段替换后拼出来天然通顺（缪特 + 正在保护自己。）。
  //
  // 三条回写时机（缺一不可）：
  //   1. DataManager.createGameObjects 之前：Game_Actors 是惰性的（rpg_objects.js:4584），
  //      之后 Game_Actor.setup 里的 _name = actor.name 会直接拿到中文，不需要事后同步；
  //   2. 译文晚到（Host 异步下发）后防抖补写；
  //   3. Game_Actor.setName 拦截剧情改名（code 320 会把日文名写回 _name）。
  //
  // **两遍结构保证的是「批内没有部分写入的中间态」，不保证「跨字段的语言一致」**：
  // 一次 patchDataTables() 先把所有表所有字段的写入计划算完，再统一落盘；计划成型到
  // 落盘之间没有让出点，插件/游戏不可能读到「一半字段已换、另一半还没换」的中间态。
  // 但译文是**按条目**下发的，名字与 messageN 的覆盖率本来就可能不一致：只到了名字的译文
  // 时，照样会拼出「缪特は身を守っている。」。这是覆盖率问题，不是原子性问题 ——
  // 别把这段读成「绝不会出现半日文」。
  // ------------------------------------------------------------------

  /// 参与回写的表。只读递归（walkDataStrings）仍然按原样扫全库，这里是一份**写**白名单。
  var DATA_PATCH_TABLES = ['$dataActors', '$dataClasses', '$dataSkills', '$dataItems',
    '$dataWeapons', '$dataArmors', '$dataEnemies', '$dataStates'];

  /// 允许写的字段。顺序固定（计划也是按这个顺序生成，便于断言）。
  var DATA_PATCH_FIELD_LIST = ['name', 'nickname', 'profile', 'description',
    'message1', 'message2', 'message3', 'message4'];

  /// 显式黑名单：这两个字段**永不**参与回写。
  /// note 被 StateHelp.js:548 解析 <STATE_HELP>、meta 被 HzExState.js:56/111/145 读取
  /// hzExState_*，写坏不是「翻错一句」，是插件直接崩。不要因为「白名单没列」就把这条
  /// 保护交给隐含逻辑：将来有人往白名单加字段时，必须先看到这行判断。
  var DATA_PATCH_BLOCKED = { note: 1, meta: 1 };

  /// 已回写字段的账本（唯一还原依据）+ 去重表（幂等依据）。
  /// 只记**真正写过**的字段：还原时绝不整库盲写（游戏自己改过的 note / 剧情数据不能被碰）。
  var dataPatchApplied = [];
  var dataPatchByKey = {};
  var dataPatchBatches = 0;
  var dataPatchRestoredCount = 0;
  var dataPatchTimer = null;
  var dataPatchFirstAt = 0;
  var dataPatchHookTimer = null;
  /// 译文晚到时的防抖窗口：一次全文下发有几十个分片（每片 200 条），逐片回写等于把整个库
  /// 扫几十遍。**每来一片就顺延**（真防抖）—— 这样一整套语料落成**一批**，名字与 message
  /// 不会因为分片边界被拆到两批（拆开就是「缪特は身を守っている。」这种半日文）。
  var DATA_PATCH_DELAY_MS = 300;
  /// 但连续流式下发不能把回写饿死：从第一次排期起最多等这么久，先落一批再说。
  /// 给到 10s 而不是几百毫秒：全文语料有几万条、几十个分片，整套推完才落盘才能保证
  /// 名字与 messageN 不被片边界拆开；它只是「永远等不到静默」时的兜底。
  var DATA_PATCH_MAX_WAIT_MS = 10000;
  /// DataManager / Game_Actor 可能晚于 Agent 早装才定义（rpg_managers.js / rpg_objects.js）。
  var DATA_PATCH_HOOK_MS = 200;
  var DATA_PATCH_HOOK_TRIES = 600;
  /// 被我们改过 _name 的 Game_Actor（剧情改名要能还原），按对象身份记账。
  var actorNameOriginals = [];
  var ACTOR_NAME_ORIGINALS_LIMIT = 500;

  function dataPatchKey(table, index, field) {
    return table + '|' + index + '|' + field;
  }

  function isPatchableField(field) {
    if (typeof field !== 'string' || field === '') { return false; }
    if (DATA_PATCH_BLOCKED[field] === 1) { return false; }
    for (var i = 0; i < DATA_PATCH_FIELD_LIST.length; i++) {
      if (DATA_PATCH_FIELD_LIST[i] === field) { return true; }
    }
    return false;
  }

  /// 名字类字段：只有这两个受 `dataPatchNames` 管辖（profile / messageN 不受影响）。
  function isNameField(field) {
    return field === 'name' || field === 'nickname';
  }

  /// 白名单 + 当前开关共同决定的「这一轮能不能写这个字段」。
  /// 还原路径**不**走这个判据：已经写进去的中文必须能按账本撤回来，哪怕开关已经关了。
  function isFieldWritableNow(field) {
    if (!isPatchableField(field)) { return false; }
    if (state.dataPatchNames === false && isNameField(field)) { return false; }
    return true;
  }

  function isDataArray(value) {
    return Object.prototype.toString.call(value) === '[object Array]';
  }

  /// 静默查表：**不发 text 事件、不写 text 流、不动 state.replaced**。
  /// 与 processText 的唯一区别就在这里 —— 几千条 $data* 字段若走 processText，会把文本流
  /// 灌满，还会被 rememberRuntime 当成「运行期见过的原文」污染全文扫描。
  /// 纯文本串天然满足 mapKey === 原串；带转义码的字段（少数 message1）仍走同一套切段。
  // 控制码形态：反斜杠 + 字母 + 方括号（\c[27] / \N[1] / \i[4]）。
  // 只给 silentLookup 的防御出口用：原文没有码、译文却带码，写进 $data* 之后
  // drawText 会把码当字面量画出来（\c[27]无法逃走）。
  var CONTROL_CODE_FORM = /\\[A-Za-z]+\[/;

  /// 占位符 `%1..%9` 的**多重集**签名：顺序无关、计数有关。
  /// 回写只要求"不增不减"——`%1`/`%2` 换个顺序在 `format()` 里仍然正确；
  /// 少了占位符，游戏传进来的实参根本没地方填；多了则填进一个不存在的参数槽。
  function placeholderSignature(text) {
    var counts = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    for (var i = 0; i + 1 < text.length; i++) {
      if (text.charCodeAt(i) !== 37) { continue; }        // '%'
      var digit = text.charCodeAt(i + 1) - 48;            // '1'..'9'
      if (digit >= 1 && digit <= 9) { counts[digit - 1]++; i++; }
    }
    return counts.join(',');
  }

  function silentLookup(raw) {
    if (typeof raw !== 'string' || raw === '') { return null; }
    try {
      var segments = splitSegments(raw);
      var key = mapKeyOfSegments(segments, raw);
      // mergeFallback 是**绘制路径**的降级指标（probe().mergeFallback）。回写查表不是页面行，
      // 这里前后保存/恢复，别让几千条 $data* 字段把"页面行降级率"统计歪掉。
      var savedFallback = state.mergeFallback;
      var hit;
      try {
        hit = lookup(raw, key, segments);
      } finally {
        state.mergeFallback = savedFallback;
      }
      if (hit === null || hit === raw) { return null; }
      // 无段证据出口（lookup 出口 2）直接给 translatedRaw，不做码值检查：那串是"别的行"的
      // 控制码。原文没有码 → 译文多出来的码会被当字面量画进数据表；宁可不回写，保持日文。
      if (raw.indexOf('\\') < 0 && CONTROL_CODE_FORM.test(hit)) { return null; }
      // 占位符守卫：`%1..%9` 的多重集必须与原文完全一致，否则放弃回写（保持日文）。
      // 写进 `$data*` 的串会被 `format()` 消费：数量对不上就不是"翻得怪"，而是把游戏
      // 传入的实参丢掉/错位（`は%1に...` → `对%1造成...` 少一个槽，玩家看到的就是空）。
      // **只在这个静默出口检查**：正常绘制路径允许译文调整占位符顺序，只是不能增减。
      if (placeholderSignature(raw) !== placeholderSignature(hit)) { return null; }
      return hit;
    } catch (e) {
      state.errors++;
      return null;
    }
  }

  /// 第一遍：只算不写。名字与 messageN 的写入计划必须在同一遍里成型，
  /// 这样落盘时它们要么一起可见、要么都还没动（见本节开头：批内无中间态）。
  function planDataPatch() {
    var plan = [];
    for (var t = 0; t < DATA_PATCH_TABLES.length; t++) {
      var tableName = DATA_PATCH_TABLES[t];
      var table = global[tableName];
      if (!isDataArray(table)) { continue; }
      for (var i = 1; i < table.length; i++) {   // 0 号是 MV/MZ 的 null 占位
        var record = table[i];
        if (!record || typeof record !== 'object' || isDataArray(record)) { continue; }
        for (var f = 0; f < DATA_PATCH_FIELD_LIST.length; f++) {
          var field = DATA_PATCH_FIELD_LIST[f];
          if (!isFieldWritableNow(field)) { continue; }   // 白名单 + dataPatchNames
          if (!Object.prototype.hasOwnProperty.call(record, field)) { continue; }
          var raw = record[field];
          if (typeof raw !== 'string' || raw === '') { continue; }
          var key = dataPatchKey(tableName, i, field);
          if (dataPatchByKey[key]) { continue; }  // 本会话已写过（幂等，不二次翻译中文）
          var translated = silentLookup(raw);
          if (translated === null) { continue; }
          plan.push({
            table: tableName, index: i, field: field,
            original: raw, applied: translated, key: key
          });
        }
      }
    }
    return plan;
  }

  /// 第二遍：统一落盘。计划成型到落盘之间没有让出点，也不会再调用任何外部代码；
  /// 因此**本批计划内**的字段对外同时可见（JS 单线程 + 两遍结构 = 批内原子）。
  /// 没进计划的字段（译文还没到）不在这个保证里 —— 那属于覆盖率，不是原子性。
  function commitDataPatch(plan) {
    if (plan.length === 0) { return 0; }
    var batch = ++dataPatchBatches;
    var count = 0;
    for (var i = 0; i < plan.length; i++) {
      var item = plan[i];
      var table = global[item.table];
      var record = table && table[item.index];
      if (!record || record[item.field] !== item.original) { continue; }
      try {
        record[item.field] = item.applied;
      } catch (e) {
        continue;                              // 冻结对象：这一条放弃，不记台账
      }
      item.batch = batch;
      dataPatchByKey[item.key] = item;
      dataPatchApplied.push(item);
      count++;
    }
    return count;
  }

  /// 对全部白名单表做一次回写。返回本批真正写入的字段数。
  function patchDataTables() {
    if (!state.enabled || !installed) { return 0; }
    // 总开关关掉时一个字段都不写：装了 Live2DInterfaceMZ 一类插件的游戏靠它整块退场。
    if (state.dataPatchEnabled === false) { return 0; }
    var count = 0;
    try {
      count = commitDataPatch(planDataPatch());
      // 数据字段与本函数在同一同步块里完成；这里只补 _name（译文晚到、角色已创建的场景）。
      syncPatchedActorNames();
      // disable 期间保留的剧情改名账：re-enable 后按原文明文重查（见函数注释）。
      resyncPlotActorNames();
    } catch (e) {
      state.errors++;
      reportHookError(e);
    }
    return count;
  }

  // ------------------------------------------------------------------
  // Game_Actor._name：HUD 走裸 Bitmap，读的就是这个字段
  // ------------------------------------------------------------------

  function actorNameEntry(actor) {
    for (var i = 0; i < actorNameOriginals.length; i++) {
      if (actorNameOriginals[i].actor === actor) { return actorNameOriginals[i]; }
    }
    return null;
  }

  /// 记账必须在写之前：_name 一旦被改掉，原文就没了。
  ///
  /// 当前名字本身可能就是数据回写的产物（译文先到、角色后建，或 sync 补写过）。
  /// 那种情况下真正的原文在 name 记录的 original 里 —— 把中文当原文记下来，
  /// disable 后就还回中文，等于没还原。
  ///
  /// @param {boolean} plot   剧情改名登记的账：clear（抹掉页面译文后重发）时**保留**，
  ///                         因为游戏不会重放 code 320，还原了就再也回不来。
  /// @param {string}  fallback 剧情改名的**原始入参**（日文）：比当前 _name 更可信，
  ///                         disable 后应当看到的是日文剧情名而不是数据名。
  /// @param {string}  applied  我们**写进** _name 的那个值。还原时只有
  ///                         `_name === applied` 才写回：游戏后来自己改过名的，
  ///                         游戏的值比账本新，覆盖它等于让玩家看到更早的名字。
  function rememberActorNameOriginal(actor, plot, fallback, applied) {
    if (!actor || typeof actor !== 'object') { return; }
    if (typeof actor._name !== 'string') { return; }
    var written = (typeof applied === 'string' && applied !== '') ? applied : undefined;
    var existing = actorNameEntry(actor);
    if (existing) {
      // 先进来的是 sync（记为数据原文、plot=false），后面 setName 才是剧情改名：
      // 以剧情入参为准，否则 disable 会把剧情名还原成数据名。
      // 连续两次剧情改名同理：账本跟的是**最后一次**写进去的值。
      if (plot === true) {
        existing.plot = true;
        if (typeof fallback === 'string' && fallback !== '') { existing.original = fallback; }
        if (written !== undefined) { existing.applied = written; }
      }
      return;
    }
    var original = actor._name;
    if (typeof fallback === 'string' && fallback !== '') {
      original = fallback;
    } else {
      var id = actorIdOf(actor);
      if (id > 0) {
        var rec = dataPatchByKey[dataPatchKey('$dataActors', id, 'name')];
        if (rec && original === rec.applied) { original = rec.original; }
      }
    }
    actorNameOriginals.push({ actor: actor, original: original, plot: plot === true, applied: written });
    if (actorNameOriginals.length > ACTOR_NAME_ORIGINALS_LIMIT) { actorNameOriginals.shift(); }
  }

  function gameActorList() {
    var out = [];
    var table = global.$gameActors && global.$gameActors._data;
    if (!isDataArray(table) && !(table && typeof table.length === 'number')) { return out; }
    for (var i = 1; i < table.length; i++) {
      if (table[i] && typeof table[i] === 'object') { out.push(table[i]); }
    }
    return out;
  }

  function actorIdOf(actor) {
    if (!actor) { return 0; }
    var id = actor._actorId;
    if (typeof id !== 'number') {
      try { id = (typeof actor.actorId === 'function') ? actor.actorId() : 0; } catch (e) { id = 0; }
    }
    return (typeof id === 'number' && id > 0) ? id : 0;
  }

  /// 把已经建成、仍是日文原文的 Game_Actor._name 换成译文。
  /// 只动 _name === 数据原文的角色：剧情改名过的名字（与原文不同）不许覆盖。
  ///
  /// 两条前置不变量（以前靠"disable 时账本已清空"隐式成立，现在被显式写出来）：
  ///   · `state.enabled` —— 翻译关掉时账本可能还留着剧情改名的账（keep-ledger），
  ///     这个函数会被 createGameObjects / extractSaveContents 的 hook 直接调到，必须自己挡；
  ///   · `dataPatchNames` —— 名字类回写被关掉时，_name 一个都不许再翻。
  function syncPatchedActorNames() {
    if (!state.enabled) { return 0; }
    if (state.dataPatchEnabled === false || state.dataPatchNames === false) { return 0; }
    var table = global.$gameActors && global.$gameActors._data;
    if (!table) { return 0; }
    var count = 0;
    for (var i = 1; i < table.length; i++) {
      var actor = table[i];
      if (!actor || typeof actor._name !== 'string') { continue; }
      var rec = dataPatchByKey[dataPatchKey('$dataActors', i, 'name')];
      if (!rec || actor._name !== rec.original) { continue; }
      rememberActorNameOriginal(actor, false, null, rec.applied);
      try {
        actor._name = rec.applied;
        count++;
      } catch (e) { /* ignore */ }
    }
    return count;
  }

  /// disable 时剧情改名的账被保留（名字已还原成日文，见 restorePatchedActorNames 的
  /// 'keep-ledger'），re-enable 必须把那些名字重新译回中文：剧情名不在 $dataActors 里，
  /// syncPatchedActorNames 的「_name === 数据原文」判据对它永远不成立。
  function resyncPlotActorNames() {
    if (!state.enabled) { return 0; }
    // 名字类回写关掉时剧情名也不许翻：账留着，等开关打开再按原文重查。
    if (state.dataPatchEnabled === false || state.dataPatchNames === false) { return 0; }
    var count = 0;
    for (var i = 0; i < actorNameOriginals.length; i++) {
      var entry = actorNameOriginals[i];
      if (!entry.plot) { continue; }
      var actor = entry.actor;
      // 只认"名字还停在剧情原名"的角色：游戏在关闭期间又改过名的，不覆盖。
      if (!actor || typeof actor._name !== 'string' || actor._name !== entry.original) { continue; }
      var translated = silentLookup(entry.original);
      if (translated === null) { continue; }
      try {
        actor._name = translated;
        entry.applied = translated;
        count++;
      } catch (e) { /* ignore */ }
    }
    return count;
  }

  /// 还原 _name。两来源：
  ///   1. 账本里有这个对象的原文（setName 或 sync 写过它）→ 写回原文；
  ///   2. 数据回写之后才 setup 的角色（setup 直接赋字段，没人「写过」它）→
  ///      只当 _name 仍等于我们写进 $dataActors[].name 的译文时才还原。
  ///
  /// **两个判据都要 `_name === applied`**（账本里我们写进去的值）：游戏后来执行
  /// `setName('勇者アレン')` 时，账本里的原文比游戏当前值旧，覆盖它就是把玩家的名字改回更早的。
  /// 没有 applied 的老条目按原行为无条件写回（兼容）。
  ///
  /// plotMode 三种：
  ///   'restore'（默认）—— 全部还原，账清空（disable / uninstall）；
  ///   'keep'          —— clear：剧情改名的账与场上名字都保留（游戏不会重放 code 320）；
  ///   'keep-ledger'   —— disable：名字还原成日文剧情名，**账留着**给 re-enable 重查
  ///                      （剧情名不在 $dataActors 里，sync 的判据永远不成立）。
  function restorePatchedActorNames(plotMode) {
    var mode = (plotMode === 'keep' || plotMode === 'keep-ledger') ? plotMode : 'restore';
    var actors = gameActorList();
    var kept = [];
    for (var i = 0; i < actors.length; i++) {
      var actor = actors[i];
      var entry = actorNameEntry(actor);
      if (entry) {
        if (entry.plot && mode !== 'restore') {
          kept.push(entry);
          if (mode === 'keep') { continue; }
        }
        if (entry.applied !== undefined && actor._name !== entry.applied) { continue; }
        if (actor._name !== entry.original) {
          try { actor._name = entry.original; } catch (e) { /* ignore */ }
        }
        continue;
      }
      var id = actorIdOf(actor);
      if (id <= 0) { continue; }
      var rec = dataPatchByKey[dataPatchKey('$dataActors', id, 'name')];
      if (rec && actor._name === rec.applied) {
        try { actor._name = rec.original; } catch (e2) { /* ignore */ }
      }
    }
    actorNameOriginals = (mode === 'restore') ? [] : kept;
  }

  // ------------------------------------------------------------------
  // 还原
  // ------------------------------------------------------------------

  function cancelDataPatchTimer() {
    if (dataPatchTimer !== null) {
      try { global.clearTimeout(dataPatchTimer); } catch (e) { /* ignore */ }
      dataPatchTimer = null;
    }
  }

  /// 关闭翻译 / uninstall：只把账本里**确实改过**的字段写回原文。
  /// 还原顺序不能反：_name 的还原要读 name 记录的 applied 值，先还原数据表会把账本
  /// 与数据原文对齐关系打乱（也会让自然创建的角色无法判断是否该还原）。
  function restoreDataPatch(options) {
    cancelDataPatchTimer();
    // plotNames：默认全部还原；'keep'（clear）/ 'keep-ledger'（disable）见 restorePatchedActorNames。
    restorePatchedActorNames(options && options.plotNames);
    var restored = 0;
    for (var i = dataPatchApplied.length - 1; i >= 0; i--) {
      var item = dataPatchApplied[i];
      var table = global[item.table];
      var record = table && table[item.index];
      if (!record) { continue; }
      // 之后被游戏/别的补丁改过：不覆盖别人的写入，也不再记这条账。
      if (record[item.field] !== item.applied) { continue; }
      try {
        record[item.field] = item.original;
        restored++;
      } catch (e) { /* frozen */ }
    }
    dataPatchRestoredCount += restored;
    dataPatchApplied = [];
    dataPatchByKey = {};
    return restored;
  }

  /// 只还原**名字类**字段（`dataPatchNames` 从 true 切 false 时用）：
  /// `name` / `nickname` + `Game_Actor._name` 回原文，message / description / profile
  /// 保持中文 —— 那是这个开关的语义：名字被插件当表 key / 换装联动用，播报文本不参与。
  ///
  /// 账本要**分账**，不能整块清：留下的条目仍是「我们写进去的中文」，下一次整块还原
  /// 还得靠它们找到原文。顺序也不能反：_name 的还原要读 name 记录的 applied 值，
  /// 先删账会让自然创建的角色失去「这条中文是不是我们写的」的判断依据（见
  /// restorePatchedActorNames 的判据 2）。
  function restoreDataPatchNames(options) {
    cancelDataPatchTimer();
    restorePatchedActorNames(options && options.plotNames);
    var restored = 0;
    var kept = [];
    for (var i = 0; i < dataPatchApplied.length; i++) {
      var item = dataPatchApplied[i];
      if (!isNameField(item.field)) { kept.push(item); continue; }
      var table = global[item.table];
      var record = table && table[item.index];
      // 被游戏/别的补丁改过的不覆盖，但账照样撤：那已经不是我们的写入了。
      if (record && record[item.field] === item.applied) {
        try {
          record[item.field] = item.original;
          restored++;
        } catch (e) { /* frozen */ }
      }
      delete dataPatchByKey[item.key];
    }
    dataPatchApplied = kept;
    dataPatchRestoredCount += restored;
    return restored;
  }

  // ------------------------------------------------------------------
  // 时机
  // ------------------------------------------------------------------

  /// 译文晚到：防抖一次回写。已写过的字段在 dataPatchByKey 里，重复触发是空转。
  ///
  /// 定时器**每片都顺延**（真防抖），并用 DATA_PATCH_MAX_WAIT_MS 兜底：全文下发是几十个
  /// 分片，顺延到最后一篇落定才回写，名字与 messageN 就不会被分片边界拆进两批；流式翻译
  /// 持续不断时上限一到就先落一批，不会永远等下去。
  function scheduleDataPatch() {
    if (!state.enabled || !installed) { return; }
    // 总开关关掉时连排期都不要：排了也是 patchDataTables 里空转，白烧一个定时器。
    if (state.dataPatchEnabled === false) { return; }
    if (typeof global.setTimeout !== 'function') { patchDataTables(); return; }
    var now = nowMs();
    if (dataPatchTimer === null) {
      dataPatchFirstAt = now;
    } else {
      if (now - dataPatchFirstAt >= DATA_PATCH_MAX_WAIT_MS) { return; }  // 已排期的会按时落地
      try { global.clearTimeout(dataPatchTimer); } catch (e) { /* ignore */ }
      dataPatchTimer = null;
    }
    dataPatchTimer = global.setTimeout(function () {
      dataPatchTimer = null;
      patchDataTables();
    }, DATA_PATCH_DELAY_MS);
  }

  function markHook(name) {
    if (installedHooks.indexOf(name) < 0) { installedHooks.push(name); }
  }

  /// 必须在原函数**之前**回写：createGameObjects 之后各角色才 setup 并读 $dataActors[].name。
  function hookCreateGameObjects() {
    var manager = global.DataManager;
    if (!manager || typeof manager.createGameObjects !== 'function') { return false; }
    var base = manager.createGameObjects;
    if (belongsToUs(base)) {
      orig.createGameObjects = base.__mochiboxOriginal || orig.createGameObjects;
      return true;
    }
    orig.createGameObjects = base;
    var wrapper = function () {
      try { patchDataTables(); } catch (e) { state.errors++; reportHookError(e); }
      var result = base.apply(this, arguments);
      // Game_Actors 是惰性的，这里通常是空跑；但若上一局已建过角色（读档/重开），
      // 补一次 _name 同步，避免 HUD 还显示日文。
      try { syncPatchedActorNames(); } catch (e2) { state.errors++; }
      return result;
    };
    wrapper.__mochiboxHooked = true;
    wrapper.__mochiboxOriginal = base;
    manager.createGameObjects = wrapper;
    return true;
  }

  /// 读档：extractSaveContents 在 createGameObjects **之后**才把存档里的 Game_Actor 灌进
  /// $gameActors._data（rpg_managers.js），那些 _name 是存档里的日文拷贝，不会经过 setup。
  /// 不补这一下，读档后 HUD 名字与 displayCurrentState 的拼接又会回到半日文。
  function hookExtractSaveContents() {
    var manager = global.DataManager;
    if (!manager || typeof manager.extractSaveContents !== 'function') { return false; }
    var base = manager.extractSaveContents;
    if (belongsToUs(base)) {
      orig.extractSaveContents = base.__mochiboxOriginal || orig.extractSaveContents;
      return true;
    }
    orig.extractSaveContents = base;
    var wrapper = function () {
      var result = base.apply(this, arguments);
      try { syncPatchedActorNames(); } catch (e) { state.errors++; }
      return result;
    };
    wrapper.__mochiboxHooked = true;
    wrapper.__mochiboxOriginal = base;
    manager.extractSaveContents = wrapper;
    return true;
  }

  /// 剧情改名（事件指令 code 320）会把日文名写回 _name，必须在这里拦。
  /// 覆写 Game_Actor.prototype.name 没用：MOG_BattleHud 直读 _battler._name。
  function hookActorSetName() {
    if (typeof global.Game_Actor === 'undefined' || !global.Game_Actor.prototype) { return false; }
    var proto = global.Game_Actor.prototype;
    if (typeof proto.setName !== 'function') { return false; }
    var base = proto.setName;
    if (belongsToUs(base)) {
      orig.setName = base.__mochiboxOriginal || orig.setName;
      return true;
    }
    orig.setName = base;
    var wrapper = function (name) {
      var args = arguments;
      try {
        // 名字类回写关掉时**直接透传**：不查表、不记账（记了就会在还原时把剧情名写回日文，
        // 而玩家这次本来就要求名字保持原文）。
        if (state.enabled && state.dataPatchEnabled !== false && state.dataPatchNames !== false &&
            typeof name === 'string' && name !== '') {
          var translated = silentLookup(name);
          if (translated !== null) {
            // 已经是译文时不再记账（否则会把中文当成原文记下来，disable 后还不回去）。
            // fallback 传**入参原文**：它才是剧情想写的名字（disable 后要看到日文剧情名）；
            // applied 传**即将写进去的译文**：游戏之后再改名就不许被这条账覆盖。
            if (this && this._name !== translated) { rememberActorNameOriginal(this, true, name, translated); }
            args[0] = translated;
          }
        }
      } catch (e) {
        state.errors++;
        reportHookError(e);
      }
      return base.apply(this, args);
    };
    wrapper.__mochiboxHooked = true;
    wrapper.__mochiboxOriginal = base;
    proto.setName = wrapper;
    return true;
  }

  /// DataManager / Game_Actor 由 rpg_managers.js / rpg_objects.js 定义，可能晚于 Agent 早装。
  /// 200ms 补装，命中即停，120s 后放弃（此时大概率已经 attach 到运行中的页面）。
  function scheduleDataPatchHook() {
    if (dataPatchHookTimer !== null) { return; }
    if (typeof global.setInterval !== 'function') { return; }
    var tries = 0;
    dataPatchHookTimer = global.setInterval(function () {
      tries++;
      var managerOk = false;
      var loadOk = false;
      var actorOk = false;
      try { managerOk = hookCreateGameObjects(); } catch (e) { managerOk = false; }
      try { loadOk = hookExtractSaveContents(); } catch (e2) { loadOk = false; }
      try { actorOk = hookActorSetName(); } catch (e3) { actorOk = false; }
      if (managerOk) { markHook('DataManager.createGameObjects'); }
      if (loadOk) { markHook('DataManager.extractSaveContents'); }
      if (actorOk) { markHook('Game_Actor.setName'); }
      if ((managerOk && loadOk && actorOk) || tries > DATA_PATCH_HOOK_TRIES) {
        try { global.clearInterval(dataPatchHookTimer); } catch (e4) { /* ignore */ }
        dataPatchHookTimer = null;
      }
    }, DATA_PATCH_HOOK_MS);
  }

  /// install 时调一次；三个目标都装上了才算齐活，否则交给补装定时器。
  function hookDataPatch() {
    var managerOk = false;
    var loadOk = false;
    var actorOk = false;
    try { managerOk = hookCreateGameObjects(); } catch (e) { managerOk = false; }
    try { loadOk = hookExtractSaveContents(); } catch (e2) { loadOk = false; }
    try { actorOk = hookActorSetName(); } catch (e3) { actorOk = false; }
    if (managerOk) { markHook('DataManager.createGameObjects'); }
    if (loadOk) { markHook('DataManager.extractSaveContents'); }
    if (actorOk) { markHook('Game_Actor.setName'); }
    return managerOk && loadOk && actorOk;
  }

  /// 诊断面（probe / 单测用）。故意不对外暴露写入口：回写时机只有本模块的三条。
  function dataPatchStats() {
    return {
      applied: dataPatchApplied.length,
      batches: dataPatchBatches,
      restored: dataPatchRestoredCount,
      actorNames: actorNameOriginals.length
    };
  }

  function dataPatchRecords() {
    var out = [];
    for (var i = 0; i < dataPatchApplied.length; i++) {
      var item = dataPatchApplied[i];
      out.push({
        table: item.table, index: item.index, field: item.field,
        original: item.original, applied: item.applied, batch: item.batch
      });
    }
    return out;
  }


  // ------------------------------------------------------------------
  // 字体：MV/MZ 用 canvas 画字，fontFace 是游戏的日文字体；macOS 缺字会
  // 回退到日文字形，中文译文于是出现怪字形（原版 MTool 装 Unifont Smooth
  // 就是为了这个）。这里只改绘制用的字体链，不动字号/颜色/其它绘制参数。
  // ------------------------------------------------------------------

  // 中文字体（含符号覆盖面）。**它们永远排在游戏自己的日文字体前面**：日文字体
  // 里带汉字字形，浏览器按声明顺序取字，它一旦靠前，简体中文就还是被画成日文字形。
  // 游戏字体只在下面这些全缺字时才轮到（符号兜底）。
  var CN_FONT_FAMILIES = ['"PingFang SC"', '"Hiragino Sans GB"', '"Heiti SC"', '"Unifont Smooth"', '"Arial Unicode MS"', '"Sun-ExtA"'];
  var DEFAULT_FONT_CHAIN = CN_FONT_FAMILIES.join(',') + ',sans-serif';

  /** 族名去引号后重新加双引号：设置页传来的是裸族名，带空格的族名在 CSS 里必须加引号。 */
  function quotedFamily(name) {
    if (typeof name !== 'string') { return ''; }
    var trimmed = name.replace(/^["']+|["']+$/g, '').trim();
    if (!trimmed) { return ''; }
    return '"' + trimmed.replace(/"/g, '') + '"';
  }

  /**
   * 剥掉 gameFace 里被 standardFontFace 回填的默认链，只留游戏自己的族名。
   *
   * 回填后 fontFace 形如 `GameFont,"PingFang SC",...`；整串塞进新链会把游戏字体
   * 又顶到中文字体前面，于是截到 PingFang SC 之前。
   */
  function gameFamilies(gameFace) {
    var chain = (typeof gameFace === 'string') ? gameFace : '';
    var idx = chain.indexOf('PingFang SC');
    if (idx >= 0) { chain = chain.slice(0, idx); }
    // 截断处常留下 `GameFont,"` 这样的半截引号，一起清掉。
    return chain.replace(/[\s,"']+$/, '').replace(/^[\s,"']+/, '');
  }

  /**
   * 有效链 = 用户族名（若选）+ 中文字体链 + 游戏自己的 fontFace（若存在）+ sans-serif。
   *
   * 用户选了族名就排最前，否则苹方打头；游戏日文字体永远在中文字体之后兜符号。
   * 链是**每次绘制现算**的，改设置后立即换字体；fontFace 为空时不产生空项。
   */
  function fontChainFor(gameFace) {
    var game = gameFamilies(gameFace);
    var chosen = quotedFamily(state.fontFamily);
    var parts = [];
    if (chosen) { parts.push(chosen); }
    for (var i = 0; i < CN_FONT_FAMILIES.length; i++) {
      if (CN_FONT_FAMILIES[i] !== chosen) { parts.push(CN_FONT_FAMILIES[i]); }
    }
    if (game) { parts.push(game); }
    parts.push('sans-serif');
    return parts.join(',');
  }

  /**
   * 重写 Bitmap.prototype._makeFontNameText。
   *
   * **自己拼**，不委托原实现：MV 真源（rpg_core.js:1521）就是
   * (italic ? 'italic ' : '') + fontSize + 'px ' + fontFace；委托 base 在只有
   * 几行桩的引擎里会直接炸。原方法不存在时直接定义（MZ 真源里没有它）。
   */
  function applyGameFont() {
    try {
      if (typeof global.Bitmap === 'undefined' || !global.Bitmap.prototype) { return false; }
      var proto = global.Bitmap.prototype;
      var current = proto._makeFontNameText;
      if (!(typeof current === 'function' && current.__mochiboxFont)) {
        if (typeof current === 'function' && !orig.makeFontNameText) { orig.makeFontNameText = current; }
        var makeFontNameText = function () {
          return (this.fontItalic ? 'italic ' : '') + this.fontSize + 'px ' + fontChainFor(this.fontFace);
        };
        makeFontNameText.__mochiboxFont = true;
        makeFontNameText.__mochiboxOriginal = orig.makeFontNameText;
        proto._makeFontNameText = makeFontNameText;
      }
      if (typeof global.Window_Base !== 'undefined' && global.Window_Base.prototype) {
        var baseProto = global.Window_Base.prototype;
        var standard = baseProto.standardFontFace;
        if (typeof standard === 'function' && !standard.__mochiboxFont) {
          if (!orig.standardFontFace) { orig.standardFontFace = standard; }
          var standardFontFace = function () {
            var face = '';
            try { face = standard.call(this); } catch (err) { face = ''; }
            // 用户族名由 _makeFontNameText 每次绘制动态前置：这里只补默认链，
            // 免得换字体后旧族名还焊在 contents.fontFace 上。
            return (typeof face === 'string' && face.length > 0) ? (face + ',' + DEFAULT_FONT_CHAIN) : DEFAULT_FONT_CHAIN;
          };
          standardFontFace.__mochiboxFont = true;
          standardFontFace.__mochiboxOriginal = standard;
          baseProto.standardFontFace = standardFontFace;
        }
      }
      return true;
    } catch (e) {
      state.errors++;
      return false;
    }
  }

  // ------------------------------------------------------------------
  // 循环视频兜底（WKWebView 第二次 EOS 后永久停帧）
  //
  // **不要动原生 loop**。插件（某影片插件）用 el.loop 判断"是否在等待首圈"，
  // 且在 autoEraseOnEnd=true 时一旦收到 ended 就 eraseVideo() 把整个立绘擦掉。
  // 上一版把原生 loop 恒写 false 换取 ended，等于把"播完擦除"的开关按了每一圈，
  // 实测 3s 待机动画每圈都消失。所以这里改成：原生 loop 保持 true（允许内核自己回绕），
  // 我们在 currentTime 到达 EOS 之前主动把 currentTime 写回 0，元素永远不会进入
  // ended 状态，插件也就不会擦除。
  //
  // 主路径是 requestVideoFrameCallback 的逐帧检查（精度 ±1 帧）；500ms 扫描只在
  // "真的卡在 EOS 附近且 currentTime 不再增长"时兜底（rVFC 被内核停掉、元素换源等）。
  // ------------------------------------------------------------------

  /**
   * 登记过的视频元素。
   *
   * 字段：el 元素本体；lastTime 上一轮扫描看到的 currentTime（停滞判定）；
   * rvfcId 在途的 requestVideoFrameCallback id；wrapAt 上一次主动回绕的时刻
   * （同一元素 60ms 内不重复 seek）；dead uninstall 后置真（在途回调不再调度）。
   *
   * 用**强引用数组**而不是 WeakMap/WeakSet：定时扫描必须能遍历，WeakMap 做不到。
   * 取舍：元素被游戏丢弃后仍留在表里，上限是"一局里创建过的媒体元素个数"（正常是
   * 个位数到几十），远小于每次扫描的收益成本；因此不做元素移除的监听与回收。
   */
  var mediaItems = [];
  var mediaTimer = null;
  /// 主动回绕次数（probe().mediaRestarts），只增不清，用来探测补丁是否真的在工作。
  var mediaRestarts = 0;
  /// 升级到 el.load() 的次数（probe().mediaLoopFails）。现行实现不再走 load()：
  /// 字段保留、语义不变，恒为 0；一旦非 0 说明有人又引入了元素重置。
  var mediaLoopFails = 0;
  /// 累计观测到的 ended 次数（probe().mediaEndedSeen）。**只观测不复位**：
  /// 期望循环的元素必须全程为 0，这是"不触发插件 autoEraseOnEnd"的不变量证据。
  var mediaEndedSeen = 0;
  /// 'off' | 'attached' | 'unsupported'（无 HTMLMediaElement：沙箱/自测 stub 静默降级）。
  var mediaPatchState = 'off';
  var MEDIA_SCAN_MS = 500;
  /// 回绕提前量（秒）：0.06–0.10 约等于 30fps 下的 2–3 帧。绝不能等到 currentTime
  /// 到达 duration —— 那一刻就是 ended 的触发点。
  var MEDIA_WRAP_LEAD = 0.08;
  /// 扫描判"停在 EOS 附近"的容差；与回绕提前量分开：兜底只救真正卡住的元素。
  var MEDIA_EOS_SLACK = 0.1;
  /// 同一元素两次回绕的最小间隔：seek 写入是异步的，防止同一批帧重复 seek 把计数刷爆。
  /// 取 60ms（约 2 帧）而不是更长：万一某次 seek 没写进去，下一帧还能在 EOS 之前补一次；
  /// 300ms 那种量级的保护会把重试推到 EOS 之后，反而把 ended 放出来。
  var MEDIA_WRAP_GUARD_MS = 60;

  function isVideoElement(el) {
    return (typeof global.HTMLVideoElement !== 'undefined') && (el instanceof global.HTMLVideoElement);
  }

  /** play() 在暂停/无源时返回 rejected Promise；不吞掉会变成未捕获异常（控制台红字 + 崩溃日志噪音）。 */
  function safePlay(el) {
    try {
      var p = el.play();
      if (p && typeof p.catch === 'function') { p.catch(function () { /* ignored */ }); }
    } catch (e) { /* ignore */ }
  }

  function mediaFind(el) {
    for (var i = 0; i < mediaItems.length; i++) {
      if (mediaItems[i].el === el) { return mediaItems[i]; }
    }
    return null;
  }

  /**
   * 元素还能不能继续被我们调度：仍在表里、原生 loop 为真、且没被游戏自己暂停。
   *
   * el.loop 只读不写 —— 这是本次修复的核心约束。插件每帧都会写一次 loop，
   * 我们只在读的时候跟随；写回去会把 isPlayingWait() 与 autoEraseOnEnd 的判断改坏。
   * **尊重游戏自己的暂停**：某影片插件用 pause()/play() 控制待机动画的
   * 暂停态，暂停时 currentTime 当然不动 —— 那不是停滞。恢复交给 play() 钩子重新起帧。
   */
  function mediaLive(rec) {
    if (!rec || rec.dead) { return false; }
    try {
      if (rec.el.loop !== true) { return false; }
      if (rec.el.paused === true) { return false; }
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 取 {duration, time}；元数据没好（NaN / Infinity / 0）返回 null。 */
  function mediaPlaybackState(el) {
    try {
      var dur = el.duration;
      if (typeof dur !== 'number' || !isFinite(dur) || !(dur > 0)) { return null; }
      var t = el.currentTime;
      if (typeof t !== 'number' || !isFinite(t)) { return null; }
      return { duration: dur, time: t };
    } catch (e) {
      return null;
    }
  }

  function mediaHasFrameCallback(el) {
    return typeof el.requestVideoFrameCallback === 'function'
      && typeof el.cancelVideoFrameCallback === 'function';
  }

  function mediaCancelFrame(rec) {
    if (!rec || rec.rvfcId === null || rec.rvfcId === undefined) { return; }
    try {
      if (mediaHasFrameCallback(rec.el)) { rec.el.cancelVideoFrameCallback(rec.rvfcId); }
    } catch (e) { /* ignore */ }
    rec.rvfcId = null;
  }

  /**
   * 重新订阅一次帧回调（幂等：已有在途订阅就不动）。
   * rVFC 不可用的元素（<audio>、老内核）完全走 500ms 扫描兜底。
   */
  function mediaArm(rec) {
    if (!rec || rec.dead || (rec.rvfcId !== null && rec.rvfcId !== undefined)) { return; }
    var el = rec.el;
    if (!mediaHasFrameCallback(el)) { return; }
    try {
      rec.rvfcId = el.requestVideoFrameCallback(function () {
        try { mediaOnFrame(rec); } catch (e) { /* 一帧出错不能打断播放 */ }
      });
    } catch (e) {
      rec.rvfcId = null;
    }
  }

  /**
   * 主动回绕：在 EOS 之前把 currentTime 写回 0，元素永远不进入 ended。
   * 只在"原生 loop 为真 + 正在播放"时由帧回调/扫描调用。
   * 计数是"复位动作次数"（mediaRestarts 的既有语义）。
   */
  function mediaWrap(rec) {
    if (!rec || rec.dead) { return false; }
    var now = Date.now();
    if (rec.wrapAt && (now - rec.wrapAt) < MEDIA_WRAP_GUARD_MS) { return false; }
    rec.wrapAt = now;
    rec.lastTime = -1;
    mediaRestarts++;
    try {
      rec.el.currentTime = 0;
    } catch (e) { /* 无源 / 已卸载：下一帧再看 */ }
    safePlay(rec.el);
    return true;
  }

  /**
   * rVFC 每帧回调：离 EOS 还剩不到 MEDIA_WRAP_LEAD 就主动回绕。
   * 回绕之后 currentTime 从 0 继续增长；帧回调在 seek 期间可能断，扫描会补订阅。
   */
  function mediaOnFrame(rec) {
    rec.rvfcId = null;
    if (!rec || rec.dead) { return; }
    if (!mediaLive(rec)) { return; }  // 一次性视频 / 游戏暂停：链条到此为止
    var state = mediaPlaybackState(rec.el);
    if (!state) { mediaArm(rec); return; }
    if (state.time >= state.duration - MEDIA_WRAP_LEAD) {
      mediaWrap(rec);
    }
    mediaArm(rec);
  }

  /**
   * ended 只做观测，**绝不在这个回调里复位**。
   * 期望循环的元素在 EOS 之前就被 mediaWrap 拉回起点，这里永远不该被调用；
   * 一旦计数增长，就说明"不派发 ended"的不变量破了（probe().mediaEndedSeen 取证）。
   */
  function mediaOnEnded(event) {
    var el = (event && event.currentTarget) || this;
    try {
      if (!el) { return; }
      mediaEndedSeen++;
    } catch (e) { /* ignore */ }
  }

  /**
   * 登记元素（幂等）。play() 与 load() 都会走到这里：
   * 插件 createElement('video') → load() → autoplay = true，这条路径上
   * **没有** JS 侧 play() 调用，只 hook play() 会漏登记。
   * 这里只挂监听与帧回调，不读写 loop。
   */
  function mediaRecordFor(el) {
    if (!isVideoElement(el)) { return null; }
    var rec = mediaFind(el);
    if (rec) { mediaArm(rec); return rec; }
    rec = { el: el, lastTime: -1, rvfcId: null, wrapAt: 0, dead: false };
    mediaItems.push(rec);
    try { el.addEventListener('ended', mediaOnEnded, false); } catch (e) { /* ignore */ }
    mediaArm(rec);
    return rec;
  }

  /**
   * 定时扫描兜底（500ms）：rVFC 不可用的元素、以及帧回调意外断掉时的最后一道网。
   * 判据是"到 EOS 附近**且** currentTime 连续两轮不动 = 停滞"，正常回绕的元素
   * 永远走不到这条分支（回绕点在 duration-0.08，比容差更早）。
   */
  function mediaTick() {
    for (var i = 0; i < mediaItems.length; i++) {
      var rec = mediaItems[i];
      var el = rec.el;
      try {
        if (rec.dead) { continue; }
        if (el.loop !== true) { rec.lastTime = -1; continue; }
        // **尊重游戏自己的暂停**：暂停时 paused 为真且 currentTime 当然不动 —— 那不是停滞。
        if (el.paused) { rec.lastTime = -1; continue; }
        var state = mediaPlaybackState(el);
        if (!state) { rec.lastTime = -1; continue; }
        mediaArm(rec);  // 帧回调可能已断（元素换源、内核停帧）：顺手补一次订阅
        if (state.time < state.duration - MEDIA_EOS_SLACK) {
          rec.lastTime = state.time;
          continue;
        }
        if (rec.lastTime === state.time) {
          mediaWrap(rec);
        } else {
          rec.lastTime = state.time;
        }
      } catch (e) { /* 单个元素异常不影响其他元素 */ }
    }
  }

  /**
   * 循环兼容补丁：**完全不碰 loop**。
   *
   * 只做三件事：
   *   1. hook play()/load() 登记视频元素；
   *   2. 给登记元素订阅 rVFC，逐帧检查是否该主动回绕；
   *   3. 起 500ms 扫描兜底。
   *
   * 能力守卫只看 HTMLMediaElement：**不碰 document** —— e2e 的 node-vm 沙箱与自测 stub
   * 都没有 DOM，这里必须静默返回 false 而不是抛。
   */
  function patchMediaCompat() {
    try {
      if (typeof global.HTMLMediaElement === 'undefined' || typeof global.HTMLVideoElement === 'undefined') {
        mediaPatchState = 'unsupported';
        return false;
      }
      var proto = global.HTMLMediaElement.prototype;
      if (!proto) { mediaPatchState = 'unsupported'; return false; }
      if (mediaPatchState === 'attached') { return true; }

      if (typeof proto.play === 'function' && !belongsToUs(proto.play)) {
        orig.mediaPlay = proto.play;
        var mediaPlay = function () {
          try { mediaRecordFor(this); } catch (e) { /* ignore */ }
          return orig.mediaPlay.apply(this, arguments);
        };
        mediaPlay.__mochiboxHooked = true;
        mediaPlay.__mochiboxOriginal = orig.mediaPlay;
        proto.play = mediaPlay;
      }
      // load() 是 autoplay 元素的唯一登记点（插件在设置 autoplay 之前就调它）。
      if (typeof proto.load === 'function' && !belongsToUs(proto.load)) {
        orig.mediaLoad = proto.load;
        var mediaLoad = function () {
          try { mediaRecordFor(this); } catch (e) { /* ignore */ }
          return orig.mediaLoad.apply(this, arguments);
        };
        mediaLoad.__mochiboxHooked = true;
        mediaLoad.__mochiboxOriginal = orig.mediaLoad;
        proto.load = mediaLoad;
      }
      if (mediaTimer === null && typeof global.setInterval === 'function') {
        mediaTimer = global.setInterval(mediaTick, MEDIA_SCAN_MS);
      }
      mediaPatchState = 'attached';
      return true;
    } catch (e) {
      state.errors++;
      return false;
    }
  }

  // ------------------------------------------------------------------
  // 视频 alpha 桥接（2D canvas → WebGL）
  // ------------------------------------------------------------------
  //
  // 问题：WebKit 把 <video> 直接 texImage2D 上传时会把 alpha 抹掉（实测透明角点
  // 读回 [0,0,0,255]、整帧 a255=4096/4096）。转码产物本身 alpha 完好（alpha 平面
  // min=0），坏的只是**上传这一段**。
  //
  // 做法：先把当前帧 drawImage 到 2D canvas（drawImage 从 video 取帧保留 alpha，
  // 实测透明角点 [0,0,0,0]、直方图与 2D 逐项相同），再把 canvas 当纹理源上传。
  // 前提是 PIXI.BaseTexture 的 alphaMode=UNPACK(1)（= UNPACK_PREMULTIPLY_ALPHA_WEBGL
  // 为真）且 FLIP_Y=false —— 这两条都由 Pixi 默认值给出，不额外改全局状态。
  //
  // 只对**探测到 alpha** 的视频生效：没有 alpha 的视频不建桥、不加帧回调，
  // 保持原路径零开销（bg_light01 这类普通视频必须完全不受影响）。

  /// 'off' | 'attached' | 'unsupported'（无 PIXI / 无 DOM：自测与沙箱里静默降级）
  var mediaBridgeState = 'off';
  /// 正在桥接的视频数（probe().mediaBridged）
  var mediaBridged = 0;
  /// 累计桥接帧数（probe().mediaBridgeFrames），只增不清
  var mediaBridgeFrames = 0;
  /// video → 桥接记录。用 **WeakMap**：键是视频元素，视频被回收时记录跟着走，
  /// 不会像 mediaItems 那样把元素钉在内存里（本插件已有 video 泄漏问题，不再叠加）。
  var mediaBridgeMap = (typeof global.WeakMap === 'function') ? new global.WeakMap() : null;
  /// 活跃桥接（强引用，仅用于 uninstall 逐条撤销；stop 时同步移除）
  var mediaBridgeActive = [];
  var mediaBridgeTimer = null;
  var mediaBridgeTries = 0;
  var mediaBridgeOrigFrom = null;
  /// 桥接收尾巡检（1s）。rVFC 只在出帧时回调，视频「先暂停再销毁」时帧回调永久停住，
  /// 收尾不能只依赖它 —— 这是 mediaBridged 会 1→2→3 累积的根因。
  /// 只在有活跃桥接时起，全部停掉就 clearInterval（无桥接不空转）。
  var mediaBridgeSweepTimer = null;
  var MEDIA_BRIDGE_SWEEP_MS = 1000;
  /// 暂停是**正常**状态（游戏暂停/开菜单后要能恢复显示），所以暂停本身绝不判死；
  /// 只有「暂停 + 持续 N 秒无帧推进」并且「纹理已不在 BaseTextureCache，或曾经挂在
  /// 场景里、现在场景树里没人拿它」才收。
  var MEDIA_BRIDGE_STALL_MS = 3000;
  /// 被巡检（而不是 rVFC 路径）收掉的桥接数，probe().mediaBridgeReaped
  var mediaBridgeReaped = 0;
  /// 长边上限默认 640。本作立绘逻辑尺寸就是 640×640，1280 全尺寸要多传 4 倍像素；
  /// 本机实测 clearRect+drawImage 一次：640×640 p50 3.9–4.3ms、1280×1280 p50 4.2ms
  /// （都不超过 33.3ms 帧预算的 13%），所以 640 主要是省带宽与显存。
  /// 页面里读不到宿主的进程环境变量，
  /// 所以 MOCHI_MEDIA_BRIDGE_MAX 在页面侧映射为同名全局；NW.js 这类带 process 的
  /// 宿主再读 process.env。两处都没有就用 640。
  var MEDIA_BRIDGE_MAX_DEFAULT = 640;
  /// 探测画布边长：64×64=4096 像素，getImageData 约 1ms，只做一次并缓存结论。
  var MEDIA_BRIDGE_PROBE_PX = 64;

  function mediaBridgeLimit() {
    var raw = null;
    try {
      if (typeof global.MOCHI_MEDIA_BRIDGE_MAX !== 'undefined') {
        raw = global.MOCHI_MEDIA_BRIDGE_MAX;
      } else if (global.process && global.process.env) {
        raw = global.process.env.MOCHI_MEDIA_BRIDGE_MAX;
      }
    } catch (e) { raw = null; }
    var limit = parseInt(raw, 10);
    if (!(limit > 0)) { return MEDIA_BRIDGE_MAX_DEFAULT; }
    // 太小会让立绘糊成马赛克，太大等于没降；64 是下限，上限不设（验收可改大做对照）。
    return Math.max(64, limit);
  }

  function mediaBridgeNewCanvas(w, h) {
    var canvas = global.document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    return canvas;
  }

  /**
   * 自证式探测：把当前帧画到 64×64 的临时 2D canvas 上读 alpha。
   * 返回 true=有 alpha（需要桥接）/ false=整帧不透明 / null=这帧读不到（等下一次事件）。
   *
   * 为什么这样判有效：drawImage(video) 是保留 alpha 的（见本节开头），所以 2D 侧看到
   * 的 alpha 就是视频真实的 alpha。**不看文件名、不看 URL 后缀、不看宿主名单**。
   */
  function mediaBridgeProbe(video) {
    var size = MEDIA_BRIDGE_PROBE_PX;
    try {
      var canvas = mediaBridgeNewCanvas(size, size);
      var ctx = canvas.getContext('2d');
      if (!ctx) { return null; }
      ctx.clearRect(0, 0, size, size);
      ctx.drawImage(video, 0, 0, size, size);
      var data = ctx.getImageData(0, 0, size, size).data;
      for (var i = 3; i < data.length; i += 4) {
        if (data[i] < 255) { return true; }
      }
      return false;
    } catch (e) {
      return null;
    }
  }

  function mediaBridgeRecord(video) {
    if (!mediaBridgeMap) { return null; }
    var rec = mediaBridgeMap.get(video);
    if (rec) { return rec; }
    rec = {
      video: video,
      /// PIXI.Texture.from(video) 造出来的原纹理：桥接建好后把它指向 canvas，
      /// 已经贴到 Sprite 上的调用方（插件把纹理存进 Bitmap._baseTexture）就能跟上。
      original: null,
      texture: null,
      base: null,
      canvas: null,
      ctx: null,
      scaleMode: null,
      /// null=未探测 / true=有 alpha / false=无 alpha
      verdict: null,
      rvfcId: null,
      rafId: null,
      started: false,
      dead: false,
      src: '',
      vw: 0,
      vh: 0,
      lastTime: -1,
      /// 最近一次真正画出帧的时刻（ms）。巡检用它区分「暂停中」与「暂停后已没人要帧」。
      lastAdvance: 0,
      /// 这个桥接是否曾经被场景树里的精灵拿过。只有「曾经在、现在不在」才算不可达：
      /// 从没进过场景的视频（自测里的裸 Bitmap_Video）不能据此判死。
      seenInScene: false,
      listeners: []
    };
    mediaBridgeMap.set(video, rec);
    return rec;
  }

  function mediaBridgeListen(rec, type, fn) {
    try {
      rec.video.addEventListener(type, fn, false);
      rec.listeners.push([type, fn]);
    } catch (e) { /* ignore */ }
  }

  function mediaBridgeUnlisten(rec) {
    for (var i = 0; i < rec.listeners.length; i++) {
      try { rec.video.removeEventListener(rec.listeners[i][0], rec.listeners[i][1], false); } catch (e) { /* ignore */ }
    }
    rec.listeners.length = 0;
  }

  /** 画一张当前帧到 canvas 并上传。**每个视频帧只调一次**，重复调用等于白烧 CPU。 */
  function mediaBridgeFrame(rec) {
    if (!rec || rec.dead || !rec.ctx || !rec.base) { return false; }
    if (rec.base.destroyed) { return false; }
    var video = rec.video;
    if (!video || video.readyState < 2) { return false; }
    if (!mediaBridgeSyncSize(rec)) { return false; }
    try {
      // 必须先 clear：drawImage 是 source-over，透明像素不会抹掉上一帧的残留。
      rec.ctx.clearRect(0, 0, rec.canvas.width, rec.canvas.height);
      rec.ctx.drawImage(video, 0, 0, rec.canvas.width, rec.canvas.height);
      rec.base.update();
      rec.lastAdvance = nowMs();
      mediaBridgeFrames++;
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 给纹理套一个 0,0,w,h 的完整帧，frame/orig/trim 三件一起换。
   *
   * 为什么要三件一起换：Pixi 5.2.4 的 frame setter 只改 _frame 与 uvs，且
   * `if (!this.trim && !this.rotate) this.orig = frame` —— 我们的纹理在构造时就带了
   * trim，所以 orig/trim 会永远停在 1×1 占位矩形上。尺寸一旦变大，任何读 orig/trim
   * 的路径（Pixi 的 Sprite bounds、纹理打包器）拿到的都是错的。
   */
  function mediaBridgeApplyFrame(texture, w, h) {
    if (!texture) { return; }
    var rect = new global.PIXI.Rectangle(0, 0, w, h);
    texture.frame = rect;
    texture.orig = rect;
    texture.trim = rect;
  }

  /**
   * 把创建时挂在旧 baseTexture 上的 update/loaded 监听搬到新 base 上。
   *
   * Pixi 5 的 Texture 构造器只在 noFrame 时挂一次
   * `baseTexture.on('update', this.onBaseTextureUpdated, this)`，挂的是**当时那个**
   * baseTexture。插件把 Texture.from(video) 的结果当 Bitmap 的 _baseTexture 用，
   * 我们为了保 alpha 把它的 baseTexture 直接换成 canvas BaseTexture —— 只换属性不搬
   * 监听，那条监听就留在了被丢弃的视频 baseTexture 上，且永远摘不掉：
   * Bitmap.destroy() → Texture.destroy() 只会对**当前** baseTexture（canvas）调 off，
   * 视频 baseTexture 上的引用照样活着。之后 VideoResource 每个 tick 都会
   * emit('update')，回调落到已销毁纹理（_frame=null）上，onBaseTextureUpdated 的
   * else 分支执行 `this.frame = this._frame`，setter 第一行 `var x = frame.x` 就炸
   * （pixi.js:16671，TypeError: null is not an object）。
   *
   * 换 base 时同步搬监听，destroy 才能在正确的 base 上解绑。
   */
  function mediaBridgeMoveUpdateListener(texture, base) {
    var old = texture && texture.baseTexture;
    if (!old || !base || old === base) { return; }
    if (typeof old.off !== 'function' || typeof base.on !== 'function') { return; }
    try {
      old.off('update', texture.onBaseTextureUpdated, texture);
      old.off('loaded', texture.onBaseTextureUpdated, texture);
      base.on('update', texture.onBaseTextureUpdated, texture);
    } catch (e) { /* 单个纹理搬家失败不影响其他桥接 */ }
  }

  /**
   * 尺寸对齐：canvas 收到长边上限内，**逻辑尺寸保持 videoWidth/videoHeight**。
   *
   * 保持逻辑尺寸靠 resolution：BaseTexture.width = 真实像素 / resolution，所以
   * 640 像素的 canvas 配 resolution=0.5 就仍然是 1280 逻辑像素 —— MZ 的
   * Sprite._refresh 按纹理宽高裁 frame，尺寸一旦变小立绘就会缩水。
   *
   * 元数据没到时调用方已建好 1×1 占位（B.5），loadedmetadata 后再走这里改尺寸。
   */
  function mediaBridgeSyncSize(rec) {
    var video = rec.video;
    if (!video) { return false; }
    var vw = video.videoWidth | 0;
    var vh = video.videoHeight | 0;
    if (!(vw > 0 && vh > 0)) { return false; }
    var limit = mediaBridgeLimit();
    var scale = Math.min(1, limit / Math.max(vw, vh));
    var cw = Math.max(1, Math.round(vw * scale));
    var ch = Math.max(1, Math.round(vh * scale));
    if (rec.vw === vw && rec.vh === vh && rec.canvas.width === cw && rec.canvas.height === ch) {
      return true;
    }
    rec.vw = vw;
    rec.vh = vh;
    rec.canvas.width = cw;
    rec.canvas.height = ch;
    var resolution = cw / vw;
    try {
      if (typeof rec.base.setSize === 'function') {
        rec.base.setSize(vw, vh, resolution);
      } else {
        rec.base.width = vw;
        rec.base.height = vh;
        rec.base.resolution = resolution;
        rec.base.update();
      }
      // baseTexture 尺寸（setSize / width+height）与纹理 frame/orig/trim 必须同步改，
      // 只改一边会留下 1×1 或 0×0 的失效 frame，插件随后 setFrame 就会踩空。
      mediaBridgeApplyFrame(rec.texture, vw, vh);
      if (rec.original && rec.original !== rec.texture) { mediaBridgeApplyFrame(rec.original, vw, vh); }
    } catch (e) {
      return false;
    }
    return true;
  }

  /** 把原纹理指向 canvas：插件的 Sprite 每帧只读 Bitmap._baseTexture，不需要重贴。 */
  function mediaBridgeLinkTexture(rec) {
    var original = rec.original;
    if (!original || original === rec.texture || !rec.base) { return; }
    // 尺寸还没到（1×1 占位阶段）：这时换 texture 会让 MZ 把 frame 裁成 0×0，
    // 等 loadedmetadata 之后再换。
    if (!(rec.vw > 0 && rec.vh > 0)) { return; }
    try {
      // 顺序要紧：先搬监听，再换 baseTexture。Pixi 的 destroy 用「当前 baseTexture」
      // 解绑，监听没搬走就等于把一条死回调永久钉在视频 baseTexture 上。
      mediaBridgeMoveUpdateListener(original, rec.base);
      original.baseTexture = rec.base;
      mediaBridgeApplyFrame(original, rec.vw, rec.vh);
    } catch (e) { /* 单个纹理异常不影响其他桥接 */ }
  }

  function mediaBridgeAlive(rec) {
    var video = rec.video;
    if (!video) { return false; }
    if (!rec.base || rec.base.destroyed) { return false; }   // 纹理被 destroy
    // 插件 Bitmap.destroy() destroy 的是它手里的 Texture（= 我们最初返回的原纹理）：
    // Pixi 5 的 Texture.destroy 会把 _frame 置 null 并解除 base 引用。立绘已经没人
    // 用了，停桥，别再往死人身上喂帧。
    if (rec.original && rec.original._frame === null) { return false; }
    if (rec.texture && rec.texture._frame === null) { return false; }   // 桥接纹理本身被 destroy
    if (video.readyState === 0) { return false; }            // 元素被卸载 / 移除
    var src = video.currentSrc || video.src || '';
    return src === rec.src;                                   // src 变了 = 换了一个视频
  }

  function mediaBridgeArm(rec) {
    if (!rec || rec.dead || rec.rvfcId !== null || rec.rafId !== null) { return; }
    var video = rec.video;
    if (!video) { return; }
    if (typeof video.requestVideoFrameCallback === 'function') {
      try {
        rec.rvfcId = video.requestVideoFrameCallback(function () {
          rec.rvfcId = null;
          mediaBridgeTick(rec);
        });
      } catch (e) { rec.rvfcId = null; }
      return;
    }
    // 没有 rVFC 的内核（老 WebKit）退化成 rAF：靠 currentTime 变化去重，
    // 不会变成每帧都 drawImage。
    if (typeof global.requestAnimationFrame !== 'function') { return; }
    rec.rafId = global.requestAnimationFrame(function () {
      rec.rafId = null;
      mediaBridgeTick(rec);
    });
  }

  function mediaBridgeTick(rec) {
    if (!rec || rec.dead) { return; }
    try {
      if (!mediaBridgeAlive(rec)) { mediaBridgeStop(rec); return; }
      var video = rec.video;
      if (rec.rvfcId === null && rec.rafId === null && typeof video.requestVideoFrameCallback !== 'function') {
        // rAF 兜底：只有时间真的动了才重画。
        if (video.paused !== true && video.currentTime !== rec.lastTime) {
          rec.lastTime = video.currentTime;
          mediaBridgeFrame(rec);
        }
      } else {
        mediaBridgeFrame(rec);
      }
    } catch (e) { /* 一帧出错不能打断播放 */ }
    mediaBridgeArm(rec);
  }

  /**
   * 建桥：canvas + BaseTexture + Texture + 逐帧回调。
   * 尺寸拿不到时按 1×1 占位，loadedmetadata 后由 mediaBridgeEnsure 改到真实尺寸。
   */
  function mediaBridgeBuild(rec, options) {
    if (!rec || rec.dead || rec.texture) { return false; }
    var PIXI = global.PIXI;
    if (!PIXI || !PIXI.BaseTexture || !PIXI.Texture || !global.document) { return false; }
    var scaleMode = rec.scaleMode;
    if (scaleMode === null || scaleMode === undefined) {
      scaleMode = (options && options.scaleMode !== undefined) ? options.scaleMode
        : (PIXI.settings ? PIXI.settings.SCALE_MODE : 0);
    }
    var alphaMode = (PIXI.ALPHA_MODES && typeof PIXI.ALPHA_MODES.UNPACK === 'number')
      ? PIXI.ALPHA_MODES.UNPACK : 1;
    try {
      var canvas = mediaBridgeNewCanvas(1, 1);
      var ctx = canvas.getContext('2d');
      if (!ctx) { return false; }
      var base = new PIXI.BaseTexture(canvas, {
        scaleMode: scaleMode,
        alphaMode: alphaMode,
        resolution: 1
      });
      var texture = new PIXI.Texture(base, new PIXI.Rectangle(0, 0, 1, 1));
      rec.canvas = canvas;
      rec.ctx = ctx;
      rec.base = base;
      rec.texture = texture;
      rec.scaleMode = scaleMode;
      rec.src = rec.video.currentSrc || rec.video.src || '';
      mediaBridgeListen(rec, 'loadedmetadata', function () {
        try { mediaBridgeEnsure(rec); } catch (e) { /* ignore */ }
      });
      // 暂停态下 seek 不会触发 rVFC：补一次，否则会停在旧帧上。
      mediaBridgeListen(rec, 'seeked', function () {
        try { mediaBridgeFrame(rec); } catch (e) { /* ignore */ }
      });
      mediaBridgeSyncSize(rec);
      mediaBridgeFrame(rec);
      return true;
    } catch (e) {
      return false;
    }
  }

  function mediaBridgeEnsure(rec) {
    if (!rec || rec.dead || !rec.base) { return; }
    if (!mediaBridgeAlive(rec)) { mediaBridgeStop(rec); return; }
    if (!mediaBridgeSyncSize(rec)) { return; }
    mediaBridgeLinkTexture(rec);   // 占位阶段没换成的纹理，在这里补上
    mediaBridgeFrame(rec);
  }

  /** 探测结论落地：真有 alpha 才建桥 + 换纹理 + 起逐帧回调。 */
  function mediaBridgeEvaluate(rec) {
    if (!rec || rec.dead || rec.verdict !== null) { return; }
    var video = rec.video;
    if (!video || video.readyState < 2) { return; }
    var verdict = mediaBridgeProbe(video);
    if (verdict === null) { return; }   // 这一帧还读不到，等 canplay/loadeddata 再来
    rec.verdict = verdict;
    mediaBridgeUnlisten(rec);           // 一次性：结论已缓存，不再挂就绪事件
    if (!verdict) { return; }           // 无 alpha：保持原路径，零开销
    if (!mediaBridgeBuild(rec)) { return; }
    mediaBridgeLinkTexture(rec);
    if (!rec.started) {
      rec.started = true;
      rec.lastAdvance = nowMs();
      mediaBridgeActive.push(rec);
      mediaBridged++;
      // 有桥才起巡检；最后一条停掉时由 mediaBridgeStop / mediaBridgeSweep 关掉。
      mediaBridgeSweepStart();
    }
    mediaBridgeArm(rec);
  }

  /** 就绪后探测：已就绪的立刻同步探测（约 1ms），没就绪的等 loadeddata / canplay。 */
  function mediaBridgeSchedule(rec) {
    if (!rec || rec.dead || rec.verdict !== null) { return; }
    var ready = function () {
      try { mediaBridgeEvaluate(rec); } catch (e) { /* ignore */ }
    };
    if (rec.video.readyState >= 2) { ready(); return; }
    if (rec.listeners.length > 0) { return; }
    mediaBridgeListen(rec, 'loadeddata', ready);
    mediaBridgeListen(rec, 'canplay', ready);
  }

  function mediaBridgeStop(rec) {
    if (!rec || rec.dead) { return; }
    rec.dead = true;
    try {
      if (rec.rvfcId !== null && rec.video && typeof rec.video.cancelVideoFrameCallback === 'function') {
        rec.video.cancelVideoFrameCallback(rec.rvfcId);
      }
    } catch (e) { /* ignore */ }
    rec.rvfcId = null;
    try {
      if (rec.rafId !== null && typeof global.cancelAnimationFrame === 'function') { global.cancelAnimationFrame(rec.rafId); }
    } catch (e) { /* ignore */ }
    rec.rafId = null;
    mediaBridgeUnlisten(rec);
    if (rec.started) {
      rec.started = false;
      mediaBridged = Math.max(0, mediaBridged - 1);
    }
    for (var i = mediaBridgeActive.length - 1; i >= 0; i--) {
      if (mediaBridgeActive[i] === rec) { mediaBridgeActive.splice(i, 1); }
    }
    // 不 destroy：游戏可能还在渲染最后一帧，destroy 会让画面整个消失。
    // 只断引用，剩下的交给 GC。
    try { if (mediaBridgeMap) { mediaBridgeMap.delete(rec.video); } } catch (e) { /* ignore */ }
    rec.video = null;
    rec.base = null;
    rec.canvas = null;
    rec.ctx = null;
    rec.texture = null;
    rec.original = null;
    // 最后一条桥接停掉就把巡检关掉：没有桥接时不许有定时器空转。
    if (mediaBridgeActive.length === 0) { mediaBridgeSweepStop(); }
  }

  /**
   * 视频元素是否还能从 PIXI 的纹理缓存到达。
   * 桥接纹理换成 canvas 之后，视频自己的 BaseTexture 仍挂在 BaseTextureCache 上；
   * 插件把 Bitmap 销毁、视频不再参与渲染后，这里就找不到以它为 source 的 baseTexture。
   * 拿不到缓存（非 Pixi 5 / 沙箱）时返回 true：**不据此判死**，宁可多留一轮。
   */
  function mediaBridgeCached(rec) {
    var video = rec.video;
    var PIXI = global.PIXI;
    var cache = PIXI && PIXI.utils && PIXI.utils.BaseTextureCache;
    if (!video || !cache) { return true; }
    try {
      for (var key in cache) {
        if (!Object.prototype.hasOwnProperty.call(cache, key)) { continue; }
        var base = cache[key];
        var resource = base && base.resource;
        if (resource && (resource.source === video || resource.video === video)) { return true; }
      }
    } catch (e) {
      return true;
    }
    return false;
  }

  /**
   * 桥接的纹理是否还被场景树里的某个精灵拿着。
   *
   * 为什么需要它：插件销毁 Bitmap 时如果视频还没 loaded，Bitmap_Video.destroy 会走
   * 「等加载完再销毁」的延迟分支；在这期间精灵已经从场景里消失，但 rec 仍攥着
   * 原纹理（_frame 不为 null），光看纹理就判不出来。实测这种孤儿会让 mediaBridged
   * 在 60s 内稳定停在 2（一个是画面上的立绘、一个是没人用的旧视频）。
   *
   * 只在「暂停 + 长时间无帧」时使用：正常暂停（窗口失焦/游戏暂停）时精灵还在场景里，
   * 结果是可达，不会被误停。拿不到场景（自测/沙箱）或树大得异常时保守返回 true。
   */
  function mediaBridgeInScene(rec) {
    var SM = global.SceneManager;
    if (!SM) { return true; }
    var roots = [];
    try {
      if (SM._scene) { roots.push(SM._scene); }
      if (SM._stack && SM._stack.length) {
        for (var s = 0; s < SM._stack.length; s++) { if (SM._stack[s]) { roots.push(SM._stack[s]); } }
      }
    } catch (e) { return true; }
    if (roots.length === 0) { return true; }
    var original = rec.original;
    var texture = rec.texture;
    var stack = roots.slice();
    var guard = 0;
    while (stack.length > 0 && guard < 20000) {
      var node = stack.pop();
      guard++;
      if (!node) { continue; }
      try {
        if (node.texture === original || node.texture === texture) { return true; }
        if (node.texture && node.texture.baseTexture === original) { return true; }
        var bmp = node._bitmap || node.bitmap;
        if (bmp && (bmp._baseTexture === original || bmp._baseTexture === texture)) { return true; }
      } catch (e) { /* 单个节点异常跳过，不影响其他节点 */ }
      var children = node.children;
      if (children) {
        for (var i = 0; i < children.length; i++) { stack.push(children[i]); }
      }
    }
    // 走满上限说明这棵树大得反常：保守认为可达，宁可多留一轮也不误停。
    return guard >= 20000;
  }

  /** 暂停中且已经 N 秒没有任何一帧被画出来（正常暂停要恢复，所以这只是判定的前置条件之一）。 */
  function mediaBridgeStalled(rec) {
    if (!(rec.lastAdvance > 0)) { return false; }
    return (nowMs() - rec.lastAdvance) >= MEDIA_BRIDGE_STALL_MS;
  }

  function mediaBridgeSweepStop() {
    if (mediaBridgeSweepTimer === null) { return; }
    try { global.clearInterval(mediaBridgeSweepTimer); } catch (e) { /* ignore */ }
    mediaBridgeSweepTimer = null;
  }

  function mediaBridgeSweepStart() {
    if (mediaBridgeSweepTimer !== null || typeof global.setInterval !== 'function') { return; }
    mediaBridgeSweepTimer = global.setInterval(function () {
      try { mediaBridgeSweep(); } catch (e) { /* 巡检自己永不抛给定时器 */ }
    }, MEDIA_BRIDGE_SWEEP_MS);
  }

  /**
   * 低频收尾巡检（1s）：补 rVFC 停摆时的收口。
   *
   * 为什么必须存在：某影片插件的 Bitmap_Video.destroy() 是 **先 pause 再断开
   * video 引用**。暂停后 requestVideoFrameCallback 不再出帧，mediaBridgeTick 就再也
   * 不会被调 —— 原纹理已被 destroy（_frame=null）、video 也废了，但没人执行
   * mediaBridgeStop，mediaBridged 不归零，video + 640×640 canvas + 纹理被
   * mediaBridgeActive 强引用住。实测反复加载 1→2→3 累积。
   *
   * 判据只用已有的 mediaBridgeAlive（纹理 destroy / readyState=0 / src 变了），
   * 外加「暂停 + 长时间无帧 + 已不在 BaseTextureCache」这一条兜底；**暂停本身不判死**，
   * 所以游戏暂停、开菜单、切窗口都不会误停正在用的桥接。
   */
  function mediaBridgeSweep() {
    if (mediaBridgeActive.length === 0) { mediaBridgeSweepStop(); return; }
    // 先快照：mediaBridgeStop 会就地改 mediaBridgeActive。
    var list = mediaBridgeActive.slice();
    var reaped = 0;
    for (var i = 0; i < list.length; i++) {
      var rec = list[i];
      if (!rec || rec.dead) { continue; }
      try {
        var dead = !mediaBridgeAlive(rec);
        if (!rec.seenInScene && mediaBridgeInScene(rec)) { rec.seenInScene = true; }
        if (!dead && rec.video && rec.video.paused === true && mediaBridgeStalled(rec)) {
          // 暂停本身不判死：只有「纹理已不在 PIXI 缓存」，或「曾经挂在场景里、现在
          // 场景树里已经没人拿它」才说明这个视频确实被丢掉了。后半条专治插件在
          // 视频未 loaded 时销毁 Bitmap 的延迟分支（纹理没被 destroy 的孤儿）。
          dead = !mediaBridgeCached(rec) || (rec.seenInScene && !mediaBridgeInScene(rec));
        }
        if (dead) {
          reaped++;
          mediaBridgeStop(rec);
        }
      } catch (e) { /* 单条异常不影响其他桥接 */ }
    }
    if (reaped > 0) { mediaBridgeReaped += reaped; }
    if (mediaBridgeActive.length === 0) { mediaBridgeSweepStop(); }
  }

  /**
   * hook PIXI.Texture.from：视频源先探测，需要桥接就返回 canvas 纹理。
   * 其余参数与返回值语义**原样透传**（options/strict 都交给原实现），
   * 所以缓存、scaleMode 这些既有依赖不受影响。
   */
  function mediaBridgeWrapFrom() {
    var PIXI = global.PIXI;
    if (!PIXI || !PIXI.Texture || typeof PIXI.Texture.from !== 'function') { return false; }
    var base = PIXI.Texture.from;
    if (belongsToUs(base)) {
      mediaBridgeOrigFrom = base.__mochiboxOriginal || mediaBridgeOrigFrom;
      mediaBridgeState = 'attached';
      return true;
    }
    mediaBridgeOrigFrom = base;
    var wrapper = function (source, options, strict) {
      var isVideo = (typeof global.HTMLVideoElement !== 'undefined')
        && (source instanceof global.HTMLVideoElement);
      if (!isVideo || !mediaBridgeMap) { return base.apply(this, arguments); }
      try {
        var rec = mediaBridgeRecord(source);
        if (rec) {
          if (rec.texture) { return rec.texture; }
          if (rec.verdict === false) { return base.apply(this, arguments); }
          if (rec.verdict === true) {
            if (!mediaBridgeBuild(rec, options)) { return base.apply(this, arguments); }
            return rec.texture;
          }
          var texture = base.apply(this, arguments);
          if (!rec.original) { rec.original = texture; }
          if (rec.scaleMode === null && options && options.scaleMode !== undefined) {
            rec.scaleMode = options.scaleMode;
          }
          mediaBridgeSchedule(rec);
          return texture;
        }
      } catch (e) {
        state.errors++;
      }
      return base.apply(this, arguments);
    };
    wrapper.__mochiboxHooked = true;
    wrapper.__mochiboxOriginal = base;
    PIXI.Texture.from = wrapper;
    mediaBridgeState = 'attached';
    return true;
  }

  /**
   * 装桥接层。PIXI 是游戏脚本，Agent 常常比它先就位：没就绪就 500ms 轮询，
   * 最多 60s；命中即停，装不上记 'unsupported'（自测/沙箱里就是这条路）。
   */
  function patchMediaBridge() {
    try {
      if (mediaBridgeState === 'attached') { return true; }
      if (typeof global.document === 'undefined' || !mediaBridgeMap) {
        mediaBridgeState = 'unsupported';
        return false;
      }
      if (mediaBridgeWrapFrom()) { return true; }
      if (mediaBridgeTimer === null && typeof global.setInterval === 'function') {
        mediaBridgeTries = 0;
        mediaBridgeTimer = global.setInterval(function () {
          mediaBridgeTries++;
          var ok = false;
          try { ok = mediaBridgeWrapFrom(); } catch (e) { ok = false; }
          if (ok || mediaBridgeTries > 120) {
            try { global.clearInterval(mediaBridgeTimer); } catch (e) { /* ignore */ }
            mediaBridgeTimer = null;
            if (!ok) { mediaBridgeState = 'unsupported'; }
          }
        }, 500);
      }
    } catch (e) {
      state.errors++;
    }
    return false;
  }

  function unpatchMediaBridge() {
    // 巡检先停：它拿着即将失效的 mediaBridgeActive/纹理表。
    mediaBridgeSweepStop();
    if (mediaBridgeTimer !== null) {
      try { global.clearInterval(mediaBridgeTimer); } catch (e) { /* ignore */ }
      mediaBridgeTimer = null;
    }
    for (var i = mediaBridgeActive.length - 1; i >= 0; i--) {
      mediaBridgeStop(mediaBridgeActive[i]);
    }
    mediaBridgeActive = [];
    mediaBridged = 0;
    mediaBridgeFrames = 0;
    mediaBridgeReaped = 0;
    // WeakMap 没有 clear()：整张换掉，旧记录交给 GC。
    if (typeof global.WeakMap === 'function') { mediaBridgeMap = new global.WeakMap(); }
    try {
      if (mediaBridgeOrigFrom && global.PIXI && global.PIXI.Texture && belongsToUs(global.PIXI.Texture.from)) {
        global.PIXI.Texture.from = mediaBridgeOrigFrom;
      }
    } catch (e) { /* ignore */ }
    mediaBridgeOrigFrom = null;
    mediaBridgeState = 'off';
  }

  function install() {
    if (installed) { return true; }
    try {
      // 重新 attach / 重新注入：清掉上一轮的采集窗口，保证首句一定上报。
      resetCaptureWindow();
      installedHooks = [];
      if (hookDrawTextEx()) { installedHooks.push('Window_Base.drawTextEx'); }
      if (hookDrawText()) { installedHooks.push('Window_Base.drawText'); }
      if (hookBitmapDrawText()) { installedHooks.push('Bitmap.drawText'); }
      if (hookStartMessage()) { installedHooks.push('Window_Message.startMessage'); }
      // 数据回写：DataManager / Game_Actor 可能还没定义（rpg_managers.js 晚于注入），
      // 没装上就交给补装定时器。
      if (!hookDataPatch()) { scheduleDataPatchHook(); }
      if (hookBattleLogDrawTextEx()) {
        installedHooks.push('Window_BattleLog.drawTextEx');
      } else {
        scheduleBattleLogHook();
      }
      // 字体链在 install 时先装一次；config 变更时再调（幂等，只读 state 重拼链）。
      applyGameFont();
      installed = installedHooks.length > 0;
      // uninstall 会把 $data* 与 _name 还原、账本清空；重新 install 时若不等下一句译文，
      // 要拖到下一次 createGameObjects 才变中文。排一次防抖回写补齐（不直接同步调：
      // 首次注入时语料还是空的，同步跑一遍纯属浪费主线程）。
      try { scheduleDataPatch(); } catch (e4) { state.errors++; }
      if (typeof global.Window_Base === 'undefined' && typeof global.Bitmap === 'undefined') {
        emit('error', { code: 'engine_symbols_missing', message: 'Window_Base / Bitmap 均不存在', stack: null });
      }
      emit('hello', {
        agentVersion: VERSION,
        ua: (typeof global.navigator !== 'undefined' && global.navigator.userAgent) ? global.navigator.userAgent : '',
        href: (global.location && global.location.href) ? global.location.href : '',
        engineGuess: 'mvmz',
        hooks: installedHooks,
        caps: ['rpc', 'cheat', 'scan']
      });
      // 放在 hello 之后：hello 是宿主握手生命线，补丁绝不能把它弄丢。
      try { patchMediaCompat(); } catch (e2) { state.errors++; }
      // alpha 桥接依赖游戏的 PIXI（通常比 Agent 晚到），所以这条自己带轮询。
      try { patchMediaBridge(); } catch (e3) { state.errors++; }
    } catch (e) {
      state.errors++;
      reportHookError(e);
    }
    return installed;
  }

  function uninstall() {
    try {
      if (typeof global.Window_Base !== 'undefined' && global.Window_Base.prototype) {
        var baseProto = global.Window_Base.prototype;
        if (orig.drawTextEx && belongsToUs(baseProto.drawTextEx)) { baseProto.drawTextEx = orig.drawTextEx; }
        if (orig.drawText && belongsToUs(baseProto.drawText)) { baseProto.drawText = orig.drawText; }
      }
      if (typeof global.Bitmap !== 'undefined' && global.Bitmap.prototype) {
        var bitmapProto = global.Bitmap.prototype;
        if (orig.bitmapDrawText && belongsToUs(bitmapProto.drawText)) {
          bitmapProto.drawText = orig.bitmapDrawText;
        }
        if (orig.makeFontNameText) {
          bitmapProto._makeFontNameText = orig.makeFontNameText;
        } else if (bitmapProto._makeFontNameText && bitmapProto._makeFontNameText.__mochiboxFont) {
          try { delete bitmapProto._makeFontNameText; } catch (e4) { bitmapProto._makeFontNameText = undefined; }
        }
      }
      if (typeof global.Window_Base !== 'undefined' && global.Window_Base.prototype && orig.standardFontFace) {
        global.Window_Base.prototype.standardFontFace = orig.standardFontFace;
      }
      if (typeof global.Window_Message !== 'undefined' && global.Window_Message.prototype) {
        if (orig.startMessage && belongsToUs(global.Window_Message.prototype.startMessage)) {
          global.Window_Message.prototype.startMessage = orig.startMessage;
        }
      }
      if (battleLogHookTimer !== null) {
        try { global.clearInterval(battleLogHookTimer); } catch (e5) { /* ignore */ }
        battleLogHookTimer = null;
      }
      if (typeof global.Window_BattleLog !== 'undefined' && global.Window_BattleLog.prototype) {
        if (orig.battleLogDrawTextEx && belongsToUs(global.Window_BattleLog.prototype.drawTextEx)) {
          global.Window_BattleLog.prototype.drawTextEx = orig.battleLogDrawTextEx;
        }
      }
      // 数据回写：先把 $data* 与 Game_Actor._name 还原（否则关掉翻译后 HUD / 状态窗还是中文），
      // 再撤 hook。顺序不能反：还原依赖账本，账本只由本模块维护。
      try { restoreDataPatch(); } catch (e8) { state.errors++; }
      if (dataPatchHookTimer !== null) {
        try { global.clearInterval(dataPatchHookTimer); } catch (e9) { /* ignore */ }
        dataPatchHookTimer = null;
      }
      if (global.DataManager) {
        if (orig.createGameObjects && belongsToUs(global.DataManager.createGameObjects)) {
          global.DataManager.createGameObjects = orig.createGameObjects;
        }
        if (orig.extractSaveContents && belongsToUs(global.DataManager.extractSaveContents)) {
          global.DataManager.extractSaveContents = orig.extractSaveContents;
        }
      }
      if (global.Game_Actor && global.Game_Actor.prototype && orig.setName
          && belongsToUs(global.Game_Actor.prototype.setName)) {
        global.Game_Actor.prototype.setName = orig.setName;
      }
      // 媒体补丁：定时器先停（否则会拿着即将失效的表继续跑），再逐个元素撤订阅，
      // 最后还原 play / load 钩子。**loop 从未被写过，所以这里没有需要还原的 loop**。
      if (mediaTimer !== null) {
        try { global.clearInterval(mediaTimer); } catch (e6) { /* ignore */ }
        mediaTimer = null;
      }
      for (var mi = 0; mi < mediaItems.length; mi++) {
        var mrec = mediaItems[mi];
        mrec.dead = true;
        mediaCancelFrame(mrec);
        try { mrec.el.removeEventListener('ended', mediaOnEnded, false); } catch (e7) { /* ignore */ }
      }
      if (typeof global.HTMLMediaElement !== 'undefined' && global.HTMLMediaElement.prototype) {
        var mediaProto = global.HTMLMediaElement.prototype;
        if (orig.mediaPlay && belongsToUs(mediaProto.play)) { mediaProto.play = orig.mediaPlay; }
        if (orig.mediaLoad && belongsToUs(mediaProto.load)) { mediaProto.load = orig.mediaLoad; }
      }
      mediaItems = [];
      mediaRestarts = 0;
      mediaLoopFails = 0;
      mediaEndedSeen = 0;
      mediaPatchState = 'off';
      // 桥接层：取消所有 rVFC、清 WeakMap、把 PIXI.Texture.from 还原。
      unpatchMediaBridge();
      installed = false;
      installedHooks = [];
    } catch (e) {
      state.errors++;
    }
    return true;
  }

  function hello() {
    try {
      // 新会话开始：清窗口，否则第二轮 attach 会因上一轮窗口未过期而采不到任何文本。
      resetCaptureWindow();
      emit('hello', {
        agentVersion: VERSION,
        ua: (typeof global.navigator !== 'undefined' && global.navigator.userAgent) ? global.navigator.userAgent : '',
        href: (global.location && global.location.href) ? global.location.href : '',
        engineGuess: 'mvmz',
        hooks: installedHooks,
        caps: ['rpc', 'cheat', 'scan']
      });
    } catch (e) {
      state.errors++;
    }
  }

  function probe() {
    try {
      return JSON.stringify({
        installed: installed,
        hooks: installedHooks,
        errors: state.errors,
        emitted: state.emitted,
        replaced: state.replaced,
        skipped: state.skipped,
        mergeFallback: state.mergeFallback,
        mapSize: countKeys(),
        enabled: state.enabled,
        fontScale: state.fontScale,
        fontFamily: state.fontFamily,
        dataPatchEnabled: state.dataPatchEnabled,
        dataPatchNames: state.dataPatchNames,
        mediaPatch: mediaPatchState,
        mediaVideos: mediaItems.length,
        mediaRestarts: mediaRestarts,
        mediaLoopFails: mediaLoopFails,
        mediaEndedSeen: mediaEndedSeen,
        mediaBridge: mediaBridgeState,
        mediaBridged: mediaBridged,
        mediaBridgeFrames: mediaBridgeFrames,
        mediaBridgeReaped: mediaBridgeReaped,
        mediaBridgeSweeping: mediaBridgeSweepTimer !== null,
        dataPatch: dataPatchStats()
      });
    } catch (e) {
      return '{}';
    }
  }

  // ------------------------------------------------------------------
  // 入站命令
  // ------------------------------------------------------------------

  function requestRepaint() {
    try {
      if (typeof global.__stubRepaint === 'function') {
        global.__stubRepaint();
        return;
      }
      var scene = global.SceneManager && global.SceneManager._scene;
      if (!scene) { return; }
      var refresh = function (obj) {
        try { obj.refresh(); } catch (e) { /* ignore */ }
      };
      if (scene._windowLayer && scene._windowLayer.children) {
        for (var i = 0; i < scene._windowLayer.children.length; i++) { refresh(scene._windowLayer.children[i]); }
      }
      if (scene._window && scene._window !== scene) { refresh(scene._window); }
      if (scene._messageWindow) { refresh(scene._messageWindow); }
    } catch (e) {
      state.errors++;
    }
  }

  function inbox(json) {
    try {
      var message = (typeof json === 'string') ? JSON.parse(json) : json;
      if (!message || typeof message !== 'object') { return; }
      var type = message.type;
      var payload = message.payload || {};
      if (type === 'config') {
        if (typeof payload.enabled === 'boolean') {
          var wasEnabled = state.enabled;
          state.enabled = payload.enabled;
          // 关掉翻译时把当前消息窗恢复原文：只改 state 的话，已经替换过的
          // $gameMessage._texts 会一直是译文，直到玩家点下一句。
          if (!payload.enabled) {
            restoreReplacedTexts();
            // 数据表 / Game_Actor._name 同理：只关绘制 hook 的话，HUD 与状态窗读的仍是
            // 已经写进数据表的中文，会一直中文到重开游戏。
            // 剧情改名的账**留着**（'keep-ledger'）：名字还原成日文，但 code 320 不会重放，
            // 抹掉就再也查不回来 —— re-enable 靠 patchDataTables 里的 resyncPlotActorNames() 重译。
            restoreDataPatch({ plotNames: 'keep-ledger' });
          } else if (!wasEnabled) {
            // 重新打开：账本已清空、数据表已还原成原文，用现有译文再回写一次。
            patchDataTables();
          }
        }
        // 数据回写两级开关。**字段缺失时保持当前值**（默认 true）：旧 Host 只发 enabled /
        // fontScale，不能因为没这两个键就把回写关掉（那是向后兼容的唯一判据）。
        //
        // 动作只在**值真的变了**时发生：同样的 config 会被重复推送（切后端、改字号、
        // 重连都会重发整份），每次都还原一遍会把玩家的中文名/播报打回日文。
        var wasDataPatchEnabled = state.dataPatchEnabled;
        var wasDataPatchNames = state.dataPatchNames;
        if (typeof payload.dataPatchEnabled === 'boolean') { state.dataPatchEnabled = payload.dataPatchEnabled; }
        if (typeof payload.dataPatchNames === 'boolean') { state.dataPatchNames = payload.dataPatchNames; }
        if (state.dataPatchEnabled === false) {
          // 整块退场：写回原文（含 _name）。剧情改名的账按 disable 的规矩留着（keep-ledger），
          // 否则重新打开后 code 320 不会重放，剧情名永远停在日文。
          if (wasDataPatchEnabled !== false) { restoreDataPatch({ plotNames: 'keep-ledger' }); }
        } else {
          // 父开关开着时子开关才能生效；子开关关掉只撤名字类，message / description /
          // profile 保持中文 —— 它们不参与插件换装联动。
          if (state.dataPatchNames === false && wasDataPatchNames !== false) {
            restoreDataPatchNames({ plotNames: 'keep-ledger' });
            // 刚才 cancelDataPatchTimer() 可能撤掉了一个待落地的批次（新译文刚到、非名字
            // 字段还没写）。重新排一次期把它补上：名字类已被计划过滤，不会写回名字。
            scheduleDataPatch();
          }
          // 任一开关**从关变开**才排期（同步直调会在 config 处理里扫整库）。
          // 判据是"现在是开 且 刚才是关"：只写 `was === false` 会让"子开关一直关着、
          // 每次 config 重发"也排一次期（虽然写不出东西，但白烧定时器）。
          if (wasDataPatchEnabled === false ||
              (state.dataPatchNames === true && wasDataPatchNames === false)) {
            scheduleDataPatch();
          }
        }
        if (typeof payload.gameFontFamily === 'string') { state.fontFamily = payload.gameFontFamily.trim(); }
        if (typeof payload.fontScale === 'number' && payload.fontScale > 0) { state.fontScale = payload.fontScale; }
        if (typeof payload.srcLang === 'string' && payload.srcLang) { srcLang = payload.srcLang; }
        if (typeof payload.tgtLang === 'string' && payload.tgtLang) { tgtLang = payload.tgtLang; }
        if (typeof payload.maxMapSize === 'number' && payload.maxMapSize > 0) { maxMapSize = payload.maxMapSize; bumpMapLimit(); }
        if (typeof payload.sessionToken === 'string' && payload.sessionToken) {
          if (sessionToken !== payload.sessionToken) { resetCaptureWindow(); }
          sessionToken = payload.sessionToken;
        }
        if (typeof payload.useBinding === 'boolean') { config.useBinding = payload.useBinding; }
        // 字体链每次绘制现算，这里只需确保 patch 还在（幂等），无需重打。
        applyGameFont();
        requestRepaint();
      } else if (type === 'setTranslation') {
        putTranslation(payload);
        scheduleDataPatch();
        requestRepaint();
      } else if (type === 'setTranslations') {
        var items = payload.items || [];
        for (var i = 0; i < items.length; i++) { putTranslation(items[i]); }
        // 译文晚到：防抖后把新到的条目补进 $data*（已写过的字段是空转）。
        scheduleDataPatch();
        requestRepaint();
      } else if (type === 'drop') {
        var keys = payload.keys || [];
        for (var j = 0; j < keys.length; j++) {
          if (Object.prototype.hasOwnProperty.call(translations, keys[j])) {
            translationCount--;
            try { delete translations[keys[j]]; } catch (e) { translations[keys[j]] = undefined; }
          }
        }
        if (translationCount < 0) { translationCount = 0; }
        state.mapSize = translationCount;
      } else if (type === 'clear') {
        translations = {};
        mapOrder = [];
        translationCount = 0;
        state.mapSize = 0;
        // 页面译文被整体抹掉（清理假译文后重发）：数据回写必须撤回，否则重发的新译文
        // 会被账本挡在门外（字段已是旧中文，再查表也查不到）。随后 pushAll 会重新触发回写。
        // 剧情改名例外：code 320 不会重放，_name 保留在场（plotNames: 'keep'）。
        restoreDataPatch({ plotNames: 'keep' });
        requestRepaint();
      } else if (type === 'ping') {
        emit('pong', { t: typeof payload.t === 'number' ? payload.t : nowMs() });
      } else if (type === 'rpc') {
        // 请求/应答：id 原样回填，Host 用它把结果配到等待中的调用上。
        handleRpc(payload);
      }
      // 替身页重绘入口（Fixtures/mv_stub/index.html 提供）
      if (typeof global.__stubRepaint === 'function') {
        try { global.__stubRepaint(); } catch (e) { /* ignore */ }
      }
    } catch (e) {
      state.errors++;
      try {
        emit('error', { code: 'inbox_error', message: String(e), stack: null });
      } catch (e2) { /* ignore */ }
    }
  }

  // ------------------------------------------------------------------
  // 对外对象
  // ------------------------------------------------------------------

  global.__mochibox = {
    version: VERSION,
    escapeTableVersion: ESCAPE_TABLE_VERSION,
    get installed() { return installed; },
    state: state,
    _orig: orig,
    install: install,
    uninstall: uninstall,
    hello: hello,
    inbox: inbox,
    drain: drain,
    requeue: requeue,
    emit: emit,
    probe: probe,
    rpc: handleRpc,
    caps: ['rpc', 'cheat', 'scan'],
    mapKeyOf: mapKeyOf,
    splitSegments: splitSegments,
    skipReasonOf: skipReasonOf,
    /// 只读诊断面：回写账本（单测断言原子批号 / 原文 / 译文）。
    dataPatch: { stats: dataPatchStats, records: dataPatchRecords }
  };

  try {
    install();
  } catch (e) {
    state.errors++;
  }
})(typeof window !== 'undefined' ? window : this);
