import wx from 'wx';
import { routeIntentSmart, MODE_PAGE } from './utils/intent-router.js';

export default {
  onLaunch: function (options) {
    console.log('声纹识别应用启动 - 无障碍版');
    // 冷启动：语音唤起也走这里（options 里可能带有 Hi Rokid 语义路由透传的原始话语）
    this._dispatch(options, true);
  },
  onShow: function (options) {
    console.log('应用显示');
    // 热启动：应用已在后台，用户再次语音唤起时走 onShow；仅当确实带了 query/mode 才分发，
    // 避免用户手动切前台（无语音参数）时被误跳转。
    var opt = options || {};
    if (opt.query || opt.mode) this._dispatch(options, false);
  },
  onHide: function () {
    console.log('应用隐藏');
  },

  // 语音直呼分发：解析 onLaunch/onShow 的 options → 路由到目标模式页
  // 字段名容错：官方文档未明确 query 载荷键名（见 docs/架构-语音直呼集成.md §8 未决项），
  // query/text/utterance/asr/mode 等候选键名全部摸一遍。
  _dispatch: function (options, isLaunch) {
    var opt = options || {};
    var q = opt.query || {};
    var raw = '';
    if (typeof q === 'string') {
      raw = q;
    } else {
      raw = q.query || q.text || q.utterance || q.asr || opt.text || '';
    }
    var explicitMode = q.mode || opt.mode || ''; // OS 若真能传结构化 mode，最高优先

    var self = this;
    // 取得 route 后的分发逻辑抽成闭包：既服务于 explicitMode 同步分支，也作为
    // routeIntentSmart 的异步回调（一级高置信时其内部同步回调，时序与现状一致）。
    var applyRoute = function (route) {
      console.log('语音直呼路由: raw="' + raw + '" mode=' + (route && route.mode) + ' page=' + (route && route.page));
      self.globalData.launchIntent = { raw: raw, route: route, at: Date.now() };

      if (!route || route.mode === 'home') return; // 冷启动默认落 index 主页，不跳转

      var url = route.page + '?mode=' + route.mode + '&autoStart=1&q=' + encodeURIComponent(raw);
      var wxNav = (typeof wx !== 'undefined' && wx) ? wx : {};
      var doRedirect = function () {
        if (typeof wxNav.redirectTo !== 'function') {
          console.log('语音直呼跳转失败: 当前环境不支持 redirectTo，保留在主页');
          return;
        }
        try {
          wxNav.redirectTo({ url: url });
        } catch (e) {
          console.log('语音直呼跳转失败: ' + (e && e.message ? e.message : e));
        }
      };

      if (isLaunch) {
        // onLaunch 时页面栈可能未就绪，延迟一拍再跳（双保险：globalData.launchIntent 已写入，
        // 页面 onLoad 兜底读取，防止 redirectTo 传参在个别固件上丢失）
        setTimeout(doRedirect, 0);
      } else {
        doRedirect();
      }
    };

    if (explicitMode && MODE_PAGE[explicitMode]) {
      // OS 直接给了结构化 mode：最高优先，同步分发
      applyRoute({ mode: explicitMode, page: MODE_PAGE[explicitMode], params: {}, confidence: 1 });
    } else {
      // 从原始文本解析：一级正则高置信时 routeIntentSmart 内部同步回调（行为同现状），
      // 只有低置信长尾才异步走端上 LLM（最多 3s 超时兜底），接通二级路由。
      routeIntentSmart(raw, applyRoute);
    }
  },

  globalData: {
    currentUser: null,
    voiceprintDB: null,
    lastRecording: null,
    lastResult: null,
    sessionStartTime: null,
    // 无障碍设置
    accessibilityMode: true,
    vibrationEnabled: true,
    voicePromptEnabled: true,
    highContrastEnabled: true,
    // 语音直呼唤起意图：{ raw, route, at }，供页面兜底读取（防 redirectTo 传参丢失）
    launchIntent: null
  }
}
