import wx from 'wx';

/**
 * 眼镜镜腿交互工具（AIUI / Rokid Glasses / JSAR）
 *
 * 按键接入依据（实测 + 官方文档交叉验证）：
 *   - AIUI 官方文档 page-events.md：页面在 export default 中定义 onKeyDown / onKeyUp
 *     接收设备按键，event.code 为标准键码：
 *       * 'GlobalHook' ：镜腿触摸（设备特有）
 *       * 'ArrowUp' / 'ArrowDown' ：方向（文档仅列上下，左右由浏览器标准 ArrowLeft/ArrowRight 上报）
 *       * 'Backspace' ：返回类操作
 *       * 'Enter'     ：确认 / 激活
 *   - Rokid 真机经验（rokid-aiui-lab）：镜腿【单击】常上报为 'Enter'，
 *     镜腿【双击】常上报为 'Backspace'（设备层已区分好，未必需要自己算时间差）。
 *
 * parseKeyEvent 将按键统一解析为：
 *   { type: 'tap',    raw }            单击（进入/执行）
 *   { type: 'swipe',  direction, raw } 滑动（left/right/up/down）
 *   { type: 'back',   raw }            返回/双击（退出）
 *   null                               event 为空
 * 任何无法识别的 code 一律兜底为一次 tap，确保“进得去功能”，
 * 同时原始 code 通过 __keyLog 回显，便于真机校准。
 */

/**
 * 解析镜腿按键事件。
 * @param {Object} event 按键事件对象（onKeyUp / onKeyDown 入参，或 window KeyboardEvent）
 * @returns {{ type: 'tap'|'swipe'|'back', direction?: string, raw: string } | null}
 */
export function parseKeyEvent(event) {
  if (!event) return null;
  const code = (event.code || event.key || '').toString();
  const keyCode = typeof event.keyCode === 'number' ? event.keyCode : 0;
  const lower = code.toLowerCase();
  const rawLabel = code || ('kc' + keyCode);

  // Rokid 镜腿手势在系统层被转换成 Android 标准按键（见 Rokid 交互文档）：
  //   单击=KEYCODE_ENTER(66)  双击=key 202  上滑=DPAD_UP(19) 下滑=DPAD_DOWN(20)
  //   左滑=DPAD_LEFT(21) 右滑=DPAD_RIGHT(22) 前滑=key 183 后滑=key 184
  // AIUI/JSAR 运行时可能映射为标准 code 字符串（Enter/ArrowLeft…），也可能直接透传数值 keyCode。两者都兼容。

  // 返回 / 双击 / 退出：Studio 仿真面板与真机的“返回系”键表达差异很大，这里统一兜住。
  //   - Rokid 真机镜腿双击 → keyCode 202（部分固件直接映射 Backspace）
  //   - Rokid AIUI Studio 仿真面板的「返回后退 / 双击后退 / 退出」按钮
  //     → 多下发 KEYCODE_BACK，字符串形如 'KEYCODE_BACK' / 'Back' / 'back'，
  //     或直接透传数值 keyCode 4（Android KEYCODE_BACK）/ 27（Escape）/ 3（HOME→退出到主页）
  //   — 之前只认 Backspace/202，导致 'KEYCODE_BACK' 落到兜底逻辑被当成一次 tap（进得去退不出）。
  const backKeywords = ['back', 'escape', 'home'];
  if (
    code === 'Backspace' ||
    keyCode === 8 ||
    keyCode === 202 ||
    keyCode === 4 ||
    keyCode === 27 ||
    keyCode === 3
  ) {
    return { type: 'back', raw: rawLabel };
  }
  for (const kw of backKeywords) {
    if (lower.indexOf(kw) !== -1) return { type: 'back', raw: rawLabel };
  }

  // 滑动方向：先按字符串关键字（Enter/ArrowLeft/SwipeLeft 等任意上报形式）
  const dirKeywords = { left: 'left', right: 'right', up: 'up', down: 'down' };
  for (const kw in dirKeywords) {
    if (lower.indexOf(kw) !== -1) return { type: 'swipe', direction: dirKeywords[kw], raw: rawLabel };
  }
  // 再按 Android 数值方向码
  const dirByCode = { 19: 'up', 20: 'down', 21: 'left', 22: 'right', 183: 'left', 184: 'right' };
  if (dirByCode[keyCode]) return { type: 'swipe', direction: dirByCode[keyCode], raw: rawLabel };

  // 单击（确认）：GlobalHook / Enter / Space / Tap / NumpadEnter / Android ENTER(66) /
  //   Studio 仿真「单击」按钮 KEYCODE_DPAD_CENTER(23)
  if (
    code === 'GlobalHook' ||
    code === 'Enter' ||
    code === 'NumpadEnter' ||
    code === 'Space' ||
    code === 'Spacebar' ||
    code === 'Tap' ||
    code === 'Center' ||
    keyCode === 13 ||
    keyCode === 32 ||
    keyCode === 66 ||
    keyCode === 23
  ) {
    return { type: 'tap', raw: rawLabel };
  }

  // 兜底：未识别的按键一律当作一次单击（保证进得去），原始码交给 __keyLog 暴露
  return { type: 'tap', raw: rawLabel };
}

