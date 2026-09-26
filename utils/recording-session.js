/**
 * 录音会话共享逻辑（enroll / verify 复用）
 *
 * 抽出两个页面几乎逐字相同的录音监听与起停流程，消除重复，
 * 并避免录音参数 / 节流逻辑在两处分叉。页面只需提供差异化
 * 的数据字段名与「录音完成后的回调」。
 *
 * ===== 为什么这一版按官方文档重写（对应审核驳回理由「录入功能不可用」）=====
 * 官方 media-capture.md 的关键约束：
 *   1. start(options) 只接受 sampleRate / numberOfChannels / format / frameSize
 *      四项——没有 duration、没有 encodeBitRate。旧代码多传的字段在部分运行时
 *      会直接拒绝（甚至不抛错、静默失败），表现为「点了开始录音却录不到东西」。
 *   2. start() 返回 Promise，权限被拒时 Promise 拒绝。旧代码未 catch。
 *   3. onFrameRecorded({frameBuffer}) 的 frameBuffer 只在本次回调内有效，
 *      官方示例明确要 frameBuffer.slice(0) 复制后再保存。旧代码直接 push 引用，
 *      底层缓冲被复用时帧内容会被覆盖 → 合成出的音频是噪声/空 → 特征无效 → 录入失败。
 *   4. onStop({duration, fileSize}) 才是可靠的「本次录音已结束」信号，且官方承诺
 *      「剩余音频帧处理完成后才触发 onStop」。旧代码 stop 后盲目 setTimeout 500ms，
 *      若帧还没到齐就合并会漏掉尾部帧；若运行时根本不回调，则合并出 0 字节音频
 *      → isRecordingValid 永远 false → 录入不可用。
 *   5. onError({errMsg}) 必须注册，否则麦克风占用 / 权限失败时页面毫无反馈。
 */

import wx from 'wx';
import { generateWaveform, combineFrames } from './voiceprint-engine.js';
import { speak } from './tts.js';

const FLAT_WAVEFORM = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
const RECORD_MS = 3000;
const WAVE_THROTTLE_MS = 120;
/** onStop 迟迟不触发时的兜底等待（毫秒）。 */
const STOP_FALLBACK_MS = 1500;
/** 兜底路径下，再给「最后一帧」留出的缓冲时间（毫秒）。 */
const STOP_FALLBACK_GRACE_MS = 300;

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

/** 安全注册一个回调（mgr.onXxx 是「注册器」而非「已赋值的回调」） */
function register(mgr, name, fn, quiet) {
  try {
    if (mgr && typeof mgr[name] === 'function') { mgr[name](fn); return true; }
  } catch (e) {
    if (!quiet) console.log('[recorder] 注册 ' + name + ' 失败: ' + (e && e.message ? e.message : e));
  }
  return false;
}

/** 安全注销一个回调 */
function unregister(mgr, name) {
  const off = 'off' + name.charAt(0).toUpperCase() + name.slice(1);
  try {
    if (mgr && typeof mgr[off] === 'function') { mgr[off](); return true; }
  } catch (e) {}
  return false;
}

/**
 * 复制一帧音频。
 * 官方明确：frameBuffer 只在当前回调内有效，必须复制（frameBuffer.slice(0)）。
 * 同时兼容 ArrayBuffer / Uint8Array / 普通数组三种运行时实现。
 */
function copyFrame(frameBuffer) {
  if (!frameBuffer) return null;
  try {
    if (typeof frameBuffer.slice === 'function') {
      const c = frameBuffer.slice(0);
      if (c && (c.byteLength || c.length)) return c;
    }
  } catch (e) {}
  try {
    if (typeof Uint8Array !== 'undefined') {
      const u = new Uint8Array(frameBuffer);
      if (u.length) return u;
    }
  } catch (e2) {}
  return null;
}

/** 帧缓冲的权威存储：只写 page._frameBuffers。
 *  绝不再镜像到 page.data——帧不是可 JSON 序列化的数据（见下方说明）。 */
