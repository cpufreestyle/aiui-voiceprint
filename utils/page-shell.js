/**
 * Page shell helpers — 抽取多个 .ink 页面重复的「键盘 / 手势」样板。
 *
 * 各页面原本各自重复定义 onKeyDown / onKeyUp（仅转发给 gesture 模块）以及
 * onShow / onHide（仅安装 / 卸载 window 级键盘兜底监听）。这里把它们收成共享函数，
 * 页面只需：
 *   import { gestureKeyDown, gestureKeyUp, shellInstallKeyboard, shellRemoveKeyboard } from './page-shell.js';
 *   ... onKeyDown: gestureKeyDown, onKeyUp: gestureKeyUp,
 *       onShow() { shellInstallKeyboard(this); /* + 页面专属逻辑 *\/ },
 *       onHide() { shellRemoveKeyboard(this); }
 */

import {
  routeKeyEvent,
  installKeyboardFallback,
  removeKeyboardFallback
} from './gesture.js';

// 与页面原始 onKeyDown 行为一致：记录时间戳并转发给手势路由。
export function gestureKeyDown(event) {
  this._lastFrameworkKey = Date.now();
  routeKeyEvent(this, event, 'down');
}

// 与页面原始 onKeyUp 行为一致：空事件直接返回，否则转发。
export function gestureKeyUp(event) {
  if (!event) return;
  routeKeyEvent(this, event, 'up');
}

// onShow 时安装 window 级键盘兜底监听（无实体键盘的仿真环境也能触发手势）。
export function shellInstallKeyboard(page) {
  installKeyboardFallback(page);
}

// onHide / onUnload 时卸载键盘兜底监听。
export function shellRemoveKeyboard(page) {
  removeKeyboardFallback(page);
}
