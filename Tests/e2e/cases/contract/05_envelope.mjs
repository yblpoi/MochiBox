/*
 * 05_envelope.mjs —— 信封协议：未知类型、drain 上限、requeue 回灌。
 *
 * 依据：`Resources/agent_mvmz.js` 的 inbox（type 分发）/ drain（DRAIN_LIMIT=50）/
 *      requeue（按上批签名去重、队首插回、容量沿用 MAX_OUTBOX）。
 *
 * requeue 的动机是握手期 Host 读走但没消费的信封必须原序放回；它一旦重复投递，
 * 文本流会出现重复行、RPC 会收到两次同样的结果。因此这里既验"能放回"，
 * 也验"放回过的同一批不会再放一次"。
 *
 * 每个场景都用**全新沙箱**：requeue 的去重记忆是模块内闭包状态，
 * 共用沙箱会让断言取决于前面的场景跑过什么。
 */
import { createHarness } from '../../lib/harness.mjs';
import { runCase } from '../../lib/tap.mjs';

const textEnvelope = (raw, ts) => ({
  v: 1, type: 'text', sessionToken: '',
  payload: { ts, frame: Math.floor(ts / 16), surface: 'Window_Base.drawTextEx', raw }
});

function fresh() {
  const h = createHarness();
  h.drainAll();
  return h;
}

