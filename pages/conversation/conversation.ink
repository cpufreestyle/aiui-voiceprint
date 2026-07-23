<script def>
{
  "navigationBarTitleText": "对话字幕 - 无障碍版",
  "description": "实时对话字幕页面 - 为听障人士优化：持续聆听对话，用声纹识别说话人并在字幕前标注姓名；未识别者显示「陌生人N」并支持现场起名入库。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "isListening": {
          "type": "boolean",
          "description": "是否正在持续聆听"
        },
        "statusText": {
          "type": "string",
          "description": "状态提示文字"
        },
        "showAsrNotice": {
          "type": "boolean",
          "description": "是否显示 ASR 演示提示条"
        },
        "subtitles": {
          "type": "array",
          "description": "字幕列表，按时间正序，最新在底部",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "number", "description": "字幕序号" },
              "speaker": { "type": "string", "description": "说话人名称" },
              "text": { "type": "string", "description": "识别到的文字" },
              "isKnown": { "type": "boolean", "description": "是否为已录入/已起名的人" }
            }
          }
        },
        "waveformData": {
          "type": "array",
          "description": "实时波形数据数组",
          "items": { "type": "number" }
        }
      },
      "required": ["isListening", "statusText", "showAsrNotice", "subtitles", "waveformData"]
    }
  }
}
</script>

<script setup>
import wx from 'wx';
import { routeKeyEvent, installKeyboardFallback, removeKeyboardFallback, safeBack } from '../../utils/gesture.js';
import { acquireRecorderManager, probeRecordingApis } from '../../utils/recorder.js';
import { extractFeatures, createTemplate, identifySpeaker, combineFrames, generateWaveform } from '../../utils/voiceprint-engine.js';
import { initAsr, startAsr, stopAsr, takeLatestText, asrMode, isAsrAvailable } from '../../utils/asr.js';
import { speak, toggleVoicePrompt, isVoicePromptOn } from '../../utils/tts.js';

// 录音有效性门槛（与注册页/验证页一致）：低于此值视为「没采到有效音频」，
// 不建模、不入库、不参与识别，避免静音/太短坏样本污染共享的 voiceprint_db。
const MIN_AUDIO_BYTES = 1600;
const MIN_ENERGY = 1e-6;

