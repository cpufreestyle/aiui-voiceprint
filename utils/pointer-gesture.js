/**
 * 触屏 / 鼠标手势层（仿真器与审核环境的关键补强）
 *
 * 背景（官方审核驳回理由）：「由于滑动和点击事件没有区分开，所以无法体验其他内容」。
 * 根因有两层：
 *   1) 镜腿按键通道：parseKeyEvent 过去把一切未识别 code 兜底当成 tap，
 *      于是一次「滑动」被判成「点击」→ 主页滑动本应移动高亮，却变成进入当前项；
 *   2) DOM 通道（仿真器 / 审核环境里用鼠标或手指操作屏幕）：页面原来只绑了
 *      bindtap / bindlongpress，拖拽结束被系统合成为一次 tap，滑动永远不成立。
 *
 * 本模块在 window 级补上「鼠标 / 触屏」手势识别：
 *   - 位移 >= 24px            → handleSwipe('left'|'right'|'up'|'down')
 *   - 位移 <  24px 且 < 400ms → handleTap()
 *   - 按住 >= 400ms           → handleDoubleTap()（长按=退出，与镜腿双击同语义）
 * 与 utils/gesture.js 的镜腿按键通道共用 utils/tap-classify.js 的 classifyTap，从而：
 *   - 双击 / 去抖 / 长按语义完全一致；
 *   - 两个通道对同一次物理操作重复上报时自动去重（不会把一次点击误判成双击）。
 *
 * 只在存在 window 的运行时（仿真器 / 浏览器 / 审核环境）安装；
 * 真机 ink 运行时没有 window，自动跳过——真机走镜腿按键通道，两者互不干扰。
 *
 * 交互子元素（按钮、列表项等）通过 data-gesture-ignore="1" 标记：
 * 这些元素上的【点按】交给它们自己的 bindtap 处理，本层不再重复触发，
 * 避免「点一次按钮触发两遍」；但【滑动】永远由本层处理（拖拽不是点击）。
 */

import { classifyTap } from './tap-classify.js';

/** 位移超过该像素值即判定为滑动（而非点击） */
const SWIPE_MIN_PX = 24;
/** 按下到抬起小于该毫秒数判定为点按 */
const TAP_MAX_MS = 400;
/** 同一动作被鼠标 / 触屏两个通道重复上报时的去重窗口 */
const CROSS_DEDUPE_MS = 400;
/** 鼠标与按键通道互相当引的去重窗口（防止一次操作被两路同时判成双击） */
const CROSS_INPUT_TAP_MS = 250;
/** 鼠标 / 触屏通道自身的重复上报去抖（远小于按键通道的 150ms，
 *  否则两次快速点击会被当成一次，导致「双击退出」失效） */
const POINTER_DEBOUNCE_MS = 40;
/** 向上遍历 DOM 查找 data-gesture-ignore 的最大深度 */
const MAX_IGNORE_DEPTH = 10;

// 最近一次由本层分发出去的手势（跨通道去重用）
const _last = { channel: '', gesture: '', dir: '', at: 0 };

function nowMs() {
  return Date.now();
}

/** 读取事件坐标，兼容 touches / changedTouches / 鼠标事件 */
function pointOf(e) {
  if (!e) return null;
  // ink 模板 bindtouchstart 的事件有时把坐标放在 detail 里，一并兼容
  const srcs = [e, (e && e.detail) ? e.detail : null];
  for (let s = 0; s < srcs.length; s++) {
    const ev = srcs[s];
    if (!ev) continue;
    const list = (ev.touches && ev.touches.length) ? ev.touches
      : ((ev.changedTouches && ev.changedTouches.length) ? ev.changedTouches : null);
    const t = list ? list[0] : ev;
    if (!t) continue;
    let x = typeof t.clientX === 'number' ? t.clientX
      : (typeof t.pageX === 'number' ? t.pageX : null);
    let y = typeof t.clientY === 'number' ? t.clientY
      : (typeof t.pageY === 'number' ? t.pageY : null);
    if (x === null || y === null) continue;
    return { x: x, y: y };
  }
  return null;
}

/** 兜底识别「可点击元素」的 class（即使漏标 data-gesture-ignore 也不会双触发） */
const IGNORE_CLASSES = [
  'btn', 'button', 'op-btn', 'op-main',
  'menu-item', 'user-info', 'user-actions', 'grid-card', 'back-btn', 'mode-badge',
  'settings-toggle', 'settings-item', 'history-toggle', 'history-btn',
  'action-row', 'view-toggle', 'footer', 'key-hints', 'onb-cta', 'onb-step',
  'manual-toggle', 'record-btn', 'stop-btn', 'save-btn', 'finish-btn',
  'vs-save', 'vs-clear', 'verify-btn', 'retry-btn', 'home-btn', 'status-card'
];

