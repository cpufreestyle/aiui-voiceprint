<script def>
{
  "navigationBarTitleText": "生成相似图 - 无障碍版",
  "description": "用例C：拍照→调用图像生成服务生成相似图→推送给云端 relay→展示取件码/二维码，供用户用手机扫码或输码查看。支持语音直呼 mode=genimg&autoStart=1 自动触发全流程；每一段（拍照/生成/推送）失败均有独立的大字幕降级提示，绝不静默卡死。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "wizardStep": {
          "type": "string",
          "enum": ["intro", "shooting", "generating", "pushing", "result"],
          "description": "当前流程阶段"
        },
        "caption": { "type": "string", "description": "主字幕文案" },
        "hint": { "type": "string", "description": "副提示文案" },
        "captionClass": {
          "type": "string",
          "enum": ["normal", "ok", "warn", "error"],
          "description": "主字幕样式类：normal 正常 / ok 成功 / warn 演示降级 / error 失败"
        },
        "cameraReady": { "type": "boolean", "description": "相机是否可用（否则演示拍照）" },
        "genModeText": { "type": "string", "description": "图像生成模式徽章文案" },
        "genBadgeClass": { "type": "string", "enum": ["live", "demo"], "description": "图像生成徽章样式类" },
        "relayModeText": { "type": "string", "description": "relay 配置状态徽章文案" },
        "relayBadgeClass": { "type": "string", "enum": ["live", "demo"], "description": "relay 徽章样式类" },
        "showSettings": { "type": "boolean", "description": "是否展开设置面板" },
        "genApiKeyMasked": { "type": "string", "description": "已保存图像生成 apiKey 的脱敏显示" },
        "relayBaseDisplay": { "type": "string", "description": "当前 relay 地址显示文案" },
        "hasResultImage": { "type": "boolean", "description": "是否已拿到生成图片可供本地预览" },
        "resultImageSrc": { "type": "string", "description": "生成图片地址（URL 或 data: base64）" },
        "hasDemoNotice": { "type": "boolean", "description": "是否展示演示降级说明" },
        "demoNotice": { "type": "string", "description": "演示降级说明文案" },
        "showQr": { "type": "boolean", "description": "是否展示二维码（relay 推送成功后）" },
        "qrSrc": { "type": "string", "description": "relay 代画的二维码图片地址" },
        "code": { "type": "string", "description": "4 位取件码" },
        "codeSpaced": { "type": "string", "description": "取件码分位展示文案，如 1 2 3 4" },
        "hasPushNote": { "type": "boolean", "description": "是否展示推送失败的补充说明" },
        "pushNoteText": { "type": "string", "description": "推送失败补充说明（含图片地址口述）" },
        "listening": { "type": "boolean", "description": "是否正在语音聆听中" },
        "lastStyleText": { "type": "string", "description": "当前生效的语音风格词展示" }
      },
      "required": ["wizardStep", "caption", "hint", "captionClass", "cameraReady"]
    }
  }
}
</script>

<script setup>
import wx from 'wx';
import { routeKeyEvent, installKeyboardFallback, removeKeyboardFallback, safeBack } from '../../utils/gesture.js';
import { speak } from '../../utils/tts.js';
import { acquireCameraContext, isCameraAvailable, takePhoto, pathToBase64, getFileBytes } from '../../utils/camera.js';
import { formatBytes, checkImageSize } from '../../utils/media-limits.js';
import { generateSimilar, imagegenMode, getImagegenConfig, setImagegenConfig } from '../../utils/imagegen.js';
import { makeCode, pushResult, qrImageUrl, isRelayConfigured, getRelayBase, setRelayBase } from '../../utils/phone-bridge.js';
import { initAsr, startAsr, stopAsr, isAsrAvailable } from '../../utils/asr.js';

// 语音指令解析：把一句识别文本映射成页面动作。
// 顺序即优先级：先识别明确动作词（返回/发手机/拍照/开始），再识别风格改写，最后兜底当风格。
function parseGenCommand(text) {
  const t = (text || '').trim();
  if (!t) return { action: 'none' };
  if (/返回|退出|回去|回到?主页|主页|首页/.test(t)) return { action: 'back' };
  if (/(发|传|推|送)(到|去|给|出)?.{0,4}(手机|电话|过去|出去)|发出去|发给我|发手机/.test(t)) return { action: 'send' };
  if (/重?拍照|再拍|拍一?张|拍个照|拍照片|开始/.test(t)) return { action: 'shoot' };
  // 明确的风格/画风改写词 → 把整句当扩写提示词
  if (/改成|变成|换成|风格|色调|画风|夜景|白天|卡通|水彩|油画|素描|赛博|黑白|漫画|写实|科幻|复古|暖色|冷色|滤镜|梦幻|中国风|极简/.test(t)) {
    return { action: 'restyle', style: t };
  }
  if (/重新生成|再生成|再来一?张|再画一?张|重画/.test(t)) return { action: 'regen' };
  // 兜底：非空且不含动作词，一律当作风格扩写词
  return { action: 'restyle', style: t };
}