/** 调试回显：把真实收到的键码用 toast 短暂显示在眼镜屏幕上（无需 schema 字段，不破坏编译），
 *  同时输出到控制台便于工作台 DevTools 查看。验证手势稳定后可简化/移除。 */
function logRaw(ctx, raw, parsed) {
  const label = (raw || '?') + ':' + (parsed || '');
  try {
    if (typeof wx !== 'undefined' && wx.showToast) {
      wx.showToast({ title: label, icon: 'none', duration: 800 });
    }
  } catch (e) {}
  try { console.log('[gesture] ' + label); } catch (e) {}
  // 把收到的原始鍵碼顯示在螢幕上，便於在無控制台的設備/仿真器上直接讀取，
  // 確認「返回」手勢到底上報了什麼 code（用來精確修復返回識別）。
  // 仅当页面 data 中声明了 debugKey（当前仅 conversation 页绑定了显示元素），
  // 否则框架会刷 “has no bindings” 警告；此处跳过以净化日志。
  try {
    if (ctx && typeof ctx.setData === 'function' && ctx.data && ctx.data.hasOwnProperty && ctx.data.hasOwnProperty('debugKey')) {
      ctx.setData({ debugKey: label });
    }
  } catch (e) {}
}

/**
 * 双击判定阈值（毫秒）。
 * AIUI 无原生双击事件；若设备不上报双击码（如两次 GlobalHook/Enter），用两次短按间隔识别。
 */
export const DOUBLE_TAP_MS = 500;

/**
 * 单击去抖阈值（毫秒）。
 * 部分真机会把「一次物理按压」上报成多次 keyup，间隔小于此值视为重复上报忽略。
 */
export const TAP_DEBOUNCE_MS = 150;

/**
 * 统一判定一次 tap 的性质，处理「设备重复上报」与「双击」两种情况。
 * @returns {'single'|'double'|'ignore'}
 */
export function classifyTap(ctx) {
  const now = Date.now();
  if (ctx._lastTapRaw && now - ctx._lastTapRaw < TAP_DEBOUNCE_MS) {
    return 'ignore';
  }
  ctx._lastTapRaw = now;

  const last = ctx._lastTapTime || 0;
  if (last && now - last < DOUBLE_TAP_MS) {
    ctx._lastTapTime = 0;
    return 'double';
  }
  ctx._lastTapTime = now;
  return 'single';
}

/** 兼容旧调用：返回布尔值（是否为双击）。 */
export function isDoubleTap(ctx) {
  return classifyTap(ctx) === 'double';
}

/**
 * 统一的按键路由：在页面 onKeyDown / onKeyUp 中调用本函数即可。
 * @param {Object} ctx    页面实例（this），需已实现 handleTap / handleSwipe，可选 handleDoubleTap / handleBack
 * @param {Object} event  按键事件对象
 * @param {'down'|'up'} phase 当前是按下还是抬起
 */
