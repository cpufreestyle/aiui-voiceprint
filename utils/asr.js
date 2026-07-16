/**
 * Rokid / AIUI 语音识别（ASR）适配层
 *
 * AIUI（Rokid 眼镜）提供微信兼容的语音识别器，是 Rokid 设备特有能力：
 *   const recognizer = wx.getSpeechRecognizer();
 *   recognizer.onStart(cb);
 *   recognizer.onRecognize((res) => { res.result }); // 中间结果
 *   recognizer.onStop((res) => { res.result });       // 最终结果
 *   recognizer.onError(cb);
 *   recognizer.start({ lang: 'zh_CN' });
 *   recognizer.stop();
 *
 * 文档：https://github.com/jsar-project/AIUI/blob/main/documentation/3-api/weixin-compatible-apis/speech.md
 *
 * 说明：
 * - 在真机（具备 Rokid ASR 能力）上走真实识别，字幕文字来自 onStop 的 res.result。
 * - 在 AIUI 仿真环境若没有 wx.getSpeechRecognizer，自动回退占位文本，保证页面可演示。
 * - 注意：语音识别器会自行占用麦克风做录音+识别；若真机不允许与 wx.media.getRecorderManager
 *   同时采集，应改为仅用识别器（其音频亦可用于声纹，需设备侧另行暴露 PCM）。
 */

// 仿真回退用字幕文本池（仅当无 wx.getSpeechRecognizer 时使用）
const DEMO_PHRASES = [
  '你今天过得怎么样？',
  '我们等会儿去吃午饭吧',
  '刚才那个会议几点开始？',
  '外面天气好像要下雨了',
  '帮我看一下这条消息',
  '周末有空一起爬山吗？'
];

let _demoIdx = 0;
let _recognizer = null;
let _latestText = '';
let _inited = false;

export function isAsrAvailable() {
  return !!(typeof wx !== 'undefined' && wx && typeof wx.getSpeechRecognizer === 'function');
}

// 初始化识别器，绑定事件回调。handlers: { onStart, onInterim, onFinal, onError }
export function initAsr(handlers) {
  handlers = handlers || {};
  if (!isAsrAvailable()) return false;
  if (_inited) return true;

  _recognizer = wx.getSpeechRecognizer();
  _recognizer.onStart(function () {
    _latestText = '';
    if (handlers.onStart) handlers.onStart();
  });
  _recognizer.onRecognize(function (res) {
    if (res && res.result) {
      _latestText = res.result;
      if (handlers.onInterim) handlers.onInterim(res.result);
    }
  });
  _recognizer.onStop(function (res) {
    if (res && res.result) _latestText = res.result;
    if (handlers.onFinal) handlers.onFinal(res ? res.result : '');
  });
  _recognizer.onError(function (err) {
    if (handlers.onError) handlers.onError(err);
  });

  _inited = true;
  return true;
}

export function startAsr(opts) {
  if (!_recognizer) return;
  _latestText = '';
  _recognizer.start(Object.assign({ lang: 'zh_CN' }, opts || {}));
}

export function stopAsr() {
  if (!_recognizer) return;
  try { _recognizer.stop(); } catch (e) {}
}

// 取本句已识别的文字：真机返回识别器累积结果，否则回退占位文本
export function takeLatestText() {
  if (isAsrAvailable()) return _latestText || '';
  const text = DEMO_PHRASES[_demoIdx % DEMO_PHRASES.length];
  _demoIdx += 1;
  return text;
}

export function asrMode() {
  return isAsrAvailable() ? 'rokid' : 'demo';
}
