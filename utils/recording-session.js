/**
 * 录音会话共享逻辑（enroll / verify 复用）
 *
 * 抽出两个页面几乎逐字相同的录音监听与起停流程，消除重复，
 * 并避免录音参数 / 节流逻辑在两处分叉。页面只需提供差异化
 * 的数据字段名与「录音完成后的回调」。
 */

import wx from 'wx';
import { generateWaveform, combineFrames } from './voiceprint-engine.js';
import { speak } from './tts.js';

const FLAT_WAVEFORM = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
const RECORD_MS = 3000;
const WAVE_THROTTLE_MS = 120;

function assign(target, src) {
  if (!src) return target;
  for (const k in src) target[k] = src[k];
  return target;
}

function vibrate(short) {
  const app = getApp();
  if (app && app.globalData && app.globalData.vibrationEnabled) {
    if (short) wx.vibrateShort(); else wx.vibrateLong();
  }
}

function storeLastRecording(audio) {
  const app = getApp();
  if (app && app.globalData) app.globalData.lastRecording = audio;
}

/**
 * 绑定实时音频帧监听（节流 + 异常保护，避免每帧 setData 拖垮主线程）。
 * @param {Object} page 页面实例（this）
 */
export function setupRecorderListeners(page) {
  if (!page.recorderManager) return;
  page.recorderManager.onFrameRecorded(function (res) {
    try {
      const frameBuffer = res.frameBuffer;
      if (frameBuffer) {
        page.data.frameBuffers.push(frameBuffer);
        const nowt = Date.now();
        if (nowt - (page._lastWaveT || 0) > WAVE_THROTTLE_MS) {
          page._lastWaveT = nowt;
          page.setData({ waveformData: generateWaveform(frameBuffer) });
        }
      }
    } catch (e) {
      console.log('波形更新失败: ' + e);
    }
  });
}

/**
 * 开始一次录音会话（含自动停止排程）。
 * @param {Object} page 页面实例（this）
 * @param {Object} opts
 *   recordingKey   录音中状态字段名（如 'isRecording'）
 *   classKey       状态样式类字段名（如 'recordingClass'）
 *   recordingClass 录音中样式类值（如 'recording'）
 *   statusText     录音中状态文案
 *   startSpeak     开始录音语音提示
 *   stopMethod     自动停止时调用的页面方法名（如 'stopRecording'）
 *   extraData      随「开始」一起 setData 的额外字段（如 promptText / result）
 */
export function startRecordingSession(page, opts) {
  // 无录音能力（仿真/无麦克风权限）：直接提示，避免崩溃
  if (!page.recorderManager) {
    page.setData(assign({ status: '仿真环境无录音能力，无法录制' },
      { [opts.recordingKey]: false, [opts.classKey]: '' }));
    return;
  }

  // 清空帧缓冲区与处理标记
  page.data.frameBuffers = [];
  page.data._processed = false;

  page.setData(assign({
    status: opts.statusText,
    [opts.recordingKey]: true,
    [opts.classKey]: opts.recordingClass,
    waveformData: FLAT_WAVEFORM
  }, opts.extraData));

  vibrate(false);
  speak(opts.startSpeak);

  // 先排定自动停止，确保即便 start 抛错也能收尾（避免卡在「开始录音」）
  if (page._autoStop != null) { try { clearTimeout(page._autoStop); } catch (e) {} }
  page._autoStop = setTimeout(function () {
    if (typeof page[opts.stopMethod] === 'function') page[opts.stopMethod]();
  }, RECORD_MS);

  try {
    page.recorderManager.start({
      duration: RECORD_MS,
      sampleRate: 16000,
      numberOfChannels: 1,
      encodeBitRate: 48000,
      format: 'pcm'
    });
  } catch (e) {
    console.log('启动录音失败: ' + e);
    clearTimeout(page._autoStop);
    page.setData(assign({ status: '启动录音失败，请重试' },
      { [opts.recordingKey]: false, [opts.classKey]: '' }));
    speak('启动录音失败，请重试');
  }
}

/**
 * 结束一次录音会话，合并音频帧并回调处理。
 * @param {Object}   page 页面实例（this）
 * @param {Object}   opts
 *   recordingKey   录音中状态字段名
 *   classKey       状态样式类字段名
 *   extraData      随「停止」一起 setData 的额外字段（如 recorded / verificationPath）
 * @param {Function} onCombined 合并完音频后的回调 (combinedAudio) => void
 */
export function stopRecordingSession(page, opts, onCombined) {
  // 幂等：避免 3 秒定时器与手动点击重复触发导致重复处理
  if (page.data._processed) return;
  page.data._processed = true;
  if (page._autoStop != null) { try { clearTimeout(page._autoStop); } catch (e) {} }

  if (page.recorderManager) {
    try {
      page.recorderManager.stop();
    } catch (e) {
      console.log('停止录音失败: ' + e);
    }
  }

  setTimeout(function () {
    // 合并所有音频帧（复用 voiceprint-engine 的共享实现）
    const combinedAudio = combineFrames(page.data.frameBuffers || []);

    page.setData(assign({
      [opts.recordingKey]: false,
      [opts.classKey]: ''
    }, opts.extraData));

    vibrate(true);
    storeLastRecording(combinedAudio);

    if (typeof onCombined === 'function') onCombined(combinedAudio);
  }, 500);
}