export function routeKeyEvent(ctx, event, phase) {
  if (!event) return;
  // 去重：同一物理事件可能被多通道投递（页面 onKeyDown + window 兜底 + global 桥接），
  // 80ms 内相同 (code,keyCode,phase) 视为一次，避免重复触发。
  const now = Date.now();
  const sig = (event.code || '') + '|' + (event.keyCode || 0) + '|' + (phase || '');
  if (ctx._lastSeenSig === sig && now - (ctx._lastSeenAt || 0) < 80) return;
  ctx._lastSeenSig = sig;
  ctx._lastSeenAt = now;

  // 尽早拦截宿主默认行为（系统拍照 / 滚动 / 返回）。
  // AIUI 文档：Enter 在 onKeyUp 默认“激活当前目标”、Arrow 默认滚动、Backspace 默认返回，
  // 必须在事件回调里 preventDefault 才能由页面接管——否则系统会打开相机/扫码等默认 Agent。
  if (event.preventDefault) event.preventDefault();

  const action = parseKeyEvent(event);
  // 任何到达的事件都先回显原始 code，便于真机校准（即使解析为 null 也记录）
  logRaw(ctx, (event.code || event.key || ''), action ? action.type + (action.direction || '') : 'null');
  if (!action) return;

  // 返回 / 双击：优先交由 handleDoubleTap（双击=退出）。
  // 页面若定义了 handleBack（如需先停聆听再退出）则回落到它。
  if (action.type === 'back') {
    if (ctx.handleDoubleTap) { ctx.handleDoubleTap(); return; }
    if (ctx.handleBack) { ctx.handleBack(); return; }
    return;
  }

  if (action.type === 'swipe') {
    const code = (event.code || event.key || '').toString();
    const now = Date.now();
    if (ctx._lastSwipeKey === code && now - (ctx._lastSwipeTime || 0) < 250) return;
    ctx._lastSwipeKey = code;
    ctx._lastSwipeTime = now;
    if (ctx.handleSwipe) ctx.handleSwipe(action.direction);
  } else if (action.type === 'tap') {
    routeTap(ctx, phase);
  }
}

/**
 * 一次物理按压的 tap 路由：保证 keydown/keyup 只触发一次。
 *  - 真机：keydown 触发，keyup（与本次按下配对）跳过；
 *  - 仿真只发 keydown：每次 keydown 都触发（classifyTap 负责去抖/双击）；
 *  - 仿真只发 keyup：无配对 keydown，keyup 直接触发。
 */
function routeTap(ctx, phase) {
  if (phase === 'down') {
    ctx._tapDownPending = true;
    ctx._tapDownAt = Date.now();
    fireTap(ctx);
  } else {
    if (ctx._tapDownPending) {
      ctx._tapDownPending = false;
      ctx._tapDownAt = 0;
      return;
    }
    ctx._tapDownPending = false;
    fireTap(ctx);
  }
}

/** 用 classifyTap 判定单击/双击/去抖后再分发，确保一次物理按压只触发一次。 */
function fireTap(ctx) {
  const kind = classifyTap(ctx);
  if (kind === 'ignore') return;
  if (kind === 'double') {
    if (ctx.handleDoubleTap) ctx.handleDoubleTap();
  } else {
    if (ctx.handleTap) ctx.handleTap();
  }
}

/**
 * 全局键盘兜底监听（应急通道）。
 * 背景：部分运行时把真实键盘 / 设备按键作为 window 级 keydown/keyup 下发，
 * 但不自动路由到页面 onKeyDown/onKeyUp，导致手势无反应。
 * 本函数在 window 上挂监听兜底，只要事件到达 JS 环境就能触发。
 *
 * 安全约束：
 *  - 运行时非浏览器（无 window）时自动禁用；
 *  - 与框架原生 onKeyDown 共存：若 2 秒内框架已派发过 onKeyDown，兜底让路避免双触发；
 *  - 通过 install/uninstall 配合页面 onShow/onHide，保证同一时刻只有前台页面监听 window。
 */
let _activeFallbackCtx = null;

