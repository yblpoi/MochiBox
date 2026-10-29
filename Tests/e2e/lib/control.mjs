/*
 * control.mjs —— --control <unix socket> 的客户端（NDJSON，一行一请求一行一响应）。
 *
 * 对端实现：Sources/Adapters/Control/ControlServer.swift。协议只有五个 op：
 *   ping / eval / state / close / quit
 * 这里**不**替调用方兜底业务语义：ok=false 原样作为 ControlReply 返回，
 * 只有"连不上 / 等不到应答 / 连接断了"才抛 ControlError —— 那三种是驱动层故障，
 * 与"页面里的 JS 抛异常（ok=false, error=js_error）"必须分开。
 *
 * 命名约定（容易混，先看清楚）：
 *   · closeWindow() → 产品的 close op（模拟用户关窗）；
 *   · close()       → 客户端收尾（断开本地 socket），不向被测进程发任何东西。
 *
 * 只用 node 内置 net。没有重连：一个 ControlClient 对应一个进程生命周期，
 * 进程没了就该失败，悄悄重连会让用例拿着上一轮会话的应答继续断言。
 */

import net from 'node:net';

export class ControlError extends Error {
  constructor(code, message, detail) {
    super(message);
    this.name = 'ControlError';
    this.code = code;
    this.detail = detail;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export class ControlClient {
  /**
   * @param {string} socketPath unix socket 路径（与 --control 参数逐字一致）
   * @param {{connectTimeoutMs?: number, responseTimeoutMs?: number}} options
   */
  constructor(socketPath, options = {}) {
    this.socketPath = socketPath;
    this.connectTimeoutMs = options.connectTimeoutMs ?? 20_000;
    this.responseTimeoutMs = options.responseTimeoutMs ?? 15_000;
    this.socket = null;
    this.connected = false;
    this.closed = false;
    this.buffer = '';
    this.nextId = 0;
    this.pending = new Map();
    this.quitSent = false;
  }

  /** 幂等：已连上直接返回。等 socket 文件出现 + 能连上，两者共用同一个 deadline。 */
  async connect() {
    if (this.connected) { return this; }
    const deadline = Date.now() + this.connectTimeoutMs;
    let lastError = null;
    while (Date.now() < deadline) {
      try {
        const socket = await this.#connectOnce();
        this.socket = socket;
        this.connected = true;
        this.#wire(socket);
        return this;
      } catch (error) {
        lastError = error;
        await sleep(50);
      }
    }
    throw new ControlError('connect_failed',
      '连不上控制通道 ' + this.socketPath + '（' + (lastError ? lastError.message : 'timeout') + '）');
  }

  #connectOnce() {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(this.socketPath);
      socket.setEncoding('utf8');
      const onError = (error) => {
        socket.destroy();
        reject(error);
      };
      socket.once('error', onError);
      socket.once('connect', () => {
        socket.removeListener('error', onError);
        resolve(socket);
      });
    });
  }

  #wire(socket) {
    socket.on('data', (chunk) => {
      this.buffer += chunk;
      let index;
      while ((index = this.buffer.indexOf('\n')) >= 0) {
        const line = this.buffer.slice(0, index).trim();
        this.buffer = this.buffer.slice(index + 1);
        if (!line) { continue; }
        let reply;
        try {
          reply = JSON.parse(line);
        } catch (error) {
          this.#rejectAll(new ControlError('bad_frame', '控制通道返回了非 JSON 行：' + line.slice(0, 120)));
          continue;
        }
        const waiter = this.pending.get(reply.id);
        if (waiter) {
          this.pending.delete(reply.id);
          clearTimeout(waiter.timer);
          waiter.resolve(reply);
        }
        // 没有 waiter 的应答（例如 quit 之后进程自己收尾）直接丢弃：
        // 协议里没有服务端主动推送，配对只能靠 id。
      }
    });
    socket.on('error', (error) => {
      if (this.quitSent) { return; }
      this.#rejectAll(new ControlError('channel_error', '控制通道错误：' + error.message));
    });
    socket.on('close', () => {
      this.connected = false;
      if (this.quitSent) { return; }
      this.#rejectAll(new ControlError('channel_closed', '控制通道已断开（被测进程可能已退出）'));
    });
  }

  #rejectAll(error) {
    for (const [, waiter] of this.pending) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.pending.clear();
  }

  /**
   * 发一条请求并等**同 id** 的应答。
   * @param {string} op ping|eval|state|close|quit
   * @param {object} extra 附加字段（eval 用 expression / timeoutSec）
   * @param {{timeoutMs?: number}} options
   * @returns {Promise<object>} 原始应答对象（含 ok/error/message）
   */
  async call(op, extra = {}, options = {}) {
    await this.connect();
    const id = ++this.nextId;
    const payload = Object.assign({ id, op }, extra);
    const timeoutMs = options.timeoutMs ?? this.responseTimeoutMs;
    if (op === 'quit') { this.quitSent = true; }

    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new ControlError('response_timeout', 'op=' + op + ' 在 ' + timeoutMs + 'ms 内没有应答'));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.socket.write(JSON.stringify(payload) + '\n');
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new ControlError('write_failed', '写控制通道失败：' + error.message));
      }
    });
  }

  /** 期望 ok=true 的便捷入口；ok=false 时抛带 code 的 ControlError。 */
  async expectOk(op, extra = {}, options = {}) {
    const reply = await this.call(op, extra, options);
    if (!reply || reply.ok !== true) {
      throw new ControlError(reply && reply.error ? reply.error : 'not_ok',
        (reply && reply.message) || ('op=' + op + ' 返回 ok=false'), reply);
    }
    return reply;
  }

  /**
   * 求值并返回字符串值。
   *
   * 注意 value 是 ControlServer 的文本化结果：数字 → "2"、布尔 → "true"、
   * 对象/数组 → JSON 文本。调用方要结构化数据就自己 JSON.parse。
   */
  async eval(expression, options = {}) {
    const reply = await this.expectOk('eval', {
      expression,
      ...(options.timeoutSec ? { timeoutSec: options.timeoutSec } : {})
    }, options);
    return reply.value === undefined ? null : reply.value;
  }

  ping() { return this.expectOk('ping'); }
  state() { return this.expectOk('state'); }
  /** 产品 op close：模拟用户关窗（不是断开本地 socket）。 */
  closeWindow() { return this.expectOk('close'); }
  quit() { return this.expectOk('quit'); }

  /** 客户端收尾：断开本地 socket。不向被测进程发任何东西（幂等）。 */
  close() {
    this.quitSent = true;
    this.connected = false;
    if (this.socket) {
      this.socket.removeAllListeners();
      this.socket.destroy();
      this.socket = null;
    }
    this.#rejectAll(new ControlError('client_closed', 'ControlClient 已关闭'));
  }

  /** 兼容别名。 */
  destroy() { this.close(); }
}
