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
  routeVoiceWakeup,
  installKeyboardFallback,
  removeKeyboardFallback
} from './gesture.js';

/**
 * 语音 / 触控唤醒通道路由。
 * 官方 page-events.md：页面定义 onVoiceWakeup(event) 接收唤醒，
 * event.keyword 区分来源——触控唤醒固定为 'clickAiAssist'，语音唤醒词是 '乐奇' / 'Hi Rokid'。
 * 仿真器 / 真机上这一路若不接，用户点屏幕就「毫无反应」（审核驳回理由 2）。
 * 用法：onVoiceWakeup: gestureVoiceWakeup
 */
export function gestureVoiceWakeup(event) {
  routeVoiceWakeup(this, event);
}

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