export default {
  data: {
    isListening: false,
    // 预计算：状态栏样式类（避免模板三元式告警）
    statusBarClass: '',
    statusText: '点击开始聆听对话',
    showAsrNotice: true,
    // ASR 模式标识：rokid=真实 Rokid 识别，demo=仿真回退
    asrModeText: '演示模式',
    // 预计算：ASR 模式徽章样式类
    modeBadgeClass: 'demo',
    // 可配置项
    recDuration: 3000,
    asrLang: 'zh_CN',
    langOptions: ['zh_CN', 'en_US', 'yue'],
    durationOptions: [2000, 3000, 5000],
    showSettings: false,
    voicePromptOn: true,
    // 预计算：语音提示开关文案
    voicePromptText: '开（点击关闭）',
    subtitles: [],
    waveformData: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    recorderManager: null,
    segmentBuffers: [],
    recordingPath: null,
    // 本次会话内未识别说话人（陌生人）的暂存表：key -> { label, signature }
    unknownSpeakers: [],
    lastUnknownKey: null,
    strangerCount: 0,
    subtitleSeq: 0,
    // 調試：最近一次收到的按鍵碼（便於在無控制台的設備上確認返回手勢的 code）
    debugKey: ''
  },

  onLoad(query) {
    // 初始化 Rokid 语音识别器（无该能力时自动回退演示文本）
    initAsr({});
    this.refreshAsrMode();
    this.setData({
      voicePromptOn: isVoicePromptOn(),
      voicePromptText: isVoicePromptOn() ? '开（点击关闭）' : '关（点击开启）'
    });
    this.initRecorder();

    // 语音直呼：app.js 跳转 URL 为 ?mode=caption&autoStart=1，落页应自动开始聆听；
    // redirectTo 个别固件丢参时兜底读 globalData.launchIntent（对齐 media/genimg 页范式）。
    const q = query || {};
    let autoStart = q.autoStart === '1';
    if (!autoStart) {
      try {
        const app = getApp();
        const li = app && app.globalData && app.globalData.launchIntent;
        if (li && li.route && li.route.mode === 'caption') autoStart = true;
      } catch (e) {}
    }
    this._pendingAutoStart = autoStart;
  },

  // 语音直呼落地后自动开始聆听：留一拍给渲染/录音器就绪，复用现有 startListening（不新写聆听逻辑）
  onReady() {
    if (this._pendingAutoStart) {
      this._pendingAutoStart = false;
      const that = this;
      setTimeout(function () {
        if (!that.data.isListening) that.startListening();
      }, 300);
    }
  },

  // 安全初始化录音管理器：不同运行时 API 位置不同（wx.getRecorderManager / wx.media.getRecorderManager），
  // 拿不到时置空并打标记，绝不在 onLoad 抛错（否则会中断页面初始化，导致按键/返回全失效）。
  initRecorder() {
    this.recorderManager = acquireRecorderManager();
    this.recorderAvailable = !!this.recorderManager;
    // 诊断：列出本运行时实际提供的录音/语音接口，便于确认真机能力或发现非常规 API
    console.log('[conversation] 可用录音/语音接口: ' + JSON.stringify(probeRecordingApis()));
    if (!this.recorderManager) {
      console.log('[conversation] 当前运行时无录音能力，进入演示模式（合成音频驱动流水线）');
    }
    this.setupRecorderListeners();
  },

  onShow() {
    installKeyboardFallback(this);
    // 平台契约：语音唤醒后，当前 Interactive InkView 须在 2 秒内“开启 ASR”，
    // 否则报“语音唤醒已超时，Interactive InkView 未在 2 秒内开启 ASR”。
    // 对话字幕页作为活动视图，一旦可见/被唤醒激活就立即开启 ASR，满足契约。
    this.ensureAsrOpen();
  },

  onHide() {
    removeKeyboardFallback(this);
  },

  // 刷新 ASR 模式标识（真实 / 演示）
  refreshAsrMode() {
    const isRokid = asrMode() === 'rokid';
    this.setData({
      asrModeText: isRokid ? 'Rokid ASR' : '演示模式',
      modeBadgeClass: isRokid ? 'real' : 'demo'
    });
  },

  // 确保语音识别器已“开启”（平台要求 Interactive InkView 在唤醒后 2 秒内开启 ASR）。
  // 仅在有真实 ASR 能力（wx.getSpeechRecognizer）时生效；演示模式无该接口则为空操作。
  // 用 _asrStarted 防重复 start：重复开启识别器在部分真机/仿真上会卡死麦克风。
  ensureAsrOpen() {
    try {
      if (!isAsrAvailable()) {
        console.log('[conversation] 无 ASR 能力（演示模式），无法开启 ASR');
        return;
      }
      if (this._asrStarted) {
        console.log('[conversation] ASR 已开启，跳过重复 start');
        return;
      }
      initAsr({});
      startAsr({ lang: this.data.asrLang });
      this._asrStarted = true;
      console.log('[conversation] 已开启 ASR（满足平台 2 秒唤醒契约）');
    } catch (e) {
      console.log('[conversation] 开启 ASR 失败: ' + (e && e.message ? e.message : e));
    }
  },

  // 切换识别语言
  cycleLang() {
    const opts = this.data.langOptions;
    const idx = opts.indexOf(this.data.asrLang);
    const next = opts[(idx + 1) % opts.length];
    this.setData({ asrLang: next });
  },

  // 切换录音时长
  cycleDuration() {
    const opts = this.data.durationOptions;
    const idx = opts.indexOf(this.data.recDuration);
    const next = opts[(idx + 1) % opts.length];
    this.setData({ recDuration: next });
  },

  // 展开/收起设置
  toggleSettings() {
    this.setData({ showSettings: !this.data.showSettings });
  },

  // 切换语音提示开关
  toggleVoicePromptSetting() {
    const on = toggleVoicePrompt();
    this.setData({
      voicePromptOn: on,
      voicePromptText: on ? '开（点击关闭）' : '关（点击开启）'
    });
    if (on) speak('语音提示已开启');
  },

  onUnload() {
    this.stopListening();
    this.teardownPausedVoice();
    this._asrStarted = false;
    stopAsr();
    if (this.recorderManager) {
      this.recorderManager.offFrameRecorded();
      this.recorderManager.offStop();
    }
    // 释放 window 级键盘兜底监听（redirectTo/navigateBack 走 onUnload，不一定触发 onHide）
    removeKeyboardFallback(this);
  },

  setupRecorderListeners() {
    if (!this.recorderManager) return;
    const that = this;

    // 实时波形（节流 + 异常保护，避免每帧 setData 拖垮主线程导致黑屏）
    this.recorderManager.onFrameRecorded(function (res) {
      try {
        const frameBuffer = res.frameBuffer;
        if (frameBuffer) {
          that.data.segmentBuffers.push(frameBuffer);
          const nowt = Date.now();
          if (nowt - (that._lastWaveT || 0) > 120) {
            that._lastWaveT = nowt;
            that.setData({ waveformData: generateWaveform(frameBuffer) });
          }
        }
      } catch (e) {
        console.log('波形更新失败: ' + e);
      }
    });

    // 每段录音结束：处理这一句（说话人识别 + 字幕）
    this.recorderManager.onStop(function () {
      that._clearTimer(that._watchdog);
      try {
        const buffers = that.data.segmentBuffers;
        that.data.segmentBuffers = [];
        const combined = buffers && buffers.length ? combineFrames(buffers) : null;
        that.processSegment(combined);
      } catch (e) {
        console.log('处理语音段失败: ' + e);
        that.setData({ statusText: '本句识别出错，继续聆听' });
        speak('本句识别出错');
      }

      // 收尾本段识别器，避免与下一段叠加导致设备卡死
      that._asrStarted = false;
      stopAsr();

      // 持续聆听：若仍在监听，自动开始下一段
      if (that.data.isListening) {
        setTimeout(function () {
          try {
            that.startRecordingSegment();
          } catch (e) {
            console.log('重启录音失败: ' + e);
            that.data._recording = false;
            that.setData({ statusText: '重启录音失败', isListening: false, statusBarClass: '' });
            speak('重启录音失败');
          }
        }, 300);
      }
    });

    // 录音异常兜底：避免设备录音出错后页面卡死、无法退出
    this.recorderManager.onError(function (err) {
      console.log('录音出错: ' + err);
      that.data._recording = false;
      that._clearTimer(that._watchdog);
      that.setData({ statusText: '录音出错，已停止', isListening: false, statusBarClass: '' });
      speak('录音出错，已停止');
    });
  },

  // 开始 / 暂停聆听
  toggleListening() {
    if (this.data.isListening) {
      this.stopListening();
    } else {
      this.startListening();
    }
  },

  startListening() {
    const that = this;
    // 从暂停态命令常听切回字幕流：先释放命令 ASR handlers，再确保字幕识别器已开
    // （暂停时被 stopAsr 关过；_asrStarted 此时为 false，ensureAsrOpen 会真正重开并重置 handlers 为空）
    this.teardownPausedVoice();
    this.ensureAsrOpen();
    this.setData({
      isListening: true,
      statusBarClass: 'listening',
      statusText: '聆听中 - 正在识别说话人',
      waveformData: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    });
    speak('开始聆听');
    this.startRecordingSegment();
  },

  // 安全清除定时器：ink-script(Rust) 运行时里 clearTimeout/clearInterval 期望 i32 句柄，
  // 传 undefined 会抛 “converting from js 'undefined' into type 'i32'”。有值才清。
  _clearTimer(id) {
    if (id != null) { try { clearTimeout(id); } catch (e) {} }
  },
  _clearInterval(id) {
    if (id != null) { try { clearInterval(id); } catch (e) {} }
  },

  stopListening() {
    this._asrStarted = false;
    stopAsr();
    this._clearTimer(this._watchdog);
    this._clearTimer(this._noRecTimer);
    this._clearInterval(this._demoWaveTimer);
    if (this.recorderManager) {
      try { this.recorderManager.stop(); } catch (e) {}
    }
    this.data._recording = false;
    this.setData({ isListening: false, statusBarClass: '', statusText: '已暂停聆听' });
    speak('已暂停聆听');
  },

  startRecordingSegment() {
    const that = this;
    // 防止上一段尚未结束就重复 start，造成设备录音卡死
    if (that.data._recording) return;
    // 无录音能力（仿真/无麦克风权限）：用合成音频驱动完整流水线（波形→声纹→字幕），
    // 让页面在仿真器里“像在录音”一样可用，且返回键正常。
    if (!that.recorderManager) {
      that.startDemoSegment();
      return;
    }
    that.data._recording = true;
    that.data.segmentBuffers = [];
    try {
      // 同步启动 Rokid 语音识别器（与录音同窗口，结束由 stopAsr 收尾）。
      // 复用 ensureAsrOpen：若 onShow 已开启则跳过，避免重复 start 卡死麦克风。
      that.ensureAsrOpen();
      that.recorderManager.start({
        duration: that.data.recDuration,
        sampleRate: 16000,
        numberOfChannels: 1,
        encodeBitRate: 48000,
        format: 'pcm'
      });
    } catch (e) {
      that.data._recording = false;
      console.log('启动录音失败: ' + e);
      that.setData({ statusText: '启动录音失败，已停止', isListening: false, statusBarClass: '' });
      speak('启动录音失败');
      return;
    }
    // 卡死看门狗：若本段录音未在预期时间内结束（onStop 未触发），语音提示并强制收尾
    that._clearTimer(that._watchdog);
    that._watchdog = setTimeout(function () {
      if (that.data._recording) {
        console.log('录音无响应，强制收尾');
        that.data._recording = false;
        that._asrStarted = false;
        stopAsr();
        try { that.recorderManager.stop(); } catch (e) {}
        that.setData({ statusText: '录音无响应，已停止', isListening: false, statusBarClass: '' });
        speak('录音没有响应，已停止');
      }
    }, that.data.recDuration + 2500);
  },

  // 仿真无麦克风时：合成“说话人音频”驱动整条流水线，使字幕页在仿真器里功能完整。
  // 轮换 3 个稳定音色（seed）让声纹能聚成不同陌生人，演示说话人标注效果。
  startDemoSegment() {
    const that = this;
    if (that.data._recording) return;
    that.data._recording = true;
    that._clearTimer(that._noRecTimer);
    that._clearInterval(that._demoWaveTimer);

    // 波形动画：段内持续跳动，模拟正在录音
    that._demoWaveTimer = setInterval(function () {
      if (!that.data.isListening) { clearInterval(that._demoWaveTimer); that._demoWaveTimer = null; return; }
      const pts = [];
      for (let i = 0; i < 20; i++) {
        pts.push(Math.round(40 + 55 * Math.abs(Math.sin(Date.now() / 130 + i * 0.6))));
      }
      that.setData({ waveformData: pts });
    }, 120);

    // 段结束：合成音频 → 走与真机完全相同的 processSegment（声纹识别 + 字幕）
    that._noRecTimer = setTimeout(function () {
      clearInterval(that._demoWaveTimer);
      that._demoWaveTimer = null;
      that.data._recording = false;
      that.data._demoSpeaker = ((that.data._demoSpeaker || 0) + 1) % 3;
      const audio = that.makeSyntheticSegment(that.data._demoSpeaker);
      try {
        that.processSegment(audio);
      } catch (e) {
        console.log('[conversation] 演示段处理失败: ' + e);
      }
      if (that.data.isListening) {
        setTimeout(function () { try { that.startRecordingSegment(); } catch (e) {} }, 300);
      }
    }, that.data.recDuration || 3000);
  },

  // 生成一段种子稳定的伪 PCM（Uint8Array，8-bit），使同一 seed 的特征稳定 → 稳定陌生人聚类。
  makeSyntheticSegment(seed) {
    const len = 16000; // 1 秒 @16k 采样
    const buf = new Uint8Array(len);
    const base = 96 + seed * 24;
    const freq = 0.018 + seed * 0.011;
    for (let i = 0; i < len; i++) {
      const v = base + 56 * Math.sin(i * freq + seed * 1.3) + 22 * Math.sin(i * freq * 3.1 + seed);
      buf[i] = Math.max(0, Math.min(255, Math.round(v)));
    }
    return buf;
  },

  // 处理一句语音：声纹识别说话人 + ASR 转写文字 + 生成字幕
  processSegment(audio) {
    const that = this;
    that.data._recording = false;
    // 1) 说话人识别（声纹）
    let speakerLabel = '陌生人1';
    let isKnown = false;
    let unknownKey = null;

    // 无效录音门槛（与注册/验证页一致）：太短或静音的音频不做声纹身份，
    // 避免全 0 特征建出假陌生人、更避免被起名入库污染共享声纹库。
    const longEnough = audio && audio.length >= MIN_AUDIO_BYTES;
    if (longEnough) {
      let features = null;
      try { features = extractFeatures(audio); } catch (e) { console.log('提取特征失败: ' + e); }

      // 静音/能量过低：丢弃该段声纹身份（不建陌生人、不可起名），字幕仍照常显示文字
      if (!features || !(features.meanEnergy > MIN_ENERGY)) {
        features = null;
      }

      const db = wx.getStorageSync('voiceprint_db') || { users: [] };
      if (features && db.users && db.users.length) {
        let candidates = [];
        try {
          candidates = identifySpeaker(features, db.users);
        } catch (e) {
          console.log('声纹识别失败: ' + e);
          candidates = [];
        }
        const top = candidates[0];
        if (top && top.matched) {
          speakerLabel = top.name;
          isKnown = true;
        } else {
          // 未匹配：在本次会话的陌生人表中查找稳定身份，否则新建
          unknownKey = that.findOrCreateUnknown(features, top);
          speakerLabel = that.getUnknownLabel(unknownKey);
          that.data.lastUnknownKey = unknownKey;
        }
      } else if (features) {
        // 库里还没有人：直接记为陌生人
        unknownKey = that.findOrCreateUnknown(features, null);
        speakerLabel = that.getUnknownLabel(unknownKey);
        that.data.lastUnknownKey = unknownKey;
      }
    }

    // 2) 文字：取自 Rokid 语音识别器本窗口的识别结果（无该能力时回退占位文本）
    const text = takeLatestText() || '（未识别到文字）';
    // 语音指令截获：整句即命令（严格短句）时执行动作、不进字幕，避免误吞正常对话
    if (that.handleCaptionVoiceCommand(text)) return;
    that.appendSubtitle(speakerLabel, isKnown, unknownKey, text);
  },

  // 追加一条字幕（说话人 + 文字对应）
  appendSubtitle(speakerLabel, isKnown, unknownKey, text) {
    const that = this;
    const seq = that.data.subtitleSeq + 1;
    that.data.subtitleSeq = seq;
    const newSub = {
      id: seq,
      key: unknownKey || ('known_' + speakerLabel),
      speaker: speakerLabel,
      text: text,
      isKnown: isKnown
    };
    const subs = that.data.subtitles.concat([newSub]);
    // 最多保留 30 条，避免无限增长
    const trimmed = subs.length > 30 ? subs.slice(subs.length - 30) : subs;
    that.setData({
      subtitles: trimmed,
      statusText: isKnown ? ('已识别：' + speakerLabel) : ('未识别 - ' + speakerLabel + '（短按可起名）')
    });

    // 振动反馈
    const app = getApp();
    if (app && app.globalData && app.globalData.vibrationEnabled) {
      wx.vibrateShort();
    }
  },

  // 根据特征在本次会话陌生人表中匹配/新建稳定身份
  findOrCreateUnknown(features, topCandidate) {
    const sig = this.signatureOf(features);
    for (const u of this.data.unknownSpeakers) {
      if (Math.abs(u.signature.energy - sig.energy) < 0.003 &&
          Math.abs(u.signature.centroid - sig.centroid) < 3) {
        return u.key;
      }
    }
    const count = this.data.unknownSpeakers.length + 1;
    const key = 'unknown_' + Date.now() + '_' + count;
    this.data.unknownSpeakers.push({ key: key, label: '陌生人' + count, signature: sig, features: features });
    return key;
  },

  getUnknownLabel(key) {
    const u = this.data.unknownSpeakers.find((x) => x.key === key);
    return u ? u.label : '陌生人';
  },

  signatureOf(features) {
    return {
      energy: Math.round(features.meanEnergy * 1000) / 1000,
      centroid: Math.round(features.spectralCentroid * 10) / 10
    };
  },

  // 现场给最近一位陌生人起名，并入库（作为声纹，供后续识别）
  nameLastUnknown() {
    const that = this;
    const key = that.data.lastUnknownKey;
    if (!key) {
      wx.showToast({ title: '暂无可起名的陌生人', icon: 'none', duration: 1500 });
      return;
    }
    const unknown = that.data.unknownSpeakers.find((x) => x.key === key);
    if (!unknown) return;

    wx.showModal({
      title: '为说话人起名',
      editable: true,
      placeholderText: '输入姓名，如：小李',
      success(res) {
        if (!res.confirm) return;
        const name = (res.content || '').trim();
        if (!name) {
          wx.showToast({ title: '名字不能为空', icon: 'none', duration: 1500 });
          return;
        }
        that.persistUnknown(key, name);
      }
    });
  },

  persistUnknown(key, name) {
    const that = this;
    const unknown = that.data.unknownSpeakers.find((x) => x.key === key);
    if (!unknown) return;

    // 0) 入库前校验（与注册页一致）：特征无效或模板生成失败则中止入库——
    //    绝不把 template:null / 静音退化模板写进共享声纹库，否则表现为
    //    「起名成功却永远识别不了」，还会污染 verify 页的比对。
    const f = unknown.features;
    if (!f || !(f.meanEnergy > MIN_ENERGY)) {
      wx.showToast({ title: '该段声音太弱，无法建声纹，请让其再说一句', icon: 'none', duration: 2000 });
      speak('声音太弱，无法起名');
      return;
    }
    let template = null;
    try { template = createTemplate([f]); } catch (e) { console.log('生成模板失败: ' + e); }
    if (!template) {
      wx.showToast({ title: '声纹生成失败，请让其再说一句后重试', icon: 'none', duration: 2000 });
      speak('声纹生成失败，请重试');
      return;
    }

    // 1) 更新会话内标签，并重标历史字幕中同一陌生人
    unknown.label = name;
    const subs = that.data.subtitles.map((s) => {
      if (s.key === key) {
        return Object.assign({}, s, { speaker: name, isKnown: true });
      }
      return s;
    });

    // 2) 入库：用该陌生人这一句的特征生成声纹模板（单样本）
    const db = wx.getStorageSync('voiceprint_db') || { users: [] };
    if (!db.users) db.users = [];
    db.users.push({
      id: 'user_' + Date.now(),
      name: name,
      enrolledAt: Date.now(),
      template: template
    });
    wx.setStorageSync('voiceprint_db', db);

    that.setData({
      subtitles: subs,
      lastUnknownKey: null,
      statusText: '已为「' + name + '」起名并入库'
    });
    speak('已为' + name + '起名');
    wx.showToast({ title: '已保存：' + name, icon: 'success', duration: 1500 });
  },

  // 清空字幕
  clearSubtitles() {
    this.setData({ subtitles: [], statusText: '字幕已清空' });
  },

  // 字幕聆听中的语音指令截获：只对「整句即命令」的严格短句生效，避免把正常对话
  // 里出现的“清空/退出”等词当指令误吞。返回 true = 已作为命令消费（不进字幕）。
  handleCaptionVoiceCommand(text) {
    const t = (text || '').trim();
    const m = t.match(/^(暂停聆听|停止聆听|暂停|清空字幕|清空|退出|返回主页)。?$/);
    if (!m) return false;
    const cmd = m[1];
    if (cmd === '清空' || cmd === '清空字幕') { this.clearSubtitles(); speak('字幕已清空'); return true; }
    if (cmd === '退出' || cmd === '返回主页') { this.handleBack(); return true; }
    // 暂停/停止聆听：停字幕流，并转入命令常听（语音仍能唤醒恢复，不必靠手势）
    this.stopListening();
    this.setupPausedVoice();
    return true;
  },

  // 暂停态命令常听：字幕流停止后仍开一个轻量 ASR，只听「开始聆听 / 退出」，
  // 让全语音用户不必靠手势就能恢复。对齐 index.ink 的 setup/schedule/teardown 三件套（含 onError 重启）。
  setupPausedVoice() {
    if (this._pausedVoiceActive || !isAsrAvailable()) return;
    const that = this;
    this._pausedVoiceActive = true;
    initAsr({
      onFinal: function (text) {
        const t = (text || '').trim();
        if (/开始聆听|继续聆听|开始字幕|继续/.test(t)) { that.teardownPausedVoice(); that.startListening(); return; }
        if (/退出|返回主页|返回/.test(t)) { that.teardownPausedVoice(); that.handleBack(); return; }
        that.schedulePausedRestart();
      },
      onError: function () { that.schedulePausedRestart(); }
    });
    startAsr({ lang: this.data.asrLang });
  },

  schedulePausedRestart() {
    const that = this;
    if (this._pausedVoiceRestartTimer) return;
    this._pausedVoiceRestartTimer = setTimeout(function () {
      that._pausedVoiceRestartTimer = null;
      if (!that._pausedVoiceActive || !isAsrAvailable()) return;
      startAsr({ lang: that.data.asrLang });
    }, 400);
  },

  teardownPausedVoice() {
    this._pausedVoiceActive = false;
    if (this._pausedVoiceRestartTimer) {
      try { clearTimeout(this._pausedVoiceRestartTimer); } catch (e) {}
      this._pausedVoiceRestartTimer = null;
    }
    stopAsr();
  },

  onKeyDown(event) {
    this._lastFrameworkKey = Date.now();
    // 調試：把整個事件的屬性名與原始碼顯示在螢幕 debugKey 上，便於確認返回手勢的 code
    try {
      const keys = event ? Object.keys(event).join(',') : 'null';
      const raw = event ? (event.code || event.key || '?') : 'null';
      const kc = event && typeof event.keyCode === 'number' ? (' kc=' + event.keyCode) : '';
      this.setData({ debugKey: raw + kc + ' | keys:[' + keys + ']' });
    } catch (e) {}
    routeKeyEvent(this, event, 'down');
  },

  onKeyUp(event) {
    if (!event) return;
    routeKeyEvent(this, event, 'up');
  },

  // 返回键：无论是否卡死，先停止聆听并退出本页，保证一定能退出来
  handleBack() {
    try { this.teardownPausedVoice(); } catch (e) {}
    try { this.stopListening(); } catch (e) { console.log('[conversation] stopListening 异常: ' + (e && e.message ? e.message : e)); }
    safeBack();
  },

  // 屏幕「返回主页」按钮：不依赖按键通道，直接停聆听并跳回主页（绕过按鍵識別問題）
  goBackHome() {
    console.log('[conversation] 点击返回主页');
    try { this.stopListening(); } catch (e) { console.log('[conversation] stopListening 异常: ' + (e && e.message ? e.message : e)); }
    safeBack();
  },

  // 短按：进入 - 给最近一位陌生人起名（现场起名）
  handleTap() {
    this.nameLastUnknown();
  },

  // 双击：退出（先停止聆听再返回主页）
  handleDoubleTap() {
    this.handleBack();
  },

  // 滑动：左右选择功能（左/上 → 清空字幕；右/下 → 开始/暂停聆听）
  handleSwipe(direction) {
    if (direction === 'left' || direction === 'up') {
      this.clearSubtitles();
    } else if (direction === 'right' || direction === 'down') {
      this.toggleListening();
    }
  }
}
</script>