export default {
  data: {
    wizardStep: 'intro',
    caption: '拍一张照片，我来生成一张相似的图，发到你的手机',
    hint: '短按开始，或点下方「开始」按钮',
    captionClass: 'normal',
    cameraReady: false,

    genModeText: '演示模式',
    genBadgeClass: 'demo',
    relayModeText: '未配置',
    relayBadgeClass: 'demo',
    showSettings: false,
    genApiKeyMasked: '未设置',
    relayBaseDisplay: '',

    hasResultImage: false,
    resultImageSrc: '',
    hasDemoNotice: false,
    demoNotice: '',
    showQr: false,
    qrSrc: '',
    code: '',
    codeSpaced: '',
    hasPushNote: false,
    pushNoteText: '',

    listening: false,
    lastStyleText: '',

    // 运行期（不进 schema 渲染）
    cameraCtx: null,
    baseDesc: '',       // 首次生成缓存的照片描述，重生成换风格时复用，免重复视觉调用
    lastStyle: '',      // 上一次语音扩写的风格词
    lastShotBase64: ''  // 首次拍照的 base64，baseDesc 缺失时回退用
  },

  onLoad(query) {
    console.log('生成相似图页面加载');
    const app = getApp();
    const q = query || {};
    let mode = q.mode || '';
    let autoStart = q.autoStart === '1';

    // 兜底：redirectTo 传参在个别固件上可能丢失，回退读 app.globalData.launchIntent
    // （见 docs/架构-语音直呼集成.md §2.3；app.js/app.json 的接入由另一 Agent 负责，
    //  这里做纯防御性读取，字段不存在时安全跳过，不影响手动进入本页的场景）
    if (!mode) {
      try {
        if (app && app.globalData && app.globalData.launchIntent) {
          const li = app.globalData.launchIntent;
          if (li && li.route && li.route.mode === 'genimg') {
            mode = 'genimg';
            autoStart = true;
          }
        }
      } catch (e) {}
    }

    this._autoStart = mode === 'genimg' ? autoStart : false;
    this._running = false;

    this._genApiKeyDraft = '';
    this._relayBaseDraft = '';

    this.data.cameraCtx = acquireCameraContext();
    this.setData({ cameraReady: isCameraAvailable() });
    this.refreshGenBadge();
    this.refreshRelayBadge();
    this.refreshMasks();
  },

  onReady() {
    if (!this.data.cameraCtx) {
      this.data.cameraCtx = acquireCameraContext();
      this.setData({ cameraReady: isCameraAvailable() });
    }
    if (this._autoStart) {
      this._autoStart = false;
      const that = this;
      // 给取景组件一拍时间铺好再自动开始，避免 onReady 刚触发时相机还没就绪
      setTimeout(function () { that.startFlow(); }, 300);
    }
    // 进页即常听语音指令（眼镜无触屏，语音是主入口；无 ASR 能力时 setupGenVoice 内部诚实降级）
    this.setupGenVoice();
  },

  onShow() { installKeyboardFallback(this); this.setupGenVoice(); },
  onHide() { removeKeyboardFallback(this); this.teardownGenVoice(); },
  onUnload() { removeKeyboardFallback(this); this.teardownGenVoice(); },

  vibrate() {
    const app = getApp();
    if (app && app.globalData && app.globalData.vibrationEnabled) {
      try { wx.vibrateShort(); } catch (e) {}
    }
  },

  refreshGenBadge() {
    const live = imagegenMode() === 'live';
    this.setData({
      genModeText: live ? 'AI 生成' : '演示模式',
      genBadgeClass: live ? 'live' : 'demo'
    });
  },

  refreshRelayBadge() {
    const ok = isRelayConfigured();
    this.setData({
      relayModeText: ok ? 'relay 已配置' : 'relay 未配置',
      relayBadgeClass: ok ? 'live' : 'demo'
    });
  },

  refreshMasks() {
    const cfg = getImagegenConfig();
    const k = cfg.apiKey || '';
    this.setData({
      genApiKeyMasked: k ? (k.slice(0, 4) + '****' + k.slice(-4)) : '未设置',
      relayBaseDisplay: getRelayBase()
    });
  },

  // ====== 主流程：拍照 → 生成 → 推送 ======

  startFlow() {
    if (this._running) return;
    this._running = true;
    const camReady = this.data.cameraReady;
    this.setData({
      wizardStep: 'shooting',
      caption: camReady ? '对准画面，正在拍照…' : '当前无相机，使用演示拍照',
      hint: '请保持稳定',
      captionClass: 'normal',
      hasResultImage: false, resultImageSrc: '',
      hasDemoNotice: false, demoNotice: '',
      showQr: false, qrSrc: '', code: '', codeSpaced: '',
      hasPushNote: false, pushNoteText: ''
    });
    speak(camReady ? '开始拍照' : '当前没有相机，进入演示流程');
    const that = this;
    setTimeout(function () { that.doShoot(); }, 500);
  },

  doShoot() {
    const that = this;
    if (this.data.cameraReady && this.data.cameraCtx) {
      takePhoto(this.data.cameraCtx, { quality: 'high' })
        .then(function (res) { return that.ingestPhoto(res.tempImagePath); })
        .catch(function (e) {
          console.log('[genimg] 拍照失败: ' + e);
          that.failShoot('拍照失败，请重试');
        });
    } else {
      // 无相机能力：走演示拍照，dataUrl 为空交给 imagegen 的演示降级处理
      that.doGenerate(null);
    }
  },

  // 处理拍到的照片：取大小→校验≤5MB→读 base64→进入生成环节
  ingestPhoto(path) {
    const that = this;
    return getFileBytes(path).then(function (bytes) {
      const chk = checkImageSize(bytes || 0);
      if (!chk.ok) {
        that.failShoot(chk.reason + '，请靠近些重拍');
        return;
      }
      return pathToBase64(path).then(function (b64) {
        that.setData({ hint: bytes ? ('已拍摄 ' + formatBytes(bytes)) : '已拍摄' });
        // 新拍照片 → 缓存原图、清空上一轮描述缓存与风格
        that.data.lastShotBase64 = b64 || '';
        that.data.baseDesc = '';
        // 读取失败也不中断：b64 为空时 imagegen 会按「无输入图」走演示降级，诚实标注
        that.doGenerate(b64 || null);
      });
    });
  },

  // 拍照环节的独立降级：清晰大字幕 + 语音提示，退回 intro 允许重试，不静默卡死
  failShoot(msg) {
    this._running = false;
    this.setData({
      wizardStep: 'intro',
      caption: msg,
      hint: '短按重新开始',
      captionClass: 'error'
    });
    speak(msg);
    this.vibrate();
  },

  // @param {string|null} dataUrl 输入照片 base64；重生成走 baseDesc 时可为 null
  // @param {string} [extra] 语音扩写/改风格提示词，拼进生成 prompt
  doGenerate(dataUrl, extra) {
    const that = this;
    const live = imagegenMode() === 'live';
    const styleTip = extra ? ('，风格：' + extra) : '';
    this.setData({
      wizardStep: 'generating',
      caption: extra ? ('正在按“' + extra + '”重新生成…') : '正在生成相似图…',
      hint: live ? ('AI 生成中，通常需要几秒到二十几秒，请稍候' + styleTip) : '未配置生成模型，将展示演示说明',
      captionClass: 'normal'
    });
    speak(live ? (extra ? '正在按新风格重新生成，请稍候' : '正在生成相似图，请稍候') : '开始演示生成流程');
    const opts = { style: '相似示意图', size: '1024x1024' };
    if (extra) opts.extra = extra;
    // 无输入图但有缓存描述 → 走 baseDesc 直接文生图，省一次视觉调用
    if (!dataUrl && this.data.baseDesc) opts.baseDesc = this.data.baseDesc;
    generateSimilar(dataUrl, opts)
      .then(function (res) { that.handleGenResult(res); });
  },

  // 生成环节的独立降级：未配置/失败一律 demo，诚实标注，不再继续推送流程
  handleGenResult(res) {
    this.refreshGenBadge();
    // 缓存视觉描述：后续语音换风格可直接据它文生图，免再拍/再描述
    if (res && res.basedOn) this.data.baseDesc = res.basedOn;
    if (!res || !res.imageUrl) {
      this._running = false;
      const notice = (res && res.text) || '演示：此处应生成一张相似图';
      this.setData({
        wizardStep: 'result',
        caption: '演示模式：未生成真实图片',
        hint: (res && res.error) ? ('原因：' + res.error) : '未配置图像生成模型',
        captionClass: 'warn',
        hasDemoNotice: true,
        demoNotice: notice,
        hasResultImage: false,
        showQr: false
      });
      speak('演示模式，' + notice);
      this.vibrate();
      return;
    }
    this.doPush(res.imageUrl);
  },

  doPush(imageUrl) {
    const that = this;
    const code = makeCode();
    this.setData({
      wizardStep: 'pushing',
      caption: '生成成功，正在发送到手机…',
      hint: '取件码 ' + this.spaceCode(code),
      captionClass: 'normal',
      hasResultImage: true,
      resultImageSrc: imageUrl,
      code: code,
      codeSpaced: this.spaceCode(code)
    });
    speak('生成成功，正在发送到手机');
    pushResult(code, imageUrl).then(function (res) {
      that.handlePushResult(imageUrl, code, res);
    });
  },

  // 推送环节的独立降级：relay 不可达/未配置 → 大字幕说明 + 口述图片地址，不假装成功
  handlePushResult(imageUrl, code, res) {
    this._running = false;
    this.refreshRelayBadge();
    if (res && res.ok) {
      this.setData({
        wizardStep: 'result',
        caption: '已生成并发送到手机',
        hint: '手机扫码，或输入取件码 ' + this.spaceCode(code) + ' 查看',
        captionClass: 'ok',
        showQr: true,
        qrSrc: qrImageUrl(code),
        hasPushNote: false,
        pushNoteText: ''
      });
      speak('已生成相似图，手机扫码或输入取件码 ' + this.chineseDigits(code) + ' 查看');
    } else {
      const err = (res && res.error) || '未知错误';
      this.setData({
        wizardStep: 'result',
        caption: '发送到手机失败',
        hint: err,
        captionClass: 'error',
        showQr: false,
        hasPushNote: true,
        pushNoteText: '图片地址：' + imageUrl
      });
      speak('发送到手机失败，' + err + '。图片地址是 ' + imageUrl);
    }
    this.vibrate();
  },

  spaceCode(code) {
    return String(code || '').split('').join(' ');
  },

  // 把数字取件码转成中文逐位读法，比西文数字更适合 TTS 逐位播报（避免读成完整数值）
  chineseDigits(code) {
    const map = { '0': '零', '1': '一', '2': '二', '3': '三', '4': '四', '5': '五', '6': '六', '7': '七', '8': '八', '9': '九' };
    const s = String(code || '');
    let out = '';
    for (let i = 0; i < s.length; i++) {
      out += (map[s[i]] || s[i]) + ' ';
    }
    return out.trim();
  },

  resetAll() {
    this._running = false;
    this.setData({
      wizardStep: 'intro',
      caption: '拍一张照片，我来生成一张相似的图，发到你的手机',
      hint: '短按开始，或点下方「开始」按钮',
      captionClass: 'normal',
      hasResultImage: false, resultImageSrc: '',
      hasDemoNotice: false, demoNotice: '',
      showQr: false, qrSrc: '', code: '', codeSpaced: '',
      hasPushNote: false, pushNoteText: ''
    });
    speak('重新开始');
  },

  // ====== 全语音控制（进页常听：眼镜无触屏，语音是主入口，识别一句后自动重开）======

  // 进页常听：对齐 index/media 的 setup/schedule/teardown 三件套（含 onError 重启，杜绝静默失聪）。
  setupGenVoice() {
    if (this._voiceActive) return;
    if (!isAsrAvailable()) {
      this.setData({ hint: '语音不可用，短按开始、双击退出' }); // 诚实降级，不阻塞手势路径
      return;
    }
    const that = this;
    this._voiceActive = true;
    initAsr({
      onStart: function () { that.setData({ listening: true }); },
      onInterim: function (partial) { that.setData({ hint: partial }); },
      onFinal: function (finalText) {
        that.setData({ listening: false });
        const t = (finalText || '').trim();
        if (t) {
          that.setData({ hint: '识别到：' + t });
          // 复用既有 parseGenCommand/dispatchVoice；生成/推送中的误触发由各动作的 _running 守卫挡住
          that.dispatchVoice(parseGenCommand(t), t);
        }
        if (that._voiceActive) that.scheduleGenRestart(); // 退出类指令已 teardown 时不再重启
      },
      onError: function (err) {
        console.log('[genimg] 常听 ASR 错误: ' + ((err && err.errMsg) || err) + '，将自动重启');
        that.setData({ listening: false });
        that.scheduleGenRestart();
      }
    });
    startAsr({ lang: 'zh_CN' });
  },

  // 真机识别器 onStop 后需重新 start 才能听下一句，隔一拍再 start 避免同步重入
  scheduleGenRestart() {
    const that = this;
    if (this._genVoiceRestartTimer) return;
    this._genVoiceRestartTimer = setTimeout(function () {
      that._genVoiceRestartTimer = null;
      if (!that._voiceActive || !isAsrAvailable()) return;
      startAsr({ lang: 'zh_CN' });
    }, 400);
  },

  teardownGenVoice() {
    this._voiceActive = false;
    if (this._genVoiceRestartTimer) {
      try { clearTimeout(this._genVoiceRestartTimer); } catch (e) {}
      this._genVoiceRestartTimer = null;
    }
    stopAsr();
  },

  // 手动兜底：镜腿手势/仿真按钮唤起——未常听则开常听，已常听则补一次 start 自救
  onVoiceCommand() {
    if (!isAsrAvailable()) {
      this.setData({ hint: '当前设备不支持语音输入' });
      speak('当前设备不支持语音输入');
      return;
    }
    this.setData({ hint: '请说：开始 / 换成XX风格 / 发手机 / 返回' });
    if (!this._voiceActive) { this.setupGenVoice(); return; }
    this.scheduleGenRestart();
  },

  // 按语音指令分派动作（结合当前流程阶段）
  dispatchVoice(cmd, rawText) {
    switch (cmd.action) {
      case 'back': this.goBackHome(); break;
      case 'shoot': this.startFlow(); break;
      case 'send':
        if (this.data.hasResultImage && this.data.resultImageSrc) this.doPush(this.data.resultImageSrc);
        else { this.setData({ hint: '还没有可发送的图片，请先生成' }); speak('还没有可发送的图片'); }
        break;
      case 'regen': this.regenWithStyle(this.data.lastStyle || ''); break;
      case 'restyle': this.regenWithStyle(cmd.style || rawText); break;
      default: this.setData({ hint: '没听清，请再说一次' }); speak('没听清');
    }
  },

  // 语音扩写改风格：复用照片描述缓存（baseDesc）直接文生图，免再拍/再描述
  regenWithStyle(styleText) {
    if (this._running) return;
    if (!this.data.baseDesc && !this.data.lastShotBase64) {
      this.setData({ caption: '请先拍照生成一张图', hint: '短按或说「开始」', captionClass: 'warn' });
      speak('请先拍照生成一张图');
      return;
    }
    this._running = true;
    this.data.lastStyle = styleText || '';
    this.setData({ lastStyleText: styleText || '', showQr: false, hasResultImage: false, hasDemoNotice: false, hasPushNote: false });
    // 有描述缓存 → 传 null 走 baseDesc；否则回退到原照片 base64
    const src = this.data.baseDesc ? null : this.data.lastShotBase64;
    this.doGenerate(src, styleText || '');
  },

  // ====== 设置面板：图像生成 apiKey / relay 地址 ======

  toggleSettings() {
    this.setData({ showSettings: !this.data.showSettings });
  },

  onGenApiKeyInput(e) {
    this._genApiKeyDraft = (e && e.detail && e.detail.value) || '';
  },

  onRelayBaseInput(e) {
    this._relayBaseDraft = (e && e.detail && e.detail.value) || '';
  },

  saveGenApiKey() {
    const key = (this._genApiKeyDraft || '').trim();
    if (!key) {
      this.setData({ hint: '生成模型密钥不能为空' });
      speak('密钥不能为空');
      return;
    }
    setImagegenConfig({ apiKey: key });
    this.refreshGenBadge();
    this.refreshMasks();
    this.setData({ hint: '已保存生成模型密钥，现在可获得真实生成' });
    speak('已保存密钥');
    try { wx.showToast({ title: '已保存', icon: 'success', duration: 1200 }); } catch (e) {}
  },

  clearGenApiKey() {
    setImagegenConfig({ apiKey: '' });
    this.refreshGenBadge();
    this.refreshMasks();
    this.setData({ hint: '已清除生成模型密钥，回到演示模式' });
    speak('已清除密钥');
  },

  saveRelayBase() {
    const base = (this._relayBaseDraft || '').trim();
    if (!base) {
      this.setData({ hint: 'relay 地址不能为空' });
      speak('地址不能为空');
      return;
    }
    setRelayBase(base);
    this.refreshRelayBadge();
    this.refreshMasks();
    this.setData({ hint: '已保存 relay 地址' });
    speak('已保存地址');
    try { wx.showToast({ title: '已保存', icon: 'success', duration: 1200 }); } catch (e) {}
  },

  // 相机组件报错（无权限/被占用）：降级为演示拍照，不卡死
  onCameraError(e) {
    console.log('[genimg] 相机组件报错: ' + JSON.stringify(e && e.detail));
    this.setData({ cameraReady: false, hint: '相机不可用，已切换为演示拍照' });
    speak('相机不可用，切换为演示拍照');
  },

  // ====== 导航与手势 ======

  goBackHome() { this.teardownGenVoice(); safeBack(); },

  onKeyDown(event) {
    this._lastFrameworkKey = Date.now();
    routeKeyEvent(this, event, 'down');
  },
  onKeyUp(event) {
    if (!event) return;
    routeKeyEvent(this, event, 'up');
  },

  // 短按：intro（含失败重试态）=开始整套流程；result=返回主页；生成/推送中不响应，避免打断
  handleTap() {
    const step = this.data.wizardStep;
    if (step === 'intro') { this.startFlow(); return; }
    if (step === 'result') { this.goBackHome(); return; }
  },

  // 双击：result=再来一组；其余=直接退出
  handleDoubleTap() {
    if (this.data.wizardStep === 'result') { this.resetAll(); return; }
    this.teardownGenVoice();
    safeBack();
  },

  // 滑动：前/上滑 → 设置面板；后/下滑 → 唤起/自救语音聆听（眼镜无触屏时的语音入口兜底）
  handleSwipe(direction) {
    if (direction === 'up' || direction === 'left') { this.toggleSettings(); return; }
    this.onVoiceCommand();
  }
}
</script>

