import wx from 'wx';
import { installPointerGestures, removePointerGestures } from './pointer-gesture.js';

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
 *   { type: 'unknown',raw }            未识别按键（只回显，不触发任何动作）
 *   null                               event 为空
 * 未识别 code 不再兜底成 tap——否则一次【滑动】会被误判成【点击】，
 * 同时原始 code 通过 __keyLog 回显，便于真机校准。
 *
 * 除了镜腿按键，本模块还负责在仿真 / 审核环境（有 window 的运行时）安装
 * 「鼠标 / 触屏」手势识别（utils/pointer-gesture.js）：
 * 拖拽=滑动、点按=短按、长按=双击，与按键通道共用 classifyTap。
 */

/**
 * 解析镜腿按键 / 仿真按键事件。
 *
 * @param {Object} event 按键事件对象（onKeyUp / onKeyDown 入参、window KeyboardEvent，
 *                       或带 direction/gesture/swipe 等方向字段的宿主手势事件）
 * @returns {{ type: 'tap'|'swipe'|'back'|'unknown', direction?: string, raw: string } | null}
 *   null    —— event 为空
 *   'back'  —— 返回 / 退出
 *   'swipe' —— 滑动（direction 为 left/right/up/down）
 *   'tap'   —— 单击（进入 / 执行）
 *   'unknown' —— 未识别按键：**不再兜底当成 tap**（见下方说明）
 *
 * ⚠️ 为什么兜底从 tap 改成 unknown（官方审核驳回理由 2 的根因）：
 *   过去「任何未识别 code 一律当作一次 tap」，于是一次【滑动】若以未收录的 code 上报，
 *   会被直接判成【点击】→ 主页「滑动=移动高亮」永远不生效，表现出来的就是
 *   「滑动和点击没有区分开，无法体验其他内容」。
 *   现在未识别按键只回显原始 code 供真机校准，绝不触发任何页面动作，
 *   保证「滑动绝不会变成点击」。
 */
export function parseKeyEvent(event) {
  if (!event) return null;
  const code = (event.code || event.key || '').toString();
  const lowerRaw = code.toLowerCase();
  const keyCode = typeof event.keyCode === 'number' ? event.keyCode : 0;
  // 归一化：去掉非字母数字，便于精确比对 KEYCODE_BACK / goBack 等多种写法
  const norm = lowerRaw.replace(/[^a-z0-9]/g, '');
  // 有些宿主把数值键码放在 code/key 里（如 '21'），这里也按数值码解析一次
  const numInCode = /^[0-9]+$/.test(norm) ? parseInt(norm, 10) : 0;
  const rawLabel = code || ('kc' + keyCode);

  // ===== 0. 宿主自带方向字段（最高优先级，说明这次输入本身就是一次手势）=====
  // 例如 { code:'GlobalHook', direction:'forward' } / { gesture:'swipeleft' }
  const dirFields = [event.direction, event.gesture, event.swipe, event.action, event.param, event.value];
  for (let i = 0; i < dirFields.length; i++) {
    const v = dirFields[i];
    if (typeof v !== 'string' || !v) continue;
    const d = dirFromString(v.toLowerCase().replace(/[^a-z0-9]/g, ''));
    if (d) return { type: 'swipe', direction: d, raw: rawLabel };
  }

  // ===== 1. 返回 / 退出 =====
  // 精确匹配（不做子串匹配）：否则 'Backward'（后滑）会被误判成返回。
  const backExact = [
    'back', 'backspace', 'escape', 'esc', 'home',
    'keycodeback', 'goback', 'backkey', 'backkeyevent', 'systemback',
    'browserback', 'exit', 'quit'
  ];
  if (backExact.indexOf(norm) !== -1) return { type: 'back', raw: rawLabel };
  // 兜住 xxxxBACK 这类封装写法（'backward' 不以 back 结尾，不会被误判）
  if (/back$/.test(norm) && norm.length <= 16) return { type: 'back', raw: rawLabel };
  // Android / Rokid 数值返回码
  if (keyCode === 8 || keyCode === 202 || keyCode === 4 || keyCode === 27 || keyCode === 3 ||
    numInCode === 8 || numInCode === 202 || numInCode === 4 || numInCode === 27 || numInCode === 3) {
    return { type: 'back', raw: rawLabel };
  }

  // ===== 2. 滑动 =====
  // 2.0 原始 DOM 事件名（TouchDown / MouseUp ...）不是手势，绝不能当滑动或点击：
  //      'touchdown' 里含 'down'，若放行会被误判成「下滑」。
  const domEventNames = ['touchstart', 'touchend', 'touchmove', 'touchcancel',
    'touchdown', 'touchup', 'mousedown', 'mouseup', 'mousemove', 'click', 'dblclick'];
  for (let di = 0; di < domEventNames.length; di++) {
    if (norm === domEventNames[di]) return { type: 'unknown', raw: rawLabel };
  }
  // 2.1 按数值方向码（Android DPAD + Rokid 前滑/后滑）
  const dirByNum = { 19: 'up', 20: 'down', 21: 'left', 22: 'right', 183: 'left', 184: 'right' };
  if (dirByNum[keyCode]) return { type: 'swipe', direction: dirByNum[keyCode], raw: rawLabel };
  if (dirByNum[numInCode]) return { type: 'swipe', direction: dirByNum[numInCode], raw: rawLabel };
  // 2.2 按字符串关键字：ArrowLeft / SwipeUp / DPAD_RIGHT / forward / backward ...
  const dir = dirFromString(norm);
  if (dir) return { type: 'swipe', direction: dir, raw: rawLabel };

  // ===== 3. 单击 =====
  const tapExact = [
    'globalhook', 'enter', 'numpadenter', 'space', 'spacebar', 'tap', 'center', 'click',
    'keycodeenter', 'dpadcenter', 'ok', 'confirm', 'single', 'press'
  ];
  // 触控唤醒（官方 onVoiceWakeup 的 keyword）也可能以按键 code 的形式到达，
  // 必须明确认成 tap：漏掉它在仿真器里就「点了没反应」。
  const tapExactExtra = ['clickaiassist', 'aiassist', 'wakeup', 'temple', 'touch'];
  if (tapExact.indexOf(norm) !== -1) return { type: 'tap', raw: rawLabel };
  for (let ti = 0; ti < tapExactExtra.length; ti++) {
    if (norm === tapExactExtra[ti]) return { type: 'tap', raw: rawLabel };
  }
  const tapNum = { 13: 1, 32: 1, 66: 1, 23: 1 };
  if (tapNum[keyCode] || tapNum[numInCode]) return { type: 'tap', raw: rawLabel };

  // ===== 4. 明确的长按 / 双击类：不当 tap（否则长按退出会被当成进入）=====
  if (norm.indexOf('long') !== -1 || norm.indexOf('double') !== -1) {
    return { type: 'unknown', raw: rawLabel };
  }

  // ===== 5. 兜底：未识别 =====
  return { type: 'unknown', raw: rawLabel };
}