runCase('envelope', (tap) => {
  // ---- 未知 type ----
  {
    const h = fresh();
    h.inbox({ type: 'no-such-type', payload: { anything: [1, 2, 3] } });
    const after = h.drainAll();
    tap.eq(after.length, 0, 'E-01 未知 type 被忽略：outbox 不新增任何信封', JSON.stringify(after));
    tap.eq(h.state().errors, 0, 'E-02 未知 type 不记 error（不是异常路径）');
    h.inbox({ type: 'ping', payload: { t: 7 } });
    const pong = h.drainAll();
    tap.ok(pong.length === 1 && pong[0].type === 'pong' && pong[0].payload.t === 7,
      'E-03 未知 type 不污染队列：随后一条 ping 恰好得到 1 条 pong', JSON.stringify(pong));
  }

  // ---- 非法入站 ----
  {
    const h = fresh();
    h.inbox('{not json');
    const events = h.drainAll();
    tap.ok(events.length === 1 && events[0].type === 'error' &&
      events[0].payload && events[0].payload.code === 'inbox_error',
      'E-04 非法 JSON 不抛出，转为 1 条 error 信封（code=inbox_error）', JSON.stringify(events));
    h.inbox('null');
    h.inbox(42);
    tap.eq(h.drainAll().length, 0, 'E-05 null / 数字等非对象入站被静默忽略（不产生信封）');
  }

  // ---- drain 上限 ----
  {
    const h = fresh();
    for (let i = 0; i < 120; i++) { h.emit('text', { ts: i, frame: 0, surface: 'e2e', raw: 'r' + i }); }
    const first = h.drain();
    const second = h.drain();
    const third = h.drain();
    const fourth = h.drain();
    tap.eq(first.length, 50, 'E-06 drain() 单次最多 50 条（第 1 批）', 'len=' + first.length);
    tap.eq(second.length, 50, 'E-07 drain() 单次最多 50 条（第 2 批）', 'len=' + second.length);
    tap.eq(third.length, 20, 'E-08 剩余 20 条在第 3 批取出（120 = 50+50+20）', 'len=' + third.length);
    tap.eq(fourth.length, 0, 'E-09 队列空后再 drain 返回空数组');
    tap.eq([first[0].payload.raw, third[19].payload.raw], ['r0', 'r119'],
      'E-10 分片不改变顺序（首条 r0、末条 r119）');
  }

  // ---- requeue：原序放回 ----
  {
    const h = fresh();
    const batch = [textEnvelope('あ', 100), textEnvelope('い', 200), textEnvelope('う', 300)];
    h.emit('text', batch[0].payload);
    h.emit('text', batch[1].payload);
    h.emit('text', batch[2].payload);
    const drained = h.drainAll();
    tap.eq(drained.map((e) => e.payload.raw), ['あ', 'い', 'う'], 'E-11 取出 3 条用于回灌（前置）');

    const report = h.requeue(drained);
    tap.eq(report, { total: 3, accepted: 3, duplicate: 0, dropped: 0 },
      'E-12 requeue 一批新信封：total=3 accepted=3', JSON.stringify(report));
    const restored = h.drainAll();
    tap.eq(restored.map((e) => e.payload.raw), ['あ', 'い', 'う'], 'E-13 回灌后按原序取回，内容逐条一致');

    const replay = h.requeue(drained);
    tap.ok(replay.accepted === 0 && replay.duplicate === 3,
      'E-14 同一批再回灌一次：accepted=0 duplicate=3（不产生重复投递）', JSON.stringify(replay));
    tap.eq(h.drainAll().length, 0, 'E-15 被吸重复的批次不再出现在 outbox');

    // 同一批信封可以连续重放任意多次：去重记忆属于"最近一次真正被接受的批次"，
    // 全重复批次不改写它（否则 accepted → duplicate → accepted 循环，Host 会产生
    // 重复文本行、RPC 会收到两次同样的结果）。
    const third = h.requeue(drained);
    tap.ok(third.accepted === 0 && third.duplicate === 3,
      'E-14b 第三次重放同一批：accepted=0 duplicate=3（去重记忆不被全重复批次清空）',
      JSON.stringify(third));
    tap.eq(h.drainAll().length, 0, 'E-14c 第三次重放同样不产生重复投递');
  }

  // ---- requeue：全畸形批次不得清空去重记忆 ----
  // 无签名的项（如 {}）不算重复、也不算"一次真实投递"。若照常重写签名表，
  // 去重记忆会被清空，下一次重放原批又变成 accepted —— 重复投递。
  {
    const h = fresh();
    const batch = [textEnvelope('あ', 100), textEnvelope('い', 200), textEnvelope('う', 300)];
    tap.eq(h.requeue(batch).accepted, 3, 'E-27 前置：正常批 accepted=3');
    h.drainAll();
    const replay = h.requeue(batch);
    tap.ok(replay.accepted === 0 && replay.duplicate === 3,
      'E-28 前置：重复批 accepted=0 duplicate=3', JSON.stringify(replay));
    const junk = h.requeue([{}, {}]);
    tap.ok(junk.duplicate === 0,
      'E-29 全畸形批不算重复（没有 type 就没有签名）', JSON.stringify(junk));
    const last = h.requeue(batch);
    tap.ok(last.accepted === 0 && last.duplicate === 3,
      'E-30 畸形批之后重放原批仍是 duplicate=3（去重表未被清空）', JSON.stringify(last));
  }

  // ---- requeue：部分重复（独立沙箱，避免上一场景的"全重复批次清空记忆"干扰） ----
  {
    const h = fresh();
    const a = textEnvelope('あ', 100);
    const b = textEnvelope('い', 200);
    tap.eq(h.requeue([a, b]).accepted, 2, 'E-16 前置：先回灌 [あ, い]');
    const partial = h.requeue([a, b, textEnvelope('え', 400)]);
    tap.ok(partial.accepted === 1 && partial.duplicate === 2,
      'E-17 部分重复：accepted=1 duplicate=2（新信封照常放回）', JSON.stringify(partial));
    tap.eq(h.drainAll().map((e) => e.payload.raw), ['え', 'あ', 'い'],
      'E-18 部分重复时只把新信封插到队首（上批被吸掉的两条不重复投递）');
  }

  // ---- requeue：批内去重 ----
  {
    const h = fresh();
    const a = textEnvelope('same', 500);
    const b = textEnvelope('other', 600);
    const report = h.requeue([a, b, a]);
    tap.ok(report.total === 3 && report.accepted === 2 && report.duplicate === 1,
      'E-19 同一批里出现两条相同签名：只收 1 条', JSON.stringify(report));
    tap.eq(h.drainAll().map((e) => e.payload.raw), ['same', 'other'], 'E-20 批内去重保留首次出现的位置');
  }

  // ---- requeue：队首插回 ----
  {
    const h = fresh();
    h.emit('text', { ts: 900, frame: 0, surface: 'e2e', raw: ' новый' });
    const report = h.requeue([textEnvelope('old-1', 700), textEnvelope('old-2', 800)]);
    tap.ok(report.accepted === 2, 'E-21 队列非空时仍接受回灌', JSON.stringify(report));
    tap.eq(h.drainAll().map((e) => e.payload.raw), ['old-1', 'old-2', ' новый'],
      'E-22 回灌插到队首（最旧的信封先出，文本流不倒退）');
  }

  // ---- requeue：非法输入 ----
  {
    const h = fresh();
    h.emit('text', { ts: 1, frame: 0, surface: 'e2e', raw: 'keep' });
    const bad = [h.requeue({ a: 1 }), h.requeue('not json at all'), h.requeue(null)];
    tap.ok(bad.every((report) => report && report.accepted === 0 && report.duplicate === 0),
      'E-23 非数组 / 非 JSON / null 入参：accepted=0 且不抛错', JSON.stringify(bad));
    tap.eq(h.drainAll().map((e) => e.payload.raw), ['keep'],
      'E-24 非法回灌不破坏已有队列');
    const empty = h.requeue([]);
    tap.eq([empty.total, empty.accepted], [0, 0], 'E-25 空数组：total=0 accepted=0', JSON.stringify(empty));
  }

  // ---- 信封字段（协议版本） ----
  {
    const h = fresh();
    h.emit('text', { ts: 42, frame: 2, surface: 'e2e', raw: 'shape' });
    const [envelope] = h.drainAll();
    tap.ok(!!envelope && envelope.v === 1 && envelope.type === 'text' &&
      typeof envelope.sessionToken === 'string' && envelope.payload && envelope.payload.raw === 'shape',
      'E-26 出站信封固定带 v=1/type/sessionToken/payload（Host 只认同一个协议版本）',
      JSON.stringify(envelope));
  }
});
