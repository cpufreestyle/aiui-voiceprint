/**
 * 语音提示（TTS）适配层
 *
 * AIUI（Rokid 眼镜）提供微信兼容的语音合成器，是 Rokid 设备特有能力：
 *   const synth = wx.getSpeechSynthesizer();
 *   synth.onEnd(cb);
 *   synth.onError(cb);
 *   synth.start({ text: '...', lang: 'zh_CN' });
 *   synth.stop();
 *
 * 文档：https://github.com/jsar-project/AIUI/blob/main/documentation/3-api/weixin-compatible-apis/speech.md
 *
 * 说明：
 * - 真机（具备 Rokid TTS 能力）朗读传入文本；无该能力时静默（仿真环境不报错）。
 * - 全局开关 voicePromptEnabled（存于 globalData，默认开）。
 */

import wx from 'wx';

let _synth = null;
let _inited = false;

function isTtsAvailable() {
  return !!(typeof wx !== 'undefined' && wx && typeof wx.getSpeechSynthesizer === 'function');
}

function ensureInit() {
  if (_inited) return !!_synth;
  _inited = true;
  if (!isTtsAvailable()) return false;
  try {
    _synth = wx.getSpeechSynthesizer();
    if (_synth && typeof _synth.onEnd === 'function') _synth.onEnd(function () {});
    if (_synth && typeof _synth.onError === 'function') {
      _synth.onError(function (e) { console.log('TTS 错误: ' + e); });
    }
  } catch (e) {
    _synth = null;
  }
  return !!_synth;
}

// 语音播报；开关关闭或无能力时静默
export function speak(text, opts) {
  if (!text) return;
  const app = getApp();
  if (app && app.globalData && app.globalData.voicePromptEnabled === false) return;
  if (!ensureInit() || !_synth) return;
  if (typeof _synth.start !== 'function') return;
  try {
    _synth.start(Object.assign({ text: text, lang: 'zh_CN' }, opts || {}));
  } catch (e) {
    console.log('TTS 播报失败: ' + e);
  }
}

export function stopSpeak() {
  if (_synth && typeof _synth.stop === 'function') {
    try { _synth.stop(); } catch (e) {}
  }
}

// 切换语音提示开关，返回新状态
export function toggleVoicePrompt() {
  const app = getApp();
  if (!app || !app.globalData) return false;
  app.globalData.voicePromptEnabled = !app.globalData.voicePromptEnabled;
  return app.globalData.voicePromptEnabled;
}

export function isVoicePromptOn() {
  const app = getApp();
  return !!(app && app.globalData && app.globalData.voicePromptEnabled !== false);
}
