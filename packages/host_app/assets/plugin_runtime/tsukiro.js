/*
 * Tsukiro 插件运行时（JS 侧）。
 *
 * 由宿主在创建插件 WebView 时**注入**，插件代码运行在它之上。
 * 插件永远不直接碰 Bridge —— 那样每个插件都要自己实现一遍协议，
 * 而且一定有人实现错（漏握手、漏错误分支、id 冲突）。
 *
 * ── 这个文件的 API 形状来自哪里 ──
 *
 * 来自 `plugins/` 下已经写好的那几个插件，而不是我凭空设计。
 * 它们用的是：
 *   tsukiro.lifecycle.on('start'|'stop'|'error', fn)
 *   tsukiro.event.on('permission.change', fn)
 *   tsukiro.log.info({ message, data })
 *   tsukiro.sys.time({ tz })
 *   tsukiro.ui.toast({ text })
 * 工具处理器是 ES module 的 `export default async function`。
 *
 * 已经写下的插件代码就是规格。让运行时去对齐它，
 * 而不是反过来让每个插件作者改代码。
 *
 * 注入时宿主替换两个占位符。**占位符不带引号** ——
 * 宿主用 `jsonEncode` 生成字面量，那个结果自带引号：
 *     var PLUGIN_ID = __PLUGIN_ID__;   →   var PLUGIN_ID = "dev.tsukiro.time";
 *
 * 早先这里写的是 `'__PLUGIN_ID__'`（带引号），于是替换出来变成
 * `'"dev.tsukiro.time"'` —— JS 求值得到的是**带引号字符的字符串**，
 * 握手时身份校验判"冒充"直接终止会话。不带引号就不会有这个问题。
 */