<page>
  <view class="container">
    <view class="header-row">
      <view class="back-btn" bindtap="goBackHome">
        <text class="back-btn-text">← 返回主页</text>
      </view>
      <text class="title">生成相似图</text>
    </view>

    <view class="badge-row" bindtap="toggleSettings">
      <view class="mode-badge {{genBadgeClass}}">
        <text>{{genModeText}}</text>
      </view>
      <view class="mode-badge {{relayBadgeClass}}">
        <text>{{relayModeText}}</text>
      </view>
    </view>

    <!-- 设置面板：图像生成 apiKey + relay 地址 -->
    <view class="settings-panel" wx:if="{{showSettings}}">
      <text class="st-title">图像生成模型设置</text>
      <text class="st-line">当前密钥：{{genApiKeyMasked}}</text>
      <input class="st-input" type="text" password="{{true}}" placeholder="粘贴图像生成 API Key" bindinput="onGenApiKeyInput" />
      <view class="st-btns">
        <button class="st-save" bindtap="saveGenApiKey"><text>保存密钥</text></button>
        <button class="st-clear" bindtap="clearGenApiKey"><text>清除</text></button>
      </view>
      <text class="st-note">未填写时为演示模式；填入后拍照内容将由真实图像生成模型处理。</text>

      <text class="st-title">Relay 中转服务设置</text>
      <text class="st-line">当前地址：{{relayBaseDisplay}}</text>
      <input class="st-input" type="text" placeholder="https://your-relay.example.com" bindinput="onRelayBaseInput" />
      <view class="st-btns">
        <button class="st-save" bindtap="saveRelayBase"><text>保存地址</text></button>
      </view>
      <text class="st-note">relay 是需要另外部署的云端中转服务（见项目文档 §5.3），未配置时无法推送到手机。</text>
    </view>

    <!-- 主字幕 -->
    <view class="caption-card {{captionClass}}">
      <text class="caption">{{caption}}</text>
      <text class="hint" wx:if="{{hint}}">{{hint}}</text>
    </view>

    <!-- 拍摄取景（shooting 阶段） -->
    <view class="camera-box" wx:if="{{wizardStep === 'shooting' && cameraReady}}">
      <camera class="camera" device-position="back" flash="off" binderror="onCameraError"></camera>
    </view>
    <view class="camera-fallback" wx:if="{{wizardStep === 'shooting' && !cameraReady}}">
      <text class="fallback-text">当前环境无相机，进入演示拍照</text>
    </view>

    <!-- 生成/推送中的进度提示 -->
    <view class="progress-box" wx:if="{{wizardStep === 'generating' || wizardStep === 'pushing'}}">
      <text class="progress-text">请稍候…</text>
    </view>

    <!-- 结果区 -->
    <view class="result-card" wx:if="{{wizardStep === 'result'}}">
      <image class="result-thumb" src="{{resultImageSrc}}" mode="aspectFit" wx:if="{{hasResultImage}}"></image>

      <view class="demo-notice" wx:if="{{hasDemoNotice}}">
        <text class="demo-notice-text">{{demoNotice}}</text>
      </view>

      <view class="pickup-box" wx:if="{{showQr}}">
        <image class="qr-image" src="{{qrSrc}}" mode="aspectFit"></image>
        <text class="pickup-label">取件码</text>
        <text class="pickup-code">{{codeSpaced}}</text>
        <text class="pickup-tip">手机扫码，或打开 relay 页面输入取件码查看</text>
      </view>

      <view class="push-note" wx:if="{{hasPushNote}}">
        <text class="push-note-text">{{pushNoteText}}</text>
      </view>

      <button class="op-btn voice" bindtap="onVoiceCommand">
        <text class="op-main">语音改风格 / 指令</text>
        <text class="op-sub">说「换成夜景 / 卡通 / 水彩风格」重做，或「发手机」「返回」</text>
      </button>
      <view class="result-ops">
        <button class="op-btn again" bindtap="resetAll"><text class="op-main">再拍一张</text></button>
        <button class="op-btn home" bindtap="goBackHome"><text class="op-main">返回主页</text></button>
      </view>
    </view>

    <!-- 起始操作 -->
    <view class="intro-ops" wx:if="{{wizardStep === 'intro'}}">
      <button class="op-btn start" bindtap="startFlow">
        <text class="op-main">开始</text>
        <text class="op-sub">拍照 → 生成相似图 → 发到手机</text>
      </button>
      <button class="op-btn voice" bindtap="onVoiceCommand">
        <text class="op-main">语音指令</text>
        <text class="op-sub">说「开始」「换成水彩风格」「发手机」等</text>
      </button>
    </view>

    <text class="gesture-hint">短按：开始 / 返回主页 ｜「语音指令」按钮：全程语音控制、语音改风格 ｜ 滑动：设置 ｜ 双击：再来或退出</text>

    <view class="sim-tap" bindtap="handleTap" bindlongpress="handleDoubleTap">
      <text class="sim-tap-text">仿真操作：点此=短按（开始 / 返回）｜ 长按此区域=再来一组或退出</text>
    </view>
  </view>