<page>
  <view class="container">
    <view class="header-row">
      <view class="back-btn" bindtap="goBackHome">
        <text class="back-btn-text">← 返回主页</text>
      </view>
      <text class="title">对话字幕</text>
      <view class="mode-badge {{modeBadgeClass}}" bindtap="refreshAsrMode">
        <text>{{asrModeText}}</text>
      </view>
    </view>
    <text class="instruction">听障交流辅助 - 说话人自动标注</text>
    <text class="asr-notice" ink:if="{{showAsrNotice}}">说话人识别为真实声纹 ｜ 文字由 Rokid 语音识别（ASR）提供，仿真环境显示演示文本</text>

    <view class="status-bar {{statusBarClass}}">
      <text class="status-dot"></text>
      <text class="status-text">{{statusText}}</text>
    </view>

    <view class="settings-toggle" bindtap="toggleSettings">
      <text>设置（时长 {{recDuration/1000}}s ｜ 语言 {{asrLang}}）</text>
    </view>
    <view class="settings-panel" ink:if="{{showSettings}}">
      <view class="settings-item" bindtap="cycleDuration">
        <text class="settings-label">录音时长</text>
        <text class="settings-value">{{recDuration/1000}} 秒（点击切换）</text>
      </view>
      <view class="settings-item" bindtap="cycleLang">
        <text class="settings-label">识别语言</text>
        <text class="settings-value">{{asrLang}}（点击切换）</text>
      </view>
      <view class="settings-item" bindtap="toggleVoicePromptSetting">
        <text class="settings-label">语音提示</text>
        <text class="settings-value">{{voicePromptText}}</text>
      </view>
    </view>

    <view class="waveform-display">
      <view wx:for="{{waveformData}}" wx:key="index" wx:for-item="item">
        <view class="waveform-bar" style="height: {{item * 100}}%;"></view>
      </view>
    </view>

    <scroll-view class="subtitle-area" scroll-y="true">
      <view class="subtitle-line" wx:for="{{subtitles}}" wx:key="id">
        <text class="speaker known" wx:if="{{item.isKnown}}">{{item.speaker}}：</text>
        <text class="speaker unknown" wx:else>{{item.speaker}}：</text>
        <text class="subtitle-text">{{item.text}}</text>
      </view>
      <view class="empty-sub" wx:if="{{subtitles.length === 0}}">
        <text>开始聆听后，对话字幕会显示在这里</text>
      </view>
    </scroll-view>

    <view class="gesture-hint">
      <text>短按：为陌生人起名 ｜ 左滑：清空字幕 ｜ 右滑：开始/暂停聆听 ｜ 双击：退出</text>
    </view>

    <view class="sim-tap" bindtap="handleTap" bindlongpress="handleDoubleTap">
      <text class="sim-tap-text">仿真操作：点此=短按（为陌生人起名）｜ 长按此区域=退出 ｜ 键盘双击空格=退出</text>
    </view>

    <view class="debug-key">
      <text class="debug-key-text">最近按键：{{debugKey || '（暂无）'}}</text>
    </view>
  </view>