function hasIgnoreClass(cls) {
  if (typeof cls !== 'string' || !cls) return false;
  const parts = cls.split(' ');
  for (let i = 0; i < parts.length; i++) {
    if (parts[i] && IGNORE_CLASSES.indexOf(parts[i]) !== -1) return true;
  }
  return false;
}

/** 目标元素是否属于「自带点击行为」的交互子元素（只屏蔽点按，不屏蔽滑动） */
function isIgnoredTarget(target) {
  let el = target;
  let depth = 0;
  while (el && depth < MAX_IGNORE_DEPTH) {
    try {
      if (el.dataset && el.dataset.gestureIgnore) return true;
      if (typeof el.getAttribute === 'function' && el.getAttribute('data-gesture-ignore')) return true;
      if (hasIgnoreClass(el.className)) return true;
      if (typeof el.tagName === 'string' && el.tagName === 'BUTTON') return true;
    } catch (e) {}
    el = el.parentElement || el.parentNode || null;
    depth++;
  }
  return false;
}

/** 主轴方向：位移更大的那一轴决定滑动方向 */
function dominantDir(dx, dy) {
  if (Math.abs(dx) >= Math.abs(dy)) return dx > 0 ? 'right' : 'left';
  return dy > 0 ? 'down' : 'up';
}

function addListener(target, type, fn, opts) {
  try {
    target.addEventListener(type, fn, opts);
  } catch (e) {
    try { target.addEventListener(type, fn, false); } catch (e2) {}
  }
}

function removeListener(target, type, fn) {
  try { target.removeEventListener(type, fn, false); } catch (e) {}
  try { target.removeEventListener(type, fn); } catch (e2) {}
  try { target.removeEventListener(type, fn, true); } catch (e3) {}
}

/** 滑动后短暂屏蔽 DOM click：拖拽结束后浏览器/框架仍会合成一次 click，
 *  若目标元素上挂着 bindtap，就会被误触发成「点击」——这正是审核驳回理由
 *  「滑动和点击事件没有区分开」在 DOM 通道的表现。这里用捕获阶段拦截，
 *  保证「刚发生过滑动」的几百毫秒内绝不再产生任何点击。 */
const CLICK_AFTER_SWIPE_GUARD_MS = 500;

function makeClickGuard(page) {
  const cg = function (e) {
    if (!page._lastPointerSwipeAt) return;
    if (Date.now() - page._lastPointerSwipeAt > CLICK_AFTER_SWIPE_GUARD_MS) return;
    try { if (e && e.stopPropagation) e.stopPropagation(); } catch (err) {}
    try { if (e && e.preventDefault) e.preventDefault(); } catch (err2) {}
  };
  return cg;
}

/**
 * 分发一次识别出的手势给页面（页面只需实现 handleTap / handleSwipe / handleDoubleTap）。
 * @param {Object} page    页面实例
 * @param {string} channel 'mouse' | 'touch'
 * @param {string} gesture 'tap' | 'swipe' | 'double'
 * @param {string} dir     滑动方向
 */
function dispatchGesture(page, channel, gesture, dir) {
  if (!page) return;
  const t = nowMs();
  // 跨通道去重：鼠标与触屏对同一次物理操作都会上报时，只认第一个通道
  if (_last.at && t - _last.at < CROSS_DEDUPE_MS &&
    _last.channel !== channel &&
    _last.gesture === gesture &&
    _last.dir === (dir || '')) {
    return;
  }
  _last.channel = channel;
  _last.gesture = gesture;
  _last.dir = dir || '';
  _last.at = t;

  if (gesture === 'swipe') {
    // 与按键通道互相当引，避免同一次滑动被两路各分发一次
    page._lastPointerSwipeAt = t;
    if (typeof page.handleSwipe === 'function') page.handleSwipe(dir);
    return;
  }

  if (gesture === 'double') {
    page._lastPointerTap = t;
    if (typeof page.handleDoubleTap === 'function') page.handleDoubleTap();
    return;
  }

  // tap：与按键通道互相当引；若刚刚已由按键通道触发过，则跳过，防止误判成双击
  if (page._lastKeyTap && t - page._lastKeyTap < CROSS_INPUT_TAP_MS) return;
  page._lastPointerTap = t;
  // 鼠标 / 触屏通道用更短的去抖窗口：这里每一次 down-up 都是完整的一次点击，
  // 两次快速点击必须能判成「双击=退出」，否则用户连退出都做不到（审核驳回理由 2）。
  const kind = classifyTap(page, { debounceMs: POINTER_DEBOUNCE_MS });
  if (kind === 'ignore') return;
  if (kind === 'double') {
    if (typeof page.handleDoubleTap === 'function') page.handleDoubleTap();
  } else if (typeof page.handleTap === 'function') {
    page.handleTap();
  }
}