(function () {
  'use strict';

  var PROTOCOL_VERSION = 1;
  var PLUGIN_ID = __PLUGIN_ID__;
  var HOST_API = __HOST_API__;

  // ─────────────────────────── 桥接底层 ───────────────────────────

  var seq = 0;
  function newId(prefix) {
    seq += 1;
    return prefix + '_' + seq.toString(36) + Math.random().toString(36).slice(2, 6);
  }

  /*
   * 发一条消息给宿主。
   *
   * 两条通路：Android 宿主注入的 TsukiroBridge（正式），
   * 或浏览器 postMessage（测试）。
   *
   * 都不存在时**抛异常而不是静默丢弃** —— 静默丢弃会让所有调用
   * 一直等到超时才报错，排查时完全看不出是"根本没发出去"。
   */
  function send(message) {
    var text = JSON.stringify(message);
    if (typeof TsukiroBridge !== 'undefined' &&
        TsukiroBridge &&
        typeof TsukiroBridge.postMessage === 'function') {
      TsukiroBridge.postMessage(text);
      return;
    }
    if (typeof window !== 'undefined' && window.parent && window.parent !== window) {
      window.parent.postMessage(text, '*');
      return;
    }
    throw new Error('没有可用的 Bridge 通道：宿主没有注入 TsukiroBridge');
  }

  var pending = new Map();
  var ready = false;
  var readyWaiters = [];
  var fatalHandlers = [];

  function whenReady() {
    if (ready) return Promise.resolve();
    return new Promise(function (resolve) { readyWaiters.push(resolve); });
  }

  function failAllPending(reason) {
    pending.forEach(function (entry) {
      clearTimeout(entry.timer);
      entry.reject(new Error(reason));
    });
    pending.clear();
  }

  // ─────────────────────────── 调用宿主原语 ───────────────────────────

  /*
   * 调一次宿主原语。
   *
   * method 形如 'sys.time'、'fs.read'。宿主侧会经过权限门禁 ——
   * 插件没声明的权限会被拒。**这不是 bug，是设计。**
   */
  function call(method, params) {
    return whenReady().then(function () {
      return new Promise(function (resolve, reject) {
        var id = newId('r');
        var timer = setTimeout(function () {
          pending.delete(id);
          reject(new Error('调用 ' + method + ' 超时（宿主没有响应）'));
        }, 30000);
        pending.set(id, { resolve: resolve, reject: reject, timer: timer });
        try {
          send({ v: PROTOCOL_VERSION, kind: 'req', id: id, method: method, params: params || {} });
        } catch (e) {
          clearTimeout(timer);
          pending.delete(id);
          reject(e);
        }
      });
    });
  }

  /*
   * 流式调用。
   *
   * onDelta 每收到一段调一次，最后 resolve { result, text }。
   * 用普通的 req —— 宿主可能回若干条 str 分片，最后用 res 收尾。
   * 不发明新的 kind：协议只有 req/res/err/evt/str/inv 六种。
   */
  function stream(method, params, onDelta) {
    return whenReady().then(function () {
      return new Promise(function (resolve, reject) {
        var id = newId('s');
        var acc = '';
        var timer = setTimeout(function () {
          pending.delete(id);
          reject(new Error('流式调用 ' + method + ' 超时'));
        }, 120000);
        pending.set(id, {
          resolve: resolve,
          reject: reject,
          timer: timer,
          isStream: true,
          accumulated: function () { return acc; },
          onDelta: function (delta, done) {
            acc += delta;
            if (typeof onDelta === 'function') onDelta(delta, done);
          },
        });
        try {
          send({ v: PROTOCOL_VERSION, kind: 'req', id: id, method: method, params: params || {} });
        } catch (e) {
          clearTimeout(timer);
          pending.delete(id);
          reject(e);
        }
      });
    });
  }

  // ─────────────────────────── 插件声明面 ───────────────────────────

  var toolDefs = new Map();       // name -> spec（程序式定义的工具）
  var toolHandlers = new Map();   // name -> handler（由 manifest 的 handler 文件注册）
  var hookHandlers = new Map();   // phase -> [handler]
  var slotRenderers = new Map();  // slot -> render
  var eventHandlers = new Map();  // 事件名 -> [handler]
  var lifecycleHandlers = new Map(); // 'start'|'stop'|'error' -> [handler]

  function on(map, key, fn) {
    if (typeof fn !== 'function') throw new Error('回调必须是函数');
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(fn);
  }

  /*
   * 生命周期。
   *
   * 用 `on(phase, fn)` 而不是 `{start, stop}` 对象：
   * 插件可以在不同文件里各注册一段（比如 index.js 注册 start，
   * 某个功能模块注册自己的 stop），对象形式做不到。
   */
  var lifecycle = {
    on: function (phase, fn) { on(lifecycleHandlers, phase, fn); },
  };

  var events = {
    on: function (name, fn) { on(eventHandlers, name, fn); },

    /**
     * 插件内部发一个事件。
     *
     * 工具处理器（handlers/xxx.js）和入口（index.js）是两个模块，
     * 以前它们之间没有任何通道 —— 处理器改完了数据，却没法让
     * 入口去刷新界面。
     *
     * **只在插件自己的运行时里跑**：不跨宿主、不跨别的插件。
     * 跨边界必须走原语（那才过门禁和审计）。
     */
    emit: function (name, payload) {
      try {
        dispatchEvent(String(name), payload || {});
        return true;
      } catch (e) {
        return false;
      }
    },
  };

  function defineTool(spec) {
    if (!spec || typeof spec.name !== 'string' || !spec.name) {
      throw new Error('defineTool 需要 name');
    }
    if (typeof spec.handler !== 'function') {
      throw new Error('defineTool(' + spec.name + ') 需要 handler 函数');
    }
    toolDefs.set(spec.name, spec);
  }

  // manifest 里声明的 handler 文件由宿主加载后调这个注册
  function registerHandler(toolName, fn) {
    if (typeof fn !== 'function') {
      throw new Error('registerHandler(' + toolName + ') 拿到的不是函数');
    }
    toolHandlers.set(toolName, fn);
  }

  function defineHook(phase, fn) { on(hookHandlers, phase, fn); }

  function defineSlot(slot, render) {
    if (typeof render !== 'function') throw new Error('defineSlot 需要渲染函数');
    slotRenderers.set(slot, render);
  }

  // ─────────────────────────── 日志 ───────────────────────────

  /*
   * 五个级别，都接受 `{ message, data }`。
   *
   * 接受对象而不是裸字符串：插件想带结构化数据时不用自己 JSON.stringify，
   * 宿主也能把 data 直接显示成可折叠的树。
   */
  function logAt(level) {
    return function (payload) {
      var message = '';
      var data = null;
      if (typeof payload === 'string') {
        message = payload;
      } else if (payload && typeof payload === 'object') {
        message = payload.message != null ? String(payload.message) : '';
        data = payload.data != null ? payload.data : null;
      }
      try {
        send({
          v: PROTOCOL_VERSION,
          kind: 'evt',
          method: 'plugin.log',
          params: { level: level, message: message, data: data },
        });
      } catch (ignored) { /* 握手前发不出去，忽略 */ }
      var consoleFn = console[level] || console.log;
      consoleFn.call(console, '[plugin:' + PLUGIN_ID + '] ' + message, data || '');
    };
  }

  var log = {
    debug: logAt('debug'),
    info: logAt('info'),
    warn: logAt('warn'),
    error: logAt('error'),
  };

  // ─────────────────────────── 收到宿主消息 ───────────────────────────

  function handle(raw) {
    var msg;
    try {
      msg = typeof raw === 'string' ? JSON.parse(raw) : raw;
    } catch (e) {
      console.error('[tsukiro] 收到解不开的消息', e);
      return;
    }
    if (!msg || typeof msg !== 'object') return;

    switch (msg.kind) {
      case 'evt': handleEvent(msg); break;
      case 'inv': handleInvoke(msg); break;
      case 'res': resolveCall(msg); break;
      case 'err': rejectCall(msg); break;
      case 'str': handleStreamChunk(msg); break;
      default: break; // 未知类型静默忽略，宿主加新类型不需要同步升级插件
    }
  }

  function handleEvent(msg) {
    switch (msg.method) {
      case 'bridge.ready':
        ready = true;
        if (msg.params && msg.params.primitives) installPrimitives(msg.params.primitives);
        var waiters = readyWaiters;
        readyWaiters = [];
        waiters.forEach(function (w) { w(); });
        // 握手完成后才跑 start —— 插件在 start 里通常会调原语，
        // 提前跑会因为"会话未就绪"全部失败
        runLifecycle('start', msg.params || {});
        break;

      case 'bridge.fatal':
        ready = false;
        failAllPending('Bridge 会话被宿主终止：' + ((msg.params && msg.params.message) || ''));
        runLifecycle('error', msg.params || {});
        fatalHandlers.forEach(function (fn) {
          try { fn(msg.params || {}); } catch (ignored) { /* 忽略 */ }
        });
        break;

      case 'plugin.error':
        // 宿主回报插件自己抛的错（比如 start 里挂了）
        dispatchEvent('plugin.error', msg.params || {});
        break;

      default:
        // 透传给插件注册的事件处理器
        dispatchEvent(msg.method, msg.params || {});
        break;
    }
  }

  function dispatchEvent(name, payload) {
    var list = eventHandlers.get(name) || [];
    list.forEach(function (fn) {
      Promise.resolve()
        .then(function () { return fn(payload); })
        .catch(function (e) {
          // 事件处理器出错不能影响别人 —— 一个插件的通知回调崩了，
          // 不该让它的主功能也停摆
          log.error({ message: '事件处理器 ' + name + ' 出错：' + errorText(e) });
        });
    });
    // permission.change 走生命周期那条路的兼容名
    if (name === 'permission.change') {
      var lc = lifecycleHandlers.get('permissionChange') || [];
      lc.forEach(function (fn) { Promise.resolve().then(function () { return fn(payload); }); });
    }
  }

  function runLifecycle(phase, payload) {
    var list = lifecycleHandlers.get(phase) || [];
    list.forEach(function (fn) {
      Promise.resolve()
        .then(function () { return fn(payload); })
        .catch(function (e) { reportError('lifecycle.' + phase, e); });
    });
  }

  /*
   * 宿主反向调用插件（工具执行、生命周期收尾）。
   *
   * **错误必须转成 err 消息发回去，不能让异常逃逸** ——
   * 逃逸出去这个 Promise 就没人接了，宿主会一直等到超时，
   * 而插件作者看到的是"我的工具明明抛了个明确的错，宿主却报超时"。
   */
  function handleInvoke(msg) {
    var id = msg.id;
    var method = msg.method;
    var params = msg.params || {};

    var task;
    if (method === 'tool.invoke') {
      task = invokeTool(params);
    } else if (method === 'lifecycle.stop') {
      task = Promise.resolve()
        .then(function () { return runLifecycleAsync('stop', params); })
        .then(function () { return { ok: true }; });
    } else if (method.indexOf('hook.') === 0) {
      task = invokeHook(method.slice('hook.'.length), params);
    } else if (method.indexOf('slot.') === 0) {
      task = renderSlot(method.slice('slot.'.length), params);
    } else {
      task = Promise.reject(new Error('插件不认识这个调用：' + method));
    }

    Promise.resolve(task).then(
      function (result) {
        send({
          v: PROTOCOL_VERSION,
          kind: 'res',
          id: id,
          result: result === undefined ? null : result,
        });
      },
      function (e) {
        send({
          v: PROTOCOL_VERSION,
          kind: 'err',
          id: id,
          error: { code: 'PLUGIN_ERROR', message: errorText(e) },
        });
      }
    );
  }

  function runLifecycleAsync(phase, payload) {
    var list = lifecycleHandlers.get(phase) || [];
    var chain = Promise.resolve();
    list.forEach(function (fn) {
      chain = chain.then(function () { return fn(payload); });
    });
    return chain;
  }

  function invokeTool(params) {
    var name = params.name || params.tool;
    var args = params.args || params.arguments || {};

    var handler = toolHandlers.get(name);
    if (!handler) {
      var def = toolDefs.get(name);
      handler = def && def.handler;
    }
    if (!handler) {
      return Promise.reject(new Error('插件没有定义工具 ' + name));
    }

    return Promise.resolve(handler(args, { pluginId: PLUGIN_ID, toolName: name })).then(
      function (r) {
        // 允许 handler 直接返回字符串（最常见），也允许返回 {ok, ...}
        if (typeof r === 'string') return { ok: true, content: r };
        return r === undefined ? { ok: true } : r;
      }
    );
  }

  function invokeHook(phase, params) {
    var list = hookHandlers.get(phase) || [];
    if (list.length === 0) return Promise.resolve(null);
    var context = params.context || {};
    var chain = Promise.resolve(context);
    list.forEach(function (fn) {
      chain = chain.then(function (ctx) {
        return Promise.resolve(fn(ctx, { phase: phase })).then(function (r) {
          return r === undefined ? ctx : r;
        });
      });
    });
    return chain;
  }

  function renderSlot(slot, params) {
    var render = slotRenderers.get(slot);
    if (!render) return Promise.resolve(null);
    return Promise.resolve(render(params.context || {})).then(normalizeRender);
  }

  /*
   * 渲染结果归一化。
   *
   * 插件可能返回：DOM 节点、HTML 字符串、{html, height}、纯文本。
   * 宿主只认 `{ html, height }`，所以在这里统一 ——
   * 在宿主侧做的话就要处理一堆 DOM 相关的分支，而那些只在这里才有意义。
   */
  function normalizeRender(result) {
    if (result == null) return null;
    if (typeof result === 'string') return { html: result };
    if (typeof result === 'object' && result.nodeType === 1) {
      return { html: result.outerHTML };
    }
    if (typeof result === 'object') {
      return {
        html: result.html != null ? String(result.html) : '',
        height: typeof result.height === 'number' ? result.height : null,
      };
    }
    return { html: String(result) };
  }

  function resolveCall(msg) {
    var entry = pending.get(msg.id);
    if (!entry) return;
    clearTimeout(entry.timer);
    pending.delete(msg.id);
    if (entry.isStream) {
      entry.resolve({ result: msg.result, text: entry.accumulated() });
    } else {
      entry.resolve(msg.result);
    }
  }

  function rejectCall(msg) {
    var entry = pending.get(msg.id);
    if (!entry) return;
    clearTimeout(entry.timer);
    pending.delete(msg.id);
    var err = msg.error || {};
    var e = new Error(err.message || '调用失败');
    e.code = err.code || 'UNKNOWN';
    entry.reject(e);
  }

  function handleStreamChunk(msg) {
    var entry = pending.get(msg.id);
    if (!entry || !entry.onDelta) return;
    entry.onDelta(msg.delta || '', !!msg.done);
    if (msg.done) {
      clearTimeout(entry.timer);
      pending.delete(msg.id);
      entry.resolve({ result: null, text: entry.accumulated() });
    }
  }

  function reportError(where, e) {
    log.error({ message: where + ' 失败：' + errorText(e), data: e && e.stack ? { stack: String(e.stack) } : null });
  }

  function errorText(e) {
    if (e == null) return '未知错误';
    if (typeof e === 'string') return e;
    if (e.message) return String(e.message);
    try { return JSON.stringify(e); } catch (ignored) { return String(e); }
  }

  // ─────────────────────────── 原语命名空间 ───────────────────────────

  /*
   * 把 `sys.time` 铺成 `tsukiro.sys.time()`。
   *
   * 按宿主发来的**可用原语列表**动态建，而不是预先写死所有域名：
   * 只挂有权限的那些，插件作者写 `tsukiro.fs.read` 时如果这个方法不存在，
   * 会立刻发现"我没声明 fs.read 权限"；如果存在但调用报错，
   * 他要等到运行时才看得出来。
   */
  function installPrimitives(list) {
    if (!Array.isArray(list)) return;
    list.forEach(function (name) {
      var parts = String(name).split('.');
      if (parts.length < 2) return;
      var target = tsukiro;
      for (var i = 0; i < parts.length - 1; i++) {
        var part = parts[i];
        if (!target[part] || typeof target[part] !== 'object') target[part] = {};
        target = target[part];
      }
      var action = parts[parts.length - 1];
      if (typeof target[action] === 'function') return;
      target[action] = function (params) { return call(name, params); };
    });
  }

  // ─────────────────────────── 导出给插件 ───────────────────────────

  var tsukiro = {
    pluginId: PLUGIN_ID,
    hostApi: HOST_API,
    protocolVersion: PROTOCOL_VERSION,

    lifecycle: lifecycle,
    event: events,
    log: log,

    defineTool: defineTool,
    defineHook: defineHook,
    defineSlot: defineSlot,
    onFatal: function (fn) { fatalHandlers.push(fn); },

    call: call,
    stream: stream,
    ready: whenReady,
    isReady: function () { return ready; },

    // 内部：宿主加载 handler 文件后调它
    __registerHandler: registerHandler,
    __installPrimitives: installPrimitives,
    __registered: function () {
      return {
        tools: Array.from(toolHandlers.keys()).concat(Array.from(toolDefs.keys())),
        hooks: Array.from(hookHandlers.keys()),
        slots: Array.from(slotRenderers.keys()),
        events: Array.from(eventHandlers.keys()),
      };
    },
  };

  if (typeof window !== 'undefined') {
    window.tsukiro = tsukiro;
    window.__tsukiro_receive = handle;

    // 浏览器测试环境（没有 Android 的 TsukiroBridge 时）
    if (typeof TsukiroBridge === 'undefined') {
      window.addEventListener('message', function (event) {
        if (typeof event.data === 'string') handle(event.data);
      });
    }
  }

  // ─────────────────────────── 握手 ───────────────────────────

  function hello() {
    send({
      v: PROTOCOL_VERSION,
      kind: 'evt',
      method: 'bridge.hello',
      params: { pluginId: PLUGIN_ID, hostApi: HOST_API, v: PROTOCOL_VERSION },
    });
  }

  try {
    hello();
  } catch (e) {
    // 宿主还没注入通道 —— 脚本可能先于注入执行。稍后重试一次。
    setTimeout(function () {
      try {
        hello();
      } catch (ignored) {
        console.error('[tsukiro] 无法与宿主握手：', ignored);
      }
    }, 50);
  }
})();