</page>

<style>
.container {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  padding: 14px;
  background-color: #000000;
  height: 100%;
  box-sizing: border-box;
}

.header-row {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 8px;
}

.back-btn {
  padding: 6px 12px;
  background-color: rgba(64, 255, 94, 0.15);
  border: 1px solid #40FF5E;
  border-radius: 16px;
}
.back-btn:active { background-color: rgba(64, 255, 94, 0.35); }
.back-btn-text { font-size: 14px; font-weight: bold; color: #40FF5E; }

.title { font-size: 24px; font-weight: bold; color: #40FF5E; }

.badge-row {
  display: flex;
  flex-direction: row;
  gap: 8px;
  margin-bottom: 8px;
}
.mode-badge {
  font-size: 12px;
  font-weight: bold;
  padding: 4px 10px;
  border-radius: 12px;
  border: 1px solid;
}
.mode-badge.live { color: #000000; background-color: #40FF5E; border-color: #40FF5E; }
.mode-badge.demo { color: #FFB000; background-color: rgba(255, 176, 0, 0.1); border-color: #FFB000; }

.settings-panel {
  background-color: #0d1a0d;
  border: 2px solid #40FF5E;
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 10px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.st-title { font-size: 16px; font-weight: bold; color: #7DFF90; margin-top: 6px; }
.st-line { font-size: 13px; color: #CFFFD8; }
.st-input {
  background-color: #001400;
  border: 1px solid #40FF5E;
  border-radius: 8px;
  padding: 10px;
  color: #FFFFFF;
  font-size: 15px;
}
.st-btns { display: flex; flex-direction: row; gap: 8px; }
.st-save { flex: 1; background-color: #40FF5E; border: none; border-radius: 8px; padding: 10px; }
.st-save text { color: #000000; font-weight: bold; font-size: 15px; }
.st-clear { flex: 0 0 auto; background-color: transparent; border: 1px solid #FF4040; border-radius: 8px; padding: 10px 16px; }
.st-clear text { color: #FF4040; font-size: 14px; }
.st-note { font-size: 12px; color: #FFC93C; line-height: 1.4; }

.caption-card {
  background-color: #0d1a0d;
  border: 2px solid #40FF5E;
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 10px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}
.caption-card.ok { border-color: #40FF5E; }
.caption-card.warn { border-color: #FFB000; background-color: rgba(255, 176, 0, 0.08); }
.caption-card.error { border-color: #FF4040; background-color: rgba(255, 64, 64, 0.08); }

.caption {
  font-size: 22px;
  font-weight: bold;
  color: #7DFF90;
  text-align: center;
  line-height: 1.35;
  text-shadow: 0 0 8px rgba(64, 255, 94, 0.7);
}
.caption-card.warn .caption { color: #FFC93C; text-shadow: 0 0 8px rgba(255, 176, 0, 0.5); }
.caption-card.error .caption { color: #FF8080; text-shadow: 0 0 8px rgba(255, 64, 64, 0.5); }
.hint { font-size: 15px; color: #CFFFD8; text-align: center; line-height: 1.4; }

.camera-box {
  position: relative;
  width: 100%;
  height: 160px;
  border: 2px solid #40FF5E;
  border-radius: 12px;
  overflow: hidden;
  margin-bottom: 10px;
}
.camera { width: 100%; height: 100%; }

.camera-fallback {
  width: 100%;
  padding: 20px;
  background-color: #1a1a1a;
  border: 2px dashed #FFB000;
  border-radius: 12px;
  text-align: center;
  margin-bottom: 10px;
  box-sizing: border-box;
}
.fallback-text { font-size: 15px; color: #FFC93C; }

.progress-box {
  width: 100%;
  padding: 24px;
  text-align: center;
  margin-bottom: 10px;
}
.progress-text { font-size: 18px; color: #7DFF90; }

.result-card {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  margin-bottom: 10px;
}
.result-thumb {
  width: 100%;
  height: 160px;
  border-radius: 12px;
  border: 2px solid #40FF5E;
  background-color: #111111;
}

.demo-notice {
  width: 100%;
  background-color: rgba(255, 176, 0, 0.1);
  border: 2px dashed #FFB000;
  border-radius: 12px;
  padding: 12px;
  box-sizing: border-box;
}
.demo-notice-text { font-size: 16px; color: #FFC93C; line-height: 1.5; }

.pickup-box {
  width: 100%;
  background-color: #0d1a0d;
  border: 2px solid #40FF5E;
  border-radius: 12px;
  padding: 14px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  box-sizing: border-box;
}
.qr-image {
  width: 140px;
  height: 140px;
  border-radius: 8px;
  background-color: #FFFFFF;
}
.pickup-label { font-size: 14px; color: #CFFFD8; }
.pickup-code {
  font-size: 36px;
  font-weight: bold;
  color: #40FF5E;
  letter-spacing: 4px;
  text-shadow: 0 0 10px rgba(64, 255, 94, 0.7);
}
.pickup-tip { font-size: 13px; color: rgba(207, 255, 216, 0.8); text-align: center; }

.push-note {
  width: 100%;
  background-color: rgba(255, 64, 64, 0.08);
  border: 2px dashed #FF4040;
  border-radius: 12px;
  padding: 12px;
  box-sizing: border-box;
}
.push-note-text { font-size: 14px; color: #FF8080; line-height: 1.5; word-break: break-all; }

.intro-ops, .result-ops {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 10px;
}
.result-ops { flex-direction: row; }
.result-ops .op-btn { flex: 1; }

.op-btn {
  padding: 12px;
  border-radius: 12px;
  border: 3px solid #40FF5E;
  background-color: transparent;
  display: flex;
  flex-direction: column;
  align-items: center;
}
.op-main { font-size: 19px; font-weight: bold; color: #7DFF90; }
.op-sub { font-size: 12px; color: rgba(207, 255, 216, 0.8); margin-top: 2px; }

.op-btn.start { background-color: #40FF5E; border-color: #40FF5E; }
.op-btn.start .op-main, .op-btn.start .op-sub { color: #000000; }
.op-btn.voice { background-color: rgba(64, 212, 255, 0.12); border-color: #40D4FF; }
.op-btn.voice .op-main { color: #9FE9FF; }
.op-btn.voice .op-sub { color: rgba(159, 233, 255, 0.85); }
.op-btn.again, .op-btn.home { border-color: rgba(64, 255, 94, 0.5); }

.listening-bar {
  width: 100%;
  padding: 10px;
  margin-bottom: 10px;
  box-sizing: border-box;
  background-color: rgba(64, 212, 255, 0.12);
  border: 2px solid #40D4FF;
  border-radius: 12px;
  text-align: center;
}
.listening-text { font-size: 16px; font-weight: bold; color: #9FE9FF; }

.style-bar {
  width: 100%;
  padding: 8px 12px;
  margin-bottom: 10px;
  box-sizing: border-box;
  background-color: rgba(64, 255, 94, 0.08);
  border-radius: 10px;
}
.style-text { font-size: 14px; color: #CFFFD8; }

.gesture-hint {
  font-size: 13px;
  color: #C4C4C4;
  text-align: center;
  line-height: 1.4;
  margin-bottom: 8px;
}

.sim-tap {
  width: 100%;
  padding: 14px;
  background-color: rgba(64, 255, 94, 0.12);
  border: 2px dashed #40FF5E;
  border-radius: 12px;
  text-align: center;
  box-sizing: border-box;
}
.sim-tap:active { background-color: rgba(64, 255, 94, 0.28); }
.sim-tap-text { font-size: 14px; font-weight: bold; color: #7DFF90; }
</style>
