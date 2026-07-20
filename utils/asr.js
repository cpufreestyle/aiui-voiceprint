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
// 当前生效的回调集合：{ onStart, onInterim, onFinal, onError }。
// 关键修复（单例锁死 bug）：此前 initAsr 把 handlers 直接闭包进 onStart/onRecognize/
// onStop/onError 四个绑定函数里，且 `if (_inited) return true;` 会在识别器已创建后
// 直接早退——导致第一个调用 initAsr 的页面之后，任何其它页面再传入新的 handlers
// 都被静默丢弃，事件永远只回调最早那份闭包。多页面各自 initAsr(自己的回调) 因此
// 无法重绑，只有第一个生效。
// 修法：把 handlers 存进这个模块级可变的 _handlers，四个事件绑定函数只在识别器
// 首次创建时绑定一次，但函数体统一读取「当下」的 _handlers.onXxx，而不是各自闭包
// 住的旧对象。这样识别器仍只创建/绑定一次（真机硬件资源不重复申请），但每次
// initAsr(handlers) 调用都会真正更新 _handlers、让新页面的回调立刻接管事件。
let _handlers = {};
// 是否正在监听中（onStart 之后、onStop/onError 之前）
let _listening = false;

export function isAsrAvailable() {
  return !!(typeof wx !== 'undefined' && wx && typeof wx.getSpeechRecognizer === 'function');
}

// 初始化识别器 + （重）绑定事件回调。handlers: { onStart, onInterim, onFinal, onError }
// 每次调用都会更新 _handlers（不再因 _inited 已为 true 而早退丢弃新回调）。
export function initAsr(handlers) {
  _handlers = handlers || {};
  if (!isAsrAvailable()) return false;
  if (_inited) return true;

  _recognizer = wx.getSpeechRecognizer();
  _recognizer.onStart(function () {
    _latestText = '';
    _listening = true;
    if (_handlers.onStart) _handlers.onStart();
  });
  _recognizer.onRecognize(function (res) {
    if (res && res.result) {
      _latestText = res.result;
      if (_handlers.onInterim) _handlers.onInterim(res.result);
    }
  });
  _recognizer.onStop(function (res) {
    if (res && res.result) _latestText = res.result;
    _listening = false;
    if (_handlers.onFinal) _handlers.onFinal(res ? res.result : '');
  });
  _recognizer.onError(function (err) {
    _listening = false;
    if (_handlers.onError) _handlers.onError(err);
  });

  _inited = true;
  return true;
}

export function startAsr(opts) {
  if (!_recognizer) return;
  _latestText = '';
  _recognizer.start(Object.assign({ lang: 'zh_CN' }, opts || {}));
}

// 幂等停止：无识别器（未初始化/无 ASR 能力）或已停止时安全空操作，绝不抛错，
// 便于页面在 onHide/onUnload 等生命周期里无条件调用。
export function stopAsr() {
  _listening = false;
  if (!_recognizer) return;
  try { _recognizer.stop(); } catch (e) {}
}

// 是否正在监听中，供页面判断要不要触发「重新 start」的常听循环
export function isAsrListening() {
  return _listening;
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