function pushFrame(page, frame) {
  if (!Array.isArray(page._frameBuffers)) page._frameBuffers = [];
  page._frameBuffers.push(frame);
  // 绝不把帧写进 page.data：官方要求页面 data 必须可 JSON 序列化，而帧是
  // ArrayBuffer / Uint8Array，被框架序列化后会变成 {}（甚至让 setData 直接报错，
  // 表现为「一录音整个页面就卡住」）。权威存储只用实例字段 _frameBuffers。
}

function frameList(page) {
  if (Array.isArray(page._frameBuffers) && page._frameBuffers.length) return page._frameBuffers;
  return [];
}

function clearFrames(page) {
  page._frameBuffers = [];
}

/**
 * 绑定实时音频帧监听（节流 + 异常保护，避免每帧 setData 拖垮主线程）。
 * 同时注册 onStop / onError / 中断回调——按官方建议「start 前就注册好」，
 * 避免遗漏快速到达的首个事件。幂等：同一页面重复调用只会注册一次。
 *
 * @param {Object} page 页面实例（this）
 */
export function setupRecorderListeners(page) {
  if (!page || !page.recorderManager) return;
  if (page._recorderListenersReady) return;
  const mgr = page.recorderManager;

  // ===== 音频帧：必须复制，绝不能保存引用 =====
  register(mgr, 'onFrameRecorded', function (res) {
    try {
      const frameBuffer = res && (res.frameBuffer || res.data || res.buffer);
      if (!frameBuffer) return;
      const copy = copyFrame(frameBuffer);
      if (!copy) return;
      pushFrame(page, copy);
      const nowt = Date.now();
      if (nowt - (page._lastWaveT || 0) > WAVE_THROTTLE_MS) {
        page._lastWaveT = nowt;
        page.setData({ waveformData: generateWaveform(copy) });
      }
    } catch (e) {
      console.log('波形更新失败: ' + e);
    }
  });

  // ===== onStop：可靠的「本次录音已结束」信号（剩余帧已交付）=====
  register(mgr, 'onStop', function (res) {
    page._recorderStopFired = true;
    page._recorderStopInfo = res || {};
    if (typeof page._onRecorderStop === 'function') {
      try { page._onRecorderStop(res || {}); } catch (e) { console.log('onStop 处理失败: ' + e); }
    }
  });

  // ===== onError：权限失败 / 设备占用 / 启动失败 =====
  register(mgr, 'onError', function (res) {
    const raw = res && (res.errMsg || res.message);
    const msg = raw ? String(raw) : '未知录音错误';
    console.log('录音出错: ' + msg);
    page._recorderError = msg;
    if (typeof page._onRecorderError === 'function') {
      try { page._onRecorderError(msg); } catch (e) {}
    }
  });

  // ===== 录音开始 / 中断：仅记录状态，便于排查「启动成功但无帧」=====
  register(mgr, 'onStart', function () { page._recorderStarted = true; }, true);
  register(mgr, 'onInterruptionBegin', function () {
    page._recorderInterrupted = true;
    console.log('录音被中断');
  }, true);
  register(mgr, 'onInterruptionEnd', function () {
    page._recorderInterrupted = false;
    console.log('录音中断结束');
  }, true);

  page._recorderListenersReady = true;
}

