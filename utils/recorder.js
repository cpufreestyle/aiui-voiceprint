import wx from 'wx';

/**
 * 安全获取录音管理器。不同运行时 API 位置不同：
 *   - 标准小程序 / 多数 AIUI(JSAR) 运行时：wx.getRecorderManager()
 *   - 部分 Rokid 文档示例：wx.media.getRecorderManager()
 * 拿不到时返回 null（绝不抛错），由调用方进入演示模式或静默，
 * 否则 onLoad 抛错会中断页面初始化，连带导致按键/返回全部失效。
 *
 * @returns {Object|null} 录音管理器；当前运行时无录音能力时返回 null
 */
export function acquireRecorderManager() {
  const candidates = [];
  try {
    if (typeof wx.getRecorderManager === 'function') candidates.push(wx.getRecorderManager);
  } catch (e) {}
  try {
    if (wx && wx.media && typeof wx.media.getRecorderManager === 'function') {
      candidates.push(wx.media.getRecorderManager);
    }
  } catch (e) {}
  for (let i = 0; i < candidates.length; i++) {
    try {
      const mgr = candidates[i].call(wx);
      if (mgr) return mgr;
    } catch (e) {
      console.log('[recorder] 初始化失败: ' + (e && e.message ? e.message : e));
    }
  }
  return null;
}

/**
 * 诊断：列出当前 wx 运行时中与录音/语音相关的可用接口。
 * 用于确认真机（Rokid）提供了哪些能力，或仿真器是否提供了非常规命名的录音 API。
 * @returns {string[]} 接口名列表（函数会带 '()' 后缀）
 */
export function probeRecordingApis() {
  const found = [];
  try {
    if (typeof wx === 'undefined' || !wx) return found;
    const keys = Object.keys(wx);
    const want = /record|speech|recogni|audio|media|voice|asr|mic/i;
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      if (want.test(k)) found.push(k + (typeof wx[k] === 'function' ? '()' : ''));
    }
  } catch (e) {
    console.log('[recorder] 探测接口失败: ' + (e && e.message ? e.message : e));
  }
  return found;
}
