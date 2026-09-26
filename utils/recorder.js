import wx from 'wx';

/**
 * 安全获取录音管理器。不同运行时 API 位置不同：
 *   - AIUI 官方（media-capture.md）：wx.media.getRecorderManager() ← 优先
 *   - 小程序风格兼容：wx.getRecorderManager()
 * 拿不到时返回 null（绝不抛错），由调用方进入演示模式或静默，
 * 否则 onLoad 抛错会中断页面初始化，连带导致按键/返回全部失效。
 *
 * @returns {Object|null} 录音管理器；当前运行时无录音能力时返回 null
 */
export function acquireRecorderManager() {
  const candidates = [];
  let stub = null;
  // 顺序很关键：官方 AIUI 文档只定义了 wx.media.getRecorderManager()，
  // 且它在 wasm32 / 无录音能力时返回 undefined，是规范入口，故优先取它。
  // 旧代码顺序相反，某些运行时两个都存在，但 wx.getRecorderManager 返回的是
  // 不完整桩对象（没有 onFrameRecorded）→ 一帧都收不到 → 「录入功能不可用」。
  try {
    if (wx && wx.media && typeof wx.media.getRecorderManager === 'function') {
      candidates.push(wx.media.getRecorderManager);
    }
  } catch (e) {}
  try {
    if (typeof wx.getRecorderManager === 'function') candidates.push(wx.getRecorderManager);
  } catch (e) {}
  for (let i = 0; i < candidates.length; i++) {
    try {
      const mgr = candidates[i].call(wx);
      // 只认「真的能收到音频帧」的管理器：没有 onFrameRecorded 的桩对象
      // 先留着当兜底，让上层至少能调用 start/stop 表现成「无法录音」，
      // 而不是静默地一帧不收。
      if (mgr && typeof mgr.onFrameRecorded === 'function') return mgr;
      if (mgr && !stub) stub = mgr;
    } catch (e) {
      console.log('[recorder] 初始化失败: ' + (e && e.message ? e.message : e));
    }
  }
  return stub || null;
}

/**
 * 诊断：列出当前 wx 运行时中与录音/语音相关的可用接口。
 * 用于确认真机（Rokid）提供了哪些能力，或仿真器是否提供了非常规命名的录音 API。
 * @returns {string[]} 接口名列表（函数会带 '()' 后缀）
 */
export function probeRecordingApis() {
  const found = [];
  const push = function (k, v) {
    try { found.push(k + (typeof v === 'function' ? '()' : '')); } catch (e) {}
  };
  try {
    if (typeof wx === 'undefined' || !wx) return found;
    const keys = Object.keys(wx);
    const want = /record|speech|recogni|audio|media|voice|asr|mic/i;
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      if (want.test(k)) push(k, wx[k]);
    }
    // 官方入口藏在 wx.media 下，单独列出来便于一眼确认
    try {
      if (wx.media) {
        const mkeys = Object.keys(wx.media);
        for (let j = 0; j < mkeys.length; j++) {
          push('wx.media.' + mkeys[j], wx.media[mkeys[j]]);
        }
      }
    } catch (e2) {}
  } catch (e) {
    console.log('[recorder] 探测接口失败: ' + (e && e.message ? e.message : e));
  }
  return found;
}