/** 页面销毁时调用：注销全部录音回调，避免离开页面后仍往旧页面 setData */
export function teardownRecorderListeners(page) {
  if (!page || !page.recorderManager) return;
  const mgr = page.recorderManager;
  unregister(mgr, 'onFrameRecorded');
  unregister(mgr, 'onStop');
  unregister(mgr, 'onError');
  unregister(mgr, 'onStart');
  unregister(mgr, 'onInterruptionBegin');
  unregister(mgr, 'onInterruptionEnd');
  page._recorderListenersReady = false;
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
  // 无录音能力（仿真/无麦克风权限）：直接提示并语音告知，避免页面毫无反馈
  if (!page.recorderManager) {
    page.setData(assign({ status: '当前环境无法录音，请检查麦克风权限后重试' },
      { [opts.recordingKey]: false, [opts.classKey]: '' }));
    speak('当前环境无法录音，请检查麦克风权限');
    return;
  }

  // 清空帧缓冲区与处理标记
  clearFrames(page);
  if (page.data) page.data._processed = false;
  page._stopFinalized = false;
  page._recorderStopFired = false;
  page._recorderError = '';
  page._recorderStarted = false;
  page._recSessId = (page._recSessId || 0) + 1;
  // 回调连接点：onStop / onError 事件驱动收尾时由 stopRecordingSession 填充
  page._onRecorderStop = null;
  page._onRecorderError = null;

  page.setData(assign({
    status: opts.statusText,
    [opts.recordingKey]: true,
    [opts.classKey]: opts.recordingClass,
    waveformData: FLAT_WAVEFORM
  }, opts.extraData));

  vibrate(false);
  speak(opts.startSpeak);

  // 先排定自动停止，确保即便 start 抛错/被拒也能收尾（避免卡在「开始录音」）
  if (page._autoStop != null) { try { clearTimeout(page._autoStop); } catch (e) {} }
  page._autoStop = setTimeout(function () {
    if (typeof page[opts.stopMethod] === 'function') page[opts.stopMethod]();
  }, RECORD_MS);

  // 官方 start 只认这四项参数；多传 duration / encodeBitRate 在部分运行时会失败。
  // start() 返回 Promise，权限拒绝时拒绝——必须 catch，否则产生未处理拒绝。
  const startOpts = {
    sampleRate: 16000,
    numberOfChannels: 1,
    format: 'pcm',
    frameSize: 250
  };
  let ret = null;
  try {
    ret = page.recorderManager.start(startOpts);
  } catch (e) {
    console.log('启动录音失败: ' + (e && e.message ? e.message : e));
    handleStartFailure(page, opts);
    return;
  }
  if (ret && typeof ret.then === 'function') {
    ret.then(function () {
      page._recorderStarted = true;
    }).catch(function (e) {
      console.log('启动录音被拒绝: ' + (e && e.message ? e.message : e));
      handleStartFailure(page, opts);
    });
  }
}

function handleStartFailure(page, opts) {
  if (page._autoStop != null) { try { clearTimeout(page._autoStop); } catch (e) {} }
  page._autoStop = null;
  if (page.data) page.data._processed = true; // 防紧随的自动 stop 再走一遍完整流程
  page._stopFinalized = true;
  const msg = page._recorderError
    ? ('无法开始录音：' + page._recorderError)
    : '启动录音失败，请检查麦克风权限后重试';
  page.setData(assign({ status: msg, [opts.recordingKey]: false, [opts.classKey]: '' }, opts.extraData || {}));
  speak(msg);
}

/**
 * 结束一次录音会话，合并音频帧并回调处理。
 *
 * 收尾由 onStop 事件驱动（官方承诺此时剩余音频帧已交付完毕），
 * 同时保留 1500ms 兜底定时器——若运行时不回调 onStop 也能正常出结果，
 * 绝不再盲目只等 500ms 就合并（那会漏帧 / 拿到 0 字节音频）。
 *
 * @param {Object}   page 页面实例（this）
 * @param {Object}   opts
 *   recordingKey   录音中状态字段名
 *   classKey       状态样式类字段名
 *   extraData      随「停止」一起 setData 的额外字段（如 recorded / verificationPath）
 * @param {Function} onCombined 合并完音频后的回调 (combinedAudio, meta) => void
 */