</page>

<style>
.container {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 20px;
  background-color: #000000;
  height: 100%;
}

.title {
  font-size: 28px;
  font-weight: bold;
  color: #40FF5E;
  margin-bottom: 4px;
}

.header-row {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.back-btn {
  flex: 0 0 auto;
  padding: 6px 14px;
  background-color: rgba(64, 255, 94, 0.15);
  border: 1px solid #40FF5E;
  border-radius: 16px;
}

.back-btn:active {
  background-color: rgba(64, 255, 94, 0.35);
}

.back-btn-text {
  font-size: 14px;
  font-weight: bold;
  color: #40FF5E;
}

.mode-badge {
  font-size: 12px;
  font-weight: bold;
  padding: 4px 10px;
  border-radius: 12px;
  border: 1px solid;
}

.mode-badge.real {
  color: #000000;
  background-color: #40FF5E;
  border-color: #40FF5E;
}

.mode-badge.demo {
  color: #FFB000;
  background-color: rgba(255, 176, 0, 0.1);
  border-color: #FFB000;
}

.settings-toggle {
  width: 100%;
  padding: 8px 12px;
  background-color: #1a1a1a;
  border: 1px solid #333333;
  border-radius: 10px;
  margin-bottom: 8px;
  text-align: center;
}

.settings-toggle text {
  font-size: 15px;
  color: #E6E6E6;
}

.settings-panel {
  width: 100%;
  background-color: #141414;
  border: 1px solid #333333;
  border-radius: 10px;
  padding: 8px;
  margin-bottom: 10px;
  box-sizing: border-box;
}

.settings-item {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
  padding: 10px 8px;
  border-bottom: 1px solid #222222;
}

.settings-item:last-child {
  border-bottom: none;
}

.settings-label {
  font-size: 14px;
  color: #40FF5E;
  font-weight: bold;
}

.settings-value {
  font-size: 13px;
  color: #FFFFFF;
}

.instruction {
  font-size: 17px;
  color: #E6E6E6;
  margin-bottom: 8px;
  text-align: center;
  text-shadow: 0 0 4px rgba(255, 255, 255, 0.2);
}

.asr-notice {
  font-size: 14px;
  color: #FFC93C;
  background-color: rgba(255, 176, 0, 0.15);
  border: 1px solid #FFB000;
  border-radius: 8px;
  padding: 6px 12px;
  margin-bottom: 12px;
  text-align: center;
}

.status-bar {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 8px;
  width: 100%;
  padding: 10px 14px;
  background-color: #1a1a1a;
  border: 2px solid #333333;
  border-radius: 12px;
  margin-bottom: 12px;
}

.status-bar.listening {
  border-color: #40FF5E;
}

.status-dot {
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background-color: #666666;
}

.status-bar.listening .status-dot {
  background-color: #40FF5E;
  animation: blink 1s infinite;
}

@keyframes blink {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.3; }
}