/** 从归一化字符串中识别方向；forward=前滑(左)，backward=后滑(右)，与 183/184 映射一致 */
function dirFromString(n) {
  if (!n) return '';
  if (n.indexOf('forward') !== -1) return 'left';
  if (n.indexOf('backward') !== -1) return 'right';
  if (n.indexOf('up') !== -1) return 'up';
  if (n.indexOf('down') !== -1) return 'down';
  if (n.indexOf('left') !== -1) return 'left';
  if (n.indexOf('right') !== -1) return 'right';
  return '';
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

// 点击语义判定抽到 utils/tap-classify.js（与鼠标 / 触屏通道共用，避免循环依赖）
// classifyTap 供本文件的 fireTap 使用；另外三个继续从本模块导出，保持对外接口不变。
import { classifyTap } from './tap-classify.js';
export { DOUBLE_TAP_MS, TAP_DEBOUNCE_MS, classifyTap, isDoubleTap } from './tap-classify.js';

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

  // 未识别按键：只回显原始 code（logRaw 已做），绝不分发页面动作。
  // 这是「滑动与点击必须区分开」的关键：宁可这次输入没有反应，
  // 也绝不能把一次滑动误判成点击（曾导致审核驳回：无法体验其他内容）。
  if (action.type === 'unknown') {
    return;
  }

  if (action.type === 'swipe') {
    const code = (event.code || event.key || '').toString();
    const now = Date.now();
    // 与鼠标 / 触屏通道互相当引：刚由拖拽产生过滑动时，忽略紧随其后的按键滑动
    if (ctx._lastPointerSwipeAt && now - ctx._lastPointerSwipeAt < 300) return;
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

/** 用 classifyTap 判定单击/双击/去抖后再分发，确保一次物理按压只触发一次。
 *  同时与鼠标 / 触屏通道互相当引：一次物理操作只应产生一次点击，
 *  否则「刚点过一次就被算成双击」会误触发退出。 */
function fireTap(ctx) {
  // 若刚刚已由鼠标 / 触屏通道触发过点击，则本次按键点击视为同一次操作，跳过
  if (ctx._lastPointerTap && Date.now() - ctx._lastPointerTap < 250) return;
  ctx._lastKeyTap = Date.now();
  const kind = classifyTap(ctx);
  if (kind === 'ignore') return;
  if (kind === 'double') {
    if (ctx.handleDoubleTap) ctx.handleDoubleTap();
  } else {
    if (ctx.handleTap) ctx.handleTap();
  }
}

/**
 * 语音唤醒通道路由（官方 page-events.md：页面可定义 onVoiceWakeup(event)）。
 *
 * 为什么必须接这一路：
 *   AIUI 的「触控唤醒」并不是 DOM 点击，而是以 onVoiceWakeup 事件上报的，
 *   且用 event.keyword 区分来源——触控/按键唤醒固定为 'clickAiAssist'，
 *   语音唤醒词是 '乐奇' / 'Hi Rokid'。仿真器与真机上这一路都可能被触发，
 *   若页面没实现 onVoiceWakeup，用户在仿真面板里点一下就「毫无反应」
 *   （审核驳回理由 2 的另一半原因：根本没有能用的点击通道）。
 *
 * 语义与镜腿短按完全一致：一次唤醒 = 一次 tap（双击唤醒词 = 退出）。
 *
 * @param {Object} ctx   页面实例（this）
 * @param {Object} event onVoiceWakeup 入参，形如 { keyword: 'clickAiAssist' }
 */
export function routeVoiceWakeup(ctx, event) {
  if (!ctx) return;
  const rawKeyword = (event && (event.keyword || event.wakeupWord || event.word ||
    event.name || event.type || '')) || '';
  const kw = String(rawKeyword).toLowerCase().replace(/[^a-z0-9]/g, '');
  // 与鼠标 / 触屏通道互相当引：同一物理操作可能同时产生唤醒与点击
  if (ctx._lastPointerTap && Date.now() - ctx._lastPointerTap < 250) return;
  logRaw(ctx, 'wakeup:' + (rawKeyword || '?'), 'wakeup');

  // 退出类唤醒词（部分定制唤醒词表把退出放在这里）
  if (/^(exit|quit|close|back)$/.test(kw) || kw.indexOf('exit') !== -1 || kw.indexOf('quit') !== -1) {
    if (ctx.handleDoubleTap) { ctx.handleDoubleTap(); return; }
    if (ctx.handleBack) { ctx.handleBack(); return; }
    return;
  }

  // 方向类唤醒词 → 滑动（左侧/上侧=前滑，右侧/下侧=后滑）
  const dir = dirFromString(kw);
  if (dir) {
    if (ctx.handleSwipe) ctx.handleSwipe(dir);
    return;
  }

  // 其余（'clickAiAssist'、'乐奇'、'Hi Rokid'、未知来源）一律当作一次短按：
  // 用户主动唤醒本应用，意图就是「进入 / 执行」。
  fireTap(ctx);
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
 *
 * 同时安装「鼠标 / 触屏」手势（见 utils/pointer-gesture.js）。
 * 官方审核环境 / AIUI 仿真器里没有镜腿按键，用户是用鼠标拖拽或手指滑动来操作屏幕的；
 * 早期只绑 bindtap/bindlongpress，拖拽结束被合成为一次 tap，于是「滑动」永远不成立——
 * 这正是审核驳回理由「滑动和点击事件没有区分开」的直接原因。
 * 这里在 window 级补上鼠标 / 触屏识别：拖拽=滑动、点按=短按、长按=双击（退出）。
 */
let _activeFallbackCtx = null;

/** 页面前台标记：只有当前可见页面才安装 window 级输入兜底（避免多页面重复触发） */
let _activePointerCtx = null;

export function installKeyboardFallback(ctx) {
  // ===== 鼠标 / 触屏手势（仿真器与审核环境的主要输入方式）=====
  // 换页时先把上一个页面的监听摘掉，保证同一时刻只有前台页面响应屏幕手势。
  if (_activePointerCtx && _activePointerCtx !== ctx) {
    removePointerGestures(_activePointerCtx);
    _activePointerCtx = null;
  }
  installPointerGestures(ctx);
  if (ctx._removePointerGestures) _activePointerCtx = ctx;

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
  // 同步卸载鼠标 / 触屏手势监听（换页 / 退后台时必须摘掉，否则旧页面仍会响应手势）
  if (ctx) {
    if (_activePointerCtx === ctx) _activePointerCtx = null;
    removePointerGestures(ctx);
  }
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
 * @param {Object} [page]        当前页面实例；导航接口全部不可用时用它调用
 *                              官方页面完成 API finish() 交回焦点退出
 */
export function safeBack(fallbackUrl, page) {
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
    // 最后兜底：官方页面完成 API。部分运行时的 wx 导航全是空桩（调用不抛错但页面不退），
    // 这时只有 finish() 能真正让页面离场；否则用户连「退出」都做不到。
    if (page && typeof page.finish === 'function') {
      try { page.finish(); console.log(tag + ' page.finish() called'); return; }
      catch (e) { console.log(tag + ' finish err: ' + (e && e.message ? e.message : e)); }
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
