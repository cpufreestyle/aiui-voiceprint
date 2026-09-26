/**
 * 点击语义判定（镜腿按键通道与鼠标 / 触屏通道共用）
 *
 * 抽成独立模块的原因：
 *   gesture.js（按键）与 pointer-gesture.js（鼠标 / 触屏）都要用它，
 *   若互相 import 会形成循环依赖；放在独立文件里，两边都单向依赖它。
 *
 * 统一语义（两种输入通道完全一致）：
 *   - <150ms 的重复点击视为同一次物理操作的重复上报 → ignore
 *   - 两次点击间隔 <500ms → double（双击=退出）
 *   - 其余 → single（单击=进入 / 执行）
 */

/** 双击判定阈值（毫秒）。AIUI 无原生双击事件，用两次短按间隔识别。 */
export const DOUBLE_TAP_MS = 500;

/** 单击去抖阈值（毫秒）。部分真机会把「一次物理按压」上报成多次 keyup。 */
export const TAP_DEBOUNCE_MS = 150;

/**
 * 统一判定一次 tap 的性质，处理「设备重复上报」与「双击」两种情况。
 * @param {Object} ctx 页面实例（this）
 * @param {Object} [opts] { debounceMs, doubleMs } 覆盖阈值。鼠标 / 触屏通道传入更小的
 *                      debounceMs：那里的每一次 down-up 都是完整的一次点击，
 *                      两次快速点击必须能判成双击（退出），不能被当成「重复上报」。
 * @returns {'single'|'double'|'ignore'}
 */
export function classifyTap(ctx, opts) {
  if (!ctx) return 'ignore';
  const now = Date.now();
  const debounceMs = (opts && typeof opts.debounceMs === 'number') ? opts.debounceMs : TAP_DEBOUNCE_MS;
  const doubleMs = (opts && typeof opts.doubleMs === 'number') ? opts.doubleMs : DOUBLE_TAP_MS;
  if (ctx._lastTapRaw && now - ctx._lastTapRaw < debounceMs) {
    return 'ignore';
  }
  ctx._lastTapRaw = now;

  const last = ctx._lastTapTime || 0;
  if (last && now - last < doubleMs) {
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