export function installKeyboardFallback(ctx) {
  if (typeof window === 'undefined' || !ctx) return;
  if (_activeFallbackCtx && _activeFallbackCtx !== ctx) {
    removeKeyboardFallback(_activeFallbackCtx);
  }
  if (ctx._removeKeyboardFallback) return;

  const down = (e) => {
    if (e.repeat) return;
    if (ctx._lastFrameworkKey && Date.now() - (ctx._lastFrameworkKey || 0) < 2000) return;
    routeKeyEvent(ctx, e, 'down');
  };
  const up = (e) => {
    if (ctx._lastFrameworkKey && Date.now() - (ctx._lastFrameworkKey || 0) < 2000) return;
    routeKeyEvent(ctx, e, 'up');
  };
  // 该运行时 window 存在但 addEventListener 未必是函数（真机 ink-scripting 即如此），
  // 必须判可用再挂载，否则 installKeyboardFallback 抛错会中断 onShow/onLoad，连 global 桥接都挂不上。
  const winOk = (typeof window !== 'undefined' && window && typeof window.addEventListener === 'function');
  if (winOk) {
    window.addEventListener('keydown', down);
    window.addEventListener('keyup', up);
  }

  // 额外桥接 global.onKeyDown / global.onKeyUp：
  // Rokid AIUI Studio 部分版本把仿真面板的按键投到 global 级处理器，而非页面 onKeyDown，
  // 若只依赖页面方法会“毫无反应”。这里把 global 通道也转发给当前页面（去重保证不重复）。
  let globalDown = null;
  let globalUp = null;
  let globalDownSet = null; // 实际挂到 global.onKeyDown 的引用，供卸载还原
  let globalUpSet = null;
  if (typeof global !== 'undefined' && global) {
    globalDown = (e) => routeKeyEvent(ctx, e, 'down');
    globalUp = (e) => routeKeyEvent(ctx, e, 'up');
    // 真机运行时往往已自带 global.onKeyDown/onKeyUp（系统默认处理器）。
    // 不能“已是函数就跳过”——否则返回键被系统层吞掉、页面收不到，表现就是“返回无效”。
    // 改为“包裹”：先调原始处理器，再转发给本页面路由（routeKeyEvent 内部去重，不会重复触发）。
    if (typeof global.onKeyDown === 'function') {
      const orig = global.onKeyDown;
      global.onKeyDown = (e) => { try { orig(e); } catch (_) {} globalDown(e); };
    } else {
      global.onKeyDown = globalDown;
    }
    globalDownSet = global.onKeyDown;
    if (typeof global.onKeyUp === 'function') {
      const orig = global.onKeyUp;
      global.onKeyUp = (e) => { try { orig(e); } catch (_) {} globalUp(e); };
    } else {
      global.onKeyUp = globalUp;
    }
    globalUpSet = global.onKeyUp;
  }

  ctx._removeKeyboardFallback = () => {
    if (winOk) {
      window.removeEventListener('keydown', down);
      window.removeEventListener('keyup', up);
    }
    if (globalDownSet && typeof global !== 'undefined' && global && global.onKeyDown === globalDownSet) {
      global.onKeyDown = null;
    }
    if (globalUpSet && typeof global !== 'undefined' && global && global.onKeyUp === globalUpSet) {
      global.onKeyUp = null;
    }
    ctx._removeKeyboardFallback = null;
  };
  _activeFallbackCtx = ctx;
}

export function removeKeyboardFallback(ctx) {
  if (ctx && ctx._removeKeyboardFallback) {
    ctx._removeKeyboardFallback();
  }
  if (_activeFallbackCtx === ctx) _activeFallbackCtx = null;
}

/**
 * 稳健的「返回 / 退出到主页」：仿真与真机通用。
 *
 * 背景：原代码一律直接 wx.navigateBack()，但在两种情况下会“毫无反应”：
 *   1) 主页（index）本身就在栈底，没有上一页，navigateBack 静默失败；
 *   2) 仿真单页预览 / 部分运行时没有维护页面栈，navigateBack 同样失败。
 * 本函数优先 navigateBack（有栈时保留上一页状态），
 * 无栈时兜底 reLaunch（再不行 redirectTo）到主页，保证“退出/返回”一定有反馈。
 *
 * @param {string} [fallbackUrl] 无栈时的兜底地址，默认主页
 */