.status-text {
  font-size: 21px;
  color: #7DFF90;
  font-weight: bold;
  text-shadow: 0 0 6px rgba(64, 255, 94, 0.7);
}

.waveform-display {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  width: 100%;
  height: 50px;
  gap: 4px;
  background-color: #1a1a1a;
  border-radius: 12px;
  padding: 8px;
  margin-bottom: 12px;
  box-sizing: border-box;
}

.waveform-bar {
  flex: 1;
  background-color: #40FF5E;
  border-radius: 2px;
  min-height: 3px;
}

.subtitle-area {
  width: 100%;
  flex: 1;
  background-color: #0d0d0d;
  border: 2px solid #333333;
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 12px;
  box-sizing: border-box;
}

.subtitle-line {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  align-items: baseline;
  margin-bottom: 14px;
  line-height: 1.5;
}

.speaker {
  font-size: 23px;
  font-weight: bold;
  margin-right: 6px;
}

.speaker.known {
  color: #7DFF90;
  text-shadow: 0 0 5px rgba(64, 255, 94, 0.6);
}

.speaker.unknown {
  color: #FFC93C;
  text-shadow: 0 0 5px rgba(255, 176, 0, 0.5);
}

.subtitle-text {
  font-size: 23px;
  color: #FFFFFF;
  flex: 1;
}

.empty-sub {
  display: flex;
  justify-content: center;
  padding: 24px;
}

.empty-sub text {
  font-size: 16px;
  color: #999999;
  text-align: center;
}

.gesture-hint {
  font-size: 14px;
  color: #C4C4C4;
  text-align: center;
  line-height: 1.5;
  text-shadow: 0 0 3px rgba(255, 255, 255, 0.15);
}

.sim-tap {
  width: 100%;
  padding: 14px;
  background-color: rgba(64, 255, 94, 0.12);
  border: 2px dashed #40FF5E;
  border-radius: 12px;
  text-align: center;
  margin-top: 10px;
  box-sizing: border-box;
}

.sim-tap:active {
  background-color: rgba(64, 255, 94, 0.28);
}

.sim-tap-text {
  font-size: 15px;
  font-weight: bold;
  color: #7DFF90;
}

.debug-key {
  margin-top: 8px;
  padding: 6px 10px;
  background-color: rgba(255, 255, 255, 0.06);
  border-radius: 8px;
}

.debug-key-text {
  font-size: 13px;
  color: #FFB000;
  word-break: break-all;
}
</style>