export function stopRecordingSession(page, opts, onCombined) {
  // 幂等：避免 3 秒定时器与手动点击重复触发导致重复处理
  if (page.data && page.data._processed) return;
  if (page.data) page.data._processed = true;
  page._stopFinalized = false;
  page._recStopReason = '';
  page._stopOnCombined = onCombined;
  page._stopOpts = opts;

  if (page._autoStop != null) { try { clearTimeout(page._autoStop); } catch (e) {} }
  page._autoStop = null;

  // 先把「录音中」的 UI 状态收掉（收尾可能是异步的，不能让人干等）
  page.setData(assign({
    [opts.recordingKey]: false,
    [opts.classKey]: ''
  }, opts.extraData));

  // onStop 事件驱动：帧已交付齐，立即收尾
  page._onRecorderStop = function () {
    finalizeStop(page, 'onStop', 0);
  };
  // onError 事件驱动：录音失败也要收尾（交回 0 字节音频，由页面提示重录）
  page._onRecorderError = function (msg) {
    finalizeStop(page, 'error:' + msg, 0);
  };

  if (page.recorderManager) {
    try {
      const ret = page.recorderManager.stop();
      if (ret && typeof ret.then === 'function') {
        ret.catch(function (e) { console.log('stop 返回拒绝: ' + (e && e.message ? e.message : e)); });
      }
    } catch (e) {
      console.log('停止录音失败: ' + (e && e.message ? e.message : e));
    }
  }

  // 兜底：部分运行时不回调 onStop。等 1500ms 仍无 onStop 就自行收尾，
  // 再多留 300ms 给可能滞后的最后一帧。
  if (page._stopFallbackTimer != null) { try { clearTimeout(page._stopFallbackTimer); } catch (e) {} }
  page._stopFallbackTimer = setTimeout(function () {
    if (page._stopFinalized) return;
    if (page._recorderStopFired) {
      finalizeStop(page, 'onStop-late', 0);
    } else {
      console.log('[recorder] onStop 未触发，走兜底收尾');
      finalizeStop(page, 'fallback', STOP_FALLBACK_GRACE_MS);
    }
  }, STOP_FALLBACK_MS);
}

/** 收尾：合并帧 → 复位 UI → 回调页面（幂等，只跑一次） */
function finalizeStop(page, reason, graceMs) {
  if (page._stopFinalized) return;
  page._stopFinalized = true;
  page._recStopReason = reason;
  page._onRecorderStop = null;
  page._onRecorderError = null;

  if (page._stopFallbackTimer != null) { try { clearTimeout(page._stopFallbackTimer); } catch (e) {} }
  page._stopFallbackTimer = null;

  const opts = page._stopOpts || {};
  const onCombined = page._stopOnCombined;
  const frames = frameList(page);
  const errMsg = page._recorderError || '';
  page._stopOnCombined = null;
  page._stopOpts = null;

  const run = function () {
    // 合并所有音频帧（复用 voiceprint-engine 的共享实现）
    const combinedAudio = combineFrames(frames || []);

    page.setData(assign({
      [opts.recordingKey]: false,
      [opts.classKey]: ''
    }, opts.extraData));

    vibrate(true);
    storeLastRecording(combinedAudio);

    if (typeof onCombined === 'function') {
      try {
        onCombined(combinedAudio, { reason: reason, frames: (frames || []).length, error: errMsg });
      } catch (e) {
        console.log('录音完成回调失败: ' + (e && e.message ? e.message : e));
      }
    }
    // 收尾后清空本次缓冲，避免下一次会话混入旧帧
    clearFrames(page);
  };

  if (graceMs > 0 && typeof setTimeout === 'function') {
    setTimeout(run, graceMs);
  } else {
    run();
  }
}

/** 页面销毁 / 离开时调用：取消挂起的自动停止与兜底定时器 */
export function abortRecordingSession(page) {
  if (!page) return;
  if (page._autoStop != null) { try { clearTimeout(page._autoStop); } catch (e) {} }
  page._autoStop = null;
  if (page._stopFallbackTimer != null) { try { clearTimeout(page._stopFallbackTimer); } catch (e) {} }
  page._stopFallbackTimer = null;
  page._stopFinalized = true;
  page._onRecorderStop = null;
  page._onRecorderError = null;
  if (page.data) page.data._processed = true;
}