/** 按压 / 触摸开始 */
function onDown(page, channel, e) {
  const p = pointOf(e);
  if (!p) { page._ptr = null; return; }
  page._ptr = {
    x: p.x,
    y: p.y,
    at: nowMs(),
    moved: false,
    target: (e && e.target) ? e.target : null,
    channel: channel
  };
}

/** 移动：只标记是否已超过滑动阈值，方向在抬起时判定 */
function onMove(page, channel, e) {
  const st = page._ptr;
  if (!st || st.channel !== channel) return;
  const p = pointOf(e);
  if (!p) return;
  const dx = p.x - st.x;
  const dy = p.y - st.y;
  if (!st.moved && (Math.abs(dx) > 6 || Math.abs(dy) > 6)) {
    st.moved = true;
    // 已判定为拖动：阻止默认行为，避免页面滚动 / 文本选中干扰手势
    try { if (e && e.preventDefault) e.preventDefault(); } catch (err) {}
  }
}

/** 抬起：滑动 / 点按 / 长按 三选一 */
function onUp(page, channel, e) {
  const st = page._ptr;
  page._ptr = null;
  if (!st || st.channel !== channel) return;
  const p = pointOf(e);
  const elapsed = nowMs() - st.at;
  if (!p) {
    // 无坐标信息：保守按一次点按处理
    dispatchGesture(page, channel, 'tap', '');
    return;
  }
  const dx = p.x - st.x;
  const dy = p.y - st.y;
  if (st.moved && (Math.abs(dx) >= SWIPE_MIN_PX || Math.abs(dy) >= SWIPE_MIN_PX)) {
    dispatchGesture(page, channel, 'swipe', dominantDir(dx, dy));
    return;
  }
  if (elapsed >= TAP_MAX_MS) {
    // 长按 = 退出（与镜腿双击同语义）
    dispatchGesture(page, channel, 'double', '');
    return;
  }
  // 点按：落在自带点击行为的元素上时让位给该元素自己的 bindtap
  if (isIgnoredTarget(st.target)) return;
  dispatchGesture(page, channel, 'tap', '');
}

/** 安装 window 级鼠标 / 触屏手势识别（幂等，同页面重复调用只会安装一次） */
export function installPointerGestures(page) {
  if (!page || page._removePointerGestures) return;
  const win = (typeof window !== 'undefined') ? window : null;
  if (!win || typeof win.addEventListener !== 'function') return;

  const md = function (e) { onDown(page, 'mouse', e); };
  const mm = function (e) { onMove(page, 'mouse', e); };
  const mu = function (e) { onUp(page, 'mouse', e); };
  const ts = function (e) { onDown(page, 'touch', e); };
  const tm = function (e) { onMove(page, 'touch', e); };
  const te = function (e) { onUp(page, 'touch', e); };
  const tc = function () { page._ptr = null; };
  const cg = makeClickGuard(page);

  // touchmove 必须是非 passive 才能 preventDefault 阻止滚动
  addListener(win, 'mousedown', md, false);
  addListener(win, 'mousemove', mm, false);
  addListener(win, 'mouseup', mu, false);
  addListener(win, 'touchstart', ts, false);
  addListener(win, 'touchmove', tm, { passive: false, capture: false });
  addListener(win, 'touchend', te, false);
  addListener(win, 'touchcancel', tc, false);
  // click 用捕获阶段：必须在任何 bindtap 之前拦截
  addListener(win, 'click', cg, true);

  page._removePointerGestures = function () {
    removeListener(win, 'mousedown', md);
    removeListener(win, 'mousemove', mm);
    removeListener(win, 'mouseup', mu);
    removeListener(win, 'touchstart', ts);
    removeListener(win, 'touchmove', tm);
    removeListener(win, 'touchend', te);
    removeListener(win, 'touchcancel', tc);
    removeListener(win, 'click', cg);
    page._ptr = null;
    page._removePointerGestures = null;
  };
}

/** 卸载 window 级鼠标 / 触屏手势识别 */
export function removePointerGestures(page) {
  if (page && page._removePointerGestures) page._removePointerGestures();
}