export function safeBack(fallbackUrl) {
  const url = fallbackUrl || '/pages/index/index';
  const tag = '[safeBack]';
  const wxNav = (typeof wx !== 'undefined' && wx) ? wx : {};
  console.log(tag + ' start fallback=' + url);
  const toast = function () {
    try { if (wxNav.showToast) wxNav.showToast({ title: '已返回主页', icon: 'none', duration: 600 }); } catch (e) {}
  };

  // 记录当前页面实例，稍后用来判断 navigateBack 是否真的离场。
  let len = 0;
  let currentPage = null;
  try {
    if (typeof getCurrentPages === 'function') {
      const p = getCurrentPages();
      if (Array.isArray(p)) { len = p.length; currentPage = p[len - 1]; }
    }
  } catch (e) {}
  console.log(tag + ' stackLen=' + len);

  // 强制回到目标页：依次尝试 reLaunch / redirectTo / navigateTo。
  // 此兜底对「navigateBack 空桩/静默失败」「真机无 navigateBack」都有效，
  // 且补齐了原 len>1 分支漏掉 navigateTo 的问题。
  const fallbackNow = function () {
    if (typeof wxNav.reLaunch === 'function') {
      try { wxNav.reLaunch({ url }); console.log(tag + ' reLaunch called'); toast(); return; }
      catch (e) { console.log(tag + ' reLaunch err: ' + (e && e.message ? e.message : e)); }
    }
    if (typeof wxNav.redirectTo === 'function') {
      try { wxNav.redirectTo({ url }); console.log(tag + ' redirectTo called'); toast(); return; }
      catch (e) { console.log(tag + ' redirectTo err: ' + (e && e.message ? e.message : e)); }
    }
    if (typeof wxNav.navigateTo === 'function') {
      try { wxNav.navigateTo({ url }); console.log(tag + ' navigateTo called'); toast(); return; }
      catch (e) { console.log(tag + ' navigateTo err: ' + (e && e.message ? e.message : e)); }
    }
    console.log(tag + ' 所有导航接口均失败，无法返回');
  };

  // 第一步：优先 navigateBack（有栈时保留上一页状态，仿真器标准行为）。
  // 注意：navigateBack 可能「静默失败」——调用不抛错但页面根本没退（部分运行时空桩）。
  // 绝不能仅凭“未抛错”就认定成功，必须校验页面是否真离场。
  const attemptedBack = !!(len > 1 && typeof wxNav.navigateBack === 'function');
  if (attemptedBack) {
    try { wxNav.navigateBack({ delta: 1 }); console.log(tag + ' navigateBack called'); }
    catch (e) { console.log(tag + ' navigateBack err: ' + (e && e.message ? e.message : e)); }
  } else {
    console.log(tag + ' 无页面栈/不可 navigateBack，直接进入强制兜底');
  }

  // 第二步：若环境支持 setTimeout，延迟校验 navigateBack 是否真离场；
  // 若不支持（部分 ink/QuickJS 运行时无 setTimeout），立即同步兜底，保证一定能回到目标页。
  // 关键：只有当“确实调用过 navigateBack”时，才用「是否仍在本页」判定它是否生效；
  // 若根本没调用（无栈，currentPage 为 null），绝不能把“仍在本页”误判为“已生效”，必须强制兜底。
  const verifyAndFallback = function () {
    let stillHere = false;
    if (attemptedBack) {
      try {
        if (typeof getCurrentPages === 'function') {
          const p = getCurrentPages();
          if (Array.isArray(p) && p.length && p[p.length - 1] === currentPage) stillHere = true;
        }
      } catch (e) {}
    }
    if (attemptedBack && !stillHere) { toast(); console.log(tag + ' navigateBack 已生效，无需兜底'); return; }
    console.log(tag + ' 启用强制兜底（无栈或 navigateBack 未生效）');
    fallbackNow();
  };

  if (typeof setTimeout === 'function') {
    setTimeout(verifyAndFallback, 350);
  } else {
    verifyAndFallback();
  }
}
