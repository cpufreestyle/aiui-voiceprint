<script def>
{
  "navigationBarTitleText": "声纹注册 - 无障碍版",
  "description": "声纹注册页面 - 为听障人士优化，提供语音+视觉引导向导、实时波形可视化、振动反馈和大字体文字提示",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "status": {
          "type": "string",
          "description": "当前录音状态文字提示"
        },
        "isRecording": {
          "type": "boolean",
          "description": "是否正在录音"
        },
        "recorded": {
          "type": "boolean",
          "description": "是否已完成录音"
        },
        "sampleCount": {
          "type": "number",
          "description": "已录制的声音样本数量"
        },
        "waveformData": {
          "type": "array",
          "description": "实时波形数据数组",
          "items": {
            "type": "number"
          }
        },
        "progressText": {
          "type": "string",
          "description": "进度提示文字"
        },
        "wizardActive": {
          "type": "boolean",
          "description": "是否处于向导流程中"
        },
        "wizardStep": {
          "type": "string",
          "enum": ["intro", "prompt", "countdown", "recording", "checkok", "retry", "enrolling", "activate", "done"],
          "description": "向导当前步骤"
        },
        "wizardCaption": {
          "type": "string",
          "description": "向导主字幕文案"
        },
        "wizardHint": {
          "type": "string",
          "description": "向导副提示文案"
        },
        "countdownNum": {
          "type": "string",
          "description": "倒计时大数字（3/2/1），空串表示不显示"
        },
        "sentenceIndexText": {
          "type": "string",
          "description": "当前第几句进度文案，如「第 1 / 3 句」"
        },
        "showManual": {
          "type": "boolean",
          "description": "是否展开手动模式按钮区"
        }
      },
      "required": ["status", "isRecording", "recorded", "sampleCount", "waveformData", "progressText"]
    }
  }
}
</script>

<script setup>
import wx from 'wx';
import { safeBack } from '../../utils/gesture.js';
import { gestureKeyDown, gestureKeyUp, shellInstallKeyboard, shellRemoveKeyboard } from '../../utils/page-shell.js';
import { acquireRecorderManager } from '../../utils/recorder.js';
import { extractFeatures, createTemplate, isRecordingValid } from '../../utils/voiceprint-engine.js';
import { setupRecorderListeners, startRecordingSession, stopRecordingSession } from '../../utils/recording-session.js';
import { speak } from '../../utils/tts.js';
import { setActiveUser } from '../../utils/active-user.js';

// 向导需录制的句子总数（与 samplePrompts 对应，至少 3 句以保证声纹稳定）
const WIZARD_TOTAL = 3;

export default {
  data: {
    status: '准备就绪',
    isRecording: false,
    recorded: false,
    // 本次录音待定特征：录完暂存于此，点「保存样本」才正式计入 sampleFeatures，
    // 从而让 sampleCount 与真正入库的有效特征数严格一致（废弃的重录不会污染模板）。
    pendingFeature: null,
    // 预计算：进度点与录音状态样式类（避免模板三元式告警）
    progressDots: ['', '', ''],
    recordingClass: '',
    recordingPath: null,
    sampleCount: 0,
    waveformData: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    progressText: '已录制 0 个样本',
    frameBuffers: [],
    sampleFeatures: [],
    recorderManager: null,
    samplePrompts: [
      '今天的天气真不错，我们出去走走吧',
      '我叫小明，很高兴认识你',
      '声音是每个人独特的标识'
    ],
    promptText: '今天的天气真不错，我们出去走走吧',
    // ===== 向导状态 =====
    wizardActive: false,
    wizardStep: 'intro',
    wizardCaption: '准备好后，点一下开始录入声纹',
    wizardHint: '点一下开始后无需再操作，我会自动一句一句带你念',
    countdownNum: '',
    sentenceIndexText: '共 3 句',
    showManual: false,
    // 预计算按钮文案，避免模板三元式触发 ink 静态检查告警
    manualToggleText: '手动模式（高级）'
  },
  onLoad() {
    console.log('注册页面加载 - 向导模式');
    // 重置样本累积与向导状态
    this.data.sampleFeatures = [];
    this.data.pendingFeature = null;
    this.data._finalized = false;
    this._enrolledId = null;
    this._enrolledName = '';
    this._currentSentence = 0;
    // 初始化录音管理器（安全获取，不同运行时 API 位置不同）
    this.recorderManager = acquireRecorderManager();
    setupRecorderListeners(this);
    // 进入向导欢迎步
    this.setData({
      wizardActive: false,
      wizardStep: 'intro',
      wizardCaption: '准备好后，点一下开始录入声纹',
      wizardHint: '点一下开始后无需再操作，我会自动一句一句带你念',
      countdownNum: '',
      sentenceIndexText: '共 ' + WIZARD_TOTAL + ' 句'
    });
  },
  onUnload() {
    // 中止向导链条，清理录音监听器
    this.data.wizardActive = false;
    if (this.recorderManager) {
      this.recorderManager.offFrameRecorded();
    }
    // 释放 window 级键盘兜底监听（redirectTo/navigateBack 走 onUnload，不一定触发 onHide）
    shellRemoveKeyboard(this);
  },

  onShow() {
    shellInstallKeyboard(this);
  },

  onHide() {
    shellRemoveKeyboard(this);
  },

  onKeyDown: gestureKeyDown,

  onKeyUp: gestureKeyUp,

  // ============ 向导流程（全自动流转）============

  // 振动反馈（受全局无障碍开关控制）
  vibrate() {
    const app = getApp();
    if (app && app.globalData && app.globalData.vibrationEnabled) {
      try { wx.vibrateShort(); } catch (e) {}
    }
  },

  // 启动向导：从第 1 句开始
  startWizard() {
    if (this.data.wizardActive) return;
    this.data.sampleFeatures = [];
    this.data.pendingFeature = null;
    this.data._finalized = false;
    this._currentSentence = 0;
    this.setData({
      wizardActive: true,
      sampleCount: 0,
      progressDots: ['', '', ''],
      showManual: false
    });
    speak('开始录入声纹，我会带你一句一句念');
    this.wizardPrompt();
  },

  // 展示当前句，提示「跟我念」，停留片刻让用户看清，再进入倒计时
  wizardPrompt() {
    if (!this.data.wizardActive) return;
    const idx = this._currentSentence;
    const sentence = this.data.samplePrompts[idx] || this.data.samplePrompts[0];
    this.setData({
      wizardStep: 'prompt',
      promptText: sentence,
      countdownNum: '',
      wizardCaption: '跟我念这句话',
      wizardHint: '看清楚，马上开始',
      sentenceIndexText: '第 ' + (idx + 1) + ' / ' + WIZARD_TOTAL + ' 句',
      status: '准备朗读'
    });
    speak('跟我念：' + sentence);
    const that = this;
    setTimeout(function () {
      if (!that.data.wizardActive) return;
      that.wizardCountdown();
    }, 2600);
  },

  // 三 → 二 → 一 倒计时（大数字 + 语音 + 震动），结束即开始录音
  wizardCountdown() {
    if (!this.data.wizardActive) return;
    const that = this;
    this.setData({ wizardStep: 'countdown', wizardCaption: '准备，跟我念', wizardHint: '' });
    const seq = ['三', '二', '一'];
    let i = 0;
    function tick() {
      if (!that.data.wizardActive) return;
      if (i >= seq.length) {
        that.setData({ countdownNum: '' });
        that.wizardStartRecord();
        return;
      }
      that.setData({ countdownNum: seq[i] });
      speak(seq[i]);
      that.vibrate();
      i++;
      setTimeout(tick, 900);
    }
    tick();
  },

  // 向导录音：复用 startRecordingSession（3 秒后自动 stopRecording）
  wizardStartRecord() {
    if (!this.data.wizardActive) return;
    // 无录音能力（仿真 / 麦克风权限被拒）：明确退回 intro 并语音告知，
    // 否则 startRecordingSession 会静默 return，向导永久卡死在「现在，念出来」这一步。
    if (!this.recorderManager) {
      this.data.wizardActive = false;
      this._currentSentence = 0;
      this.data.sampleFeatures = [];
      this.setData({
        wizardActive: false,
        wizardStep: 'intro',
        wizardCaption: '当前环境无法录音',
        wizardHint: '请检查麦克风权限后，点一下重试',
        countdownNum: '',
        sampleCount: 0,
        progressDots: ['', '', '']
      });
      speak('当前环境无法录音，请检查麦克风权限');
      return;
    }
    this._skipNextStop = false; // 清除可能残留的取消标记，确保本句能正常录入
    const sentence = this.data.samplePrompts[this._currentSentence] || this.data.samplePrompts[0];
    this.setData({
      wizardStep: 'recording',
      wizardCaption: '现在，念出来',
      wizardHint: '清晰读出上面这句话，录完自动进入下一句（无需按键）',
      countdownNum: ''
    });
    startRecordingSession(this, {
      recordingKey: 'isRecording',
      classKey: 'recordingClass',
      recordingClass: 'recording',
      statusText: '正在录音 - 请清晰朗读',
      startSpeak: '开始',
      stopMethod: 'stopRecording',
      extraData: { promptText: sentence }
    });
  },

  // 一句录完（有效）后推进：还有句子→下一句；已够→生成声纹
  wizardAfterSample() {
    if (!this.data.wizardActive) return;
    const that = this;
    this._currentSentence += 1;
    const done = this._currentSentence;
    this.setData({
      wizardStep: 'checkok',
      wizardCaption: '第 ' + done + ' 句完成',
      wizardHint: done < WIZARD_TOTAL ? '准备下一句' : '全部念完了，正在生成声纹',
      countdownNum: ''
    });
    this.vibrate();
    speak('第 ' + done + ' 句完成');
    setTimeout(function () {
      if (!that.data.wizardActive) return;
      if (that._currentSentence < WIZARD_TOTAL) {
        that.wizardPrompt();
      } else {
        that.wizardEnroll();
      }
    }, 1200);
  },

  // 本句没录好：提示后重录当前句（句号不前进）
  wizardRetry() {
    if (!this.data.wizardActive) return;
    const that = this;
    const sentence = this.data.samplePrompts[this._currentSentence] || this.data.samplePrompts[0];
    this.setData({
      wizardStep: 'retry',
      wizardCaption: '没听清，我们再念一次',
      wizardHint: '请靠近麦克风，大声一点：' + sentence,
      countdownNum: ''
    });
    // 复述本句，方便依赖语音的用户重录时仍知道要念什么
    speak('没听清，再念一次：' + sentence);
    setTimeout(function () {
      if (!that.data.wizardActive) return;
      that.wizardCountdown();
    }, 1800);
  },

  // 生成声纹并入库，成功后进入「是否启用」
  wizardEnroll() {
    if (!this.data.wizardActive) return;
    this.setData({ wizardStep: 'enrolling', wizardCaption: '正在生成你的声纹', wizardHint: '请稍候', countdownNum: '' });
    const res = this.persistVoiceprint();
    if (!res.ok) {
      // 生成失败：退回 intro，用户点一下即可重新走一遍向导
      this.data.wizardActive = false;
      this._currentSentence = 0;
      this.setData({
        wizardActive: false,
        wizardStep: 'intro',
        wizardCaption: '声纹生成失败，点一下重新录入',
        wizardHint: '刚才的样本质量不足，我们再来一次',
        countdownNum: '',
        sampleCount: 0,
        progressDots: ['', '', '']
      });
      speak('声纹生成失败，请重试');
      return;
    }
    this._enrolledId = res.id;
    this._enrolledName = res.name;
    this.wizardActivate(res.name);
  },

  // 询问是否把新声纹设为当前身份
  wizardActivate(name) {
    this.setData({
      wizardStep: 'activate',
      wizardCaption: '声纹已保存为「' + name + '」',
      wizardHint: '设为当前身份？  点一下=启用  ｜  双击=以后再说',
      countdownNum: ''
    });
    speak('声纹已保存为' + name + '，是否设为当前身份');
  },

  // 启用新声纹
  wizardActivateYes() {
    const id = this._enrolledId;
    const name = this._enrolledName;
    if (id) setActiveUser(id);
    speak('已启用' + name);
    this.wizardDone('已启用「' + name + '」为当前身份');
  },

  // 不启用，直接完成
  wizardActivateNo() {
    this.wizardDone('声纹已保存，未设为当前身份');
  },

  // 向导收尾：完成提示后返回主页
  wizardDone(caption) {
    this.setData({
      wizardStep: 'done',
      wizardActive: false,
      wizardCaption: caption || '全部完成',
      wizardHint: '即将返回主页',
      countdownNum: ''
    });
    this.vibrate();
    const that = this;
    setTimeout(function () {
      try {
        wx.showToast({ title: '声纹注册成功', icon: 'success', duration: 1500 });
      } catch (e) {}
      setTimeout(function () { safeBack(); }, 1500);
    }, 1200);
  },

  // ============ 录音（向导与手动共用）============

  startRecording() {
    // 设置本次要朗读的句子（按已完成样本数取对应提示）
    const prompt = this.data.samplePrompts[this.data.sampleCount] || this.data.samplePrompts[0];
    startRecordingSession(this, {
      recordingKey: 'isRecording',
      classKey: 'recordingClass',
      recordingClass: 'recording',
      statusText: '正在录音 - 请清晰朗读下方文字3秒钟',
      startSpeak: '开始录音，请清晰朗读',
      stopMethod: 'stopRecording',
      extraData: { promptText: prompt }
    });
  },

  stopRecording() {
    // 向导被中途取消时，跳过这一次自动 stop 的完整处理，仅复位录音 UI
    if (this._skipNextStop) {
      this._skipNextStop = false;
      this.setData({ isRecording: false, recordingClass: '' });
      return;
    }
    stopRecordingSession(this,
      {
        recordingKey: 'isRecording',
        classKey: 'recordingClass',
        extraData: {
          recorded: true,
          status: '录音完成 - 点击下方按钮保存',
          recordingPath: 'recording_' + Date.now()
        }
      },
      (combinedAudio) => {
        const that = this;
        // 提取本次录音特征，并校验有效性（太短 / 静音则不计入，避免坏样本污染模板）
        let features = null;
        try {
          features = extractFeatures(combinedAudio);
        } catch (e) {
          console.log('提取特征失败: ' + e);
        }
        const valid = isRecordingValid(combinedAudio, features);


        // ===== 向导模式：自动保存并推进，无需用户点「保存」=====
        if (that.data.wizardActive) {
          if (!valid) {
            that.setData({ recorded: false });
            that.wizardRetry();
            return;
          }
          that.data.sampleFeatures.push(features);
          const newCount = that.data.sampleFeatures.length;
          that.setData({
            recorded: false,
            sampleCount: newCount,
            progressDots: [
              newCount >= 1 ? 'completed' : '',
              newCount >= 2 ? 'completed' : '',
              newCount >= 3 ? 'completed' : ''
            ],
            progressText: '已录制 ' + newCount + ' 个样本'
          });
          that.wizardAfterSample();
          return;
        }

        // ===== 手动模式：暂存待定，等用户点「保存样本」=====
        if (!valid) {
          that.data.pendingFeature = null;
          that.setData({ recorded: false, status: '没录到清晰声音，请靠近麦克风重录' });
          speak('没录到清晰声音，请重录');
          return;
        }
        that.data.pendingFeature = features;
        speak('录音完成，请保存');
      }
    );
  },

  saveVoiceprint() {
    const that = this;

    if (!that.data.recorded || !that.data.pendingFeature) {
      that.setData({ status: '请先完成一次有效录音' });
      speak('请先完成录音');
      return;
    }

    // 此刻才把待定特征正式计入，保证 sampleCount 恒等于入库的有效特征数
    that.data.sampleFeatures.push(that.data.pendingFeature);
    that.data.pendingFeature = null;
    const newCount = that.data.sampleFeatures.length;
    that.setData({
      sampleCount: newCount,
      recorded: false,
      progressDots: [
        newCount >= 1 ? 'completed' : '',
        newCount >= 2 ? 'completed' : '',
        newCount >= 3 ? 'completed' : ''
      ],
      status: '样本 ' + newCount + ' 已保存',
      progressText: '已录制 ' + newCount + ' 个样本' + (newCount < 3 ? '（至少 3 个）' : ''),
      waveformData: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    });

    // 振动反馈
    this.vibrate();

    // 可继续录制更多样本（>3 也可），或点击「完成注册」
    const nextPrompt = that.data.samplePrompts[newCount % that.data.samplePrompts.length];
    setTimeout(function () {
      that.setData({
        status: newCount >= 3 ? '可继续录制，或点击「完成注册」' : '准备录制第 ' + (newCount + 1) + ' 个样本 - 点击开始录音',
        promptText: nextPrompt
      });
    }, 1500);
  },

  // 生成声纹模板并写入声纹库，返回 { ok, id, name }。向导与手动共用。
  persistVoiceprint() {
    const that = this;
    if (that.data.sampleFeatures.length < 3) {
      return { ok: false };
    }
    if (that.data._finalized) return { ok: false };

    let template = null;
    try {
      template = createTemplate(that.data.sampleFeatures);
    } catch (e) {
      console.log('生成模板失败: ' + e);
    }
    // 模板无效则中止入库：绝不存进 template:null 的「空模板用户」——
    // 否则验证时会被 identifySpeaker 跳过，表现为「注册成功却永远验证不了」。
    if (!template) {
      return { ok: false };
    }
    that.data._finalized = true;

    const db = wx.getStorageSync('voiceprint_db') || { users: [] };
    if (!db.users) db.users = [];
    const id = 'user_' + Date.now();
    const name = '用户 ' + (db.users.length + 1);
    db.users.push({
      id: id,
      name: name,
      enrolledAt: Date.now(),
      template: template
    });
    wx.setStorageSync('voiceprint_db', db);
    return { ok: true, id: id, name: name };
  },

  // 手动完成注册：用全部已录样本生成模板并入库
  finishEnroll() {
    const that = this;
    if (that.data.sampleFeatures.length < 3) {
      that.setData({ status: '至少录制并保存 3 个有效样本后再完成' });
      speak('至少录制3个样本');
      return;
    }
    const res = this.persistVoiceprint();
    if (!res.ok) {
      that.setData({ status: '声纹生成失败，请重新录制样本' });
      speak('声纹生成失败，请重试');
      return;
    }
    that.setData({
      status: '注册完成！声纹已保存为「' + res.name + '」',
      progressText: '已录制 ' + that.data.sampleCount + ' 个样本 - 完成'
    });
    speak('注册完成，声纹已保存为' + res.name);

    setTimeout(function () {
      wx.showToast({ title: '声纹注册成功', icon: 'success', duration: 2000 });
      setTimeout(function () { safeBack(); }, 2000);
    }, 1000);
  },

  // 切换手动模式按钮区显隐
  toggleManual() {
    const next = !this.data.showManual;
    this.setData({
      showManual: next,
      manualToggleText: next ? '收起手动模式' : '手动模式（高级）'
    });
  },

  // 取消进行中的向导：停录音、回起始步，但【不退出页面】。
  // 关键修复：向导中误触返回键/双击时走这里，避免 handleDoubleTap 直接把整页弹出（闪退根因）。
  cancelWizard() {
    this.data.wizardActive = false;
    this._skipNextStop = true; // 让紧接着的自动 stop 回调跳过，避免走完整录音处理
    this._currentSentence = 0;
    this.data.sampleFeatures = [];
    this.data.pendingFeature = null;
    if (this.recorderManager) {
      try { this.recorderManager.stop(); } catch (e) {}
    }
    this.setData({
      wizardActive: false,
      wizardStep: 'intro',
      isRecording: false,
      recordingClass: '',
      recorded: false,
      sampleCount: 0,
      progressDots: ['', '', ''],
      countdownNum: '',
      wizardCaption: '已暂停，点一下重新开始录入',
      wizardHint: '无需按键，开始后我会自动一句一句带你念',
      sentenceIndexText: '共 ' + WIZARD_TOTAL + ' 句'
    });
    speak('已暂停');
  },

  cancelEnroll() {
    this.data.wizardActive = false;
    safeBack();
  },

  // 镜腿短按：单键推进整条流程
  // 录音中→停止；已录待存→保存样本；已满 3 个样本→完成注册；否则→开始录音。
  // 双击已用于「退出」，故完成注册并入短按流程（录满 3 个后短按即完成）。
  handleTap() {
    if (this.data.wizardActive || this.data.wizardStep === 'activate' || this.data.wizardStep === 'intro') {
      if (this.data.wizardStep === 'intro') {
        this.startWizard();
      } else if (this.data.wizardStep === 'activate') {
        this.wizardActivateYes();
      }
      // 其余向导步骤自动流转，短按不打断
      return;
    }
    if (this.data.isRecording) {
      this.stopRecording();
    } else if (this.data.recorded) {
      this.saveVoiceprint();
    } else if (this.data.sampleCount >= 3) {
      this.finishEnroll();
    } else {
      this.startRecording();
    }
  },

  // 镜腿双击：activate 步=不启用直接完成；其余=退出
  handleDoubleTap() {
    if (this.data.wizardStep === 'activate') {
      this.wizardActivateNo();
      return;
    }
    // 向导进行中：只暂停回起点，【不退出页面】（防返回键/双击误触闪退）
    if (this.data.wizardActive) {
      this.cancelWizard();
      return;
    }
    this.cancelEnroll();
  },

  // 镜腿滑动：左右选择相邻功能（一侧→验证身份，另一侧→返回主页）
  handleSwipe(direction) {
    if (this.data.wizardActive) return; // 向导进行中不跳页
    if (direction === 'left' || direction === 'up') {
      wx.redirectTo({ url: '/pages/verify/verify' });
    } else if (direction === 'right' || direction === 'down') {
      this.cancelEnroll();
    }
  }
}
</script>

<page>
  <view class="container">
    <text class="title">声纹注册</text>

    <!-- ===== 向导卡片：全程语音+视觉引导 ===== -->
    <view class="wizard-card">
      <text class="wizard-caption">{{wizardCaption}}</text>

      <view class="countdown-box" wx:if="{{countdownNum}}">
        <text class="countdown-num">{{countdownNum}}</text>
      </view>

      <view class="prompt-box" wx:if="{{wizardStep === 'prompt' || wizardStep === 'recording'}}">
        <text class="prompt-label">请朗读</text>
        <text class="prompt-text">{{promptText}}</text>
      </view>

      <view class="waveform-display" wx:if="{{wizardStep === 'recording'}}">
        <view wx:for="{{waveformData}}" wx:key="index" wx:for-item="item">
          <view class="waveform-bar" style="height: {{item * 100}}%;"></view>
        </view>
      </view>

      <text class="wizard-hint" wx:if="{{wizardHint}}">{{wizardHint}}</text>
      <text class="wizard-index">{{sentenceIndexText}}</text>

      <view class="progress-indicator">
        <view class="progress-dot {{progressDots[0]}}"></view>
        <view class="progress-dot {{progressDots[1]}}"></view>
        <view class="progress-dot {{progressDots[2]}}"></view>
      </view>
    </view>

    <!-- ===== 手动模式（兜底，默认折叠）===== -->
    <button class="manual-toggle" bindtap="toggleManual">
      <text>{{manualToggleText}}</text>
    </button>

    <view class="manual-panel" wx:if="{{showManual}}">
      <view class="status-box {{recordingClass}}">
        <text class="status-text">{{status}}</text>
      </view>
      <view class="button-group">
        <button bindtap="startRecording" disabled="{{isRecording}}" class="record-btn">
          <text class="btn-main-text">开始录音</text>
          <text class="btn-sub-text">录制3秒钟</text>
        </button>
        <button bindtap="stopRecording" disabled="{{!isRecording}}" class="stop-btn">
          <text class="btn-main-text">停止录音</text>
        </button>
        <button bindtap="saveVoiceprint" disabled="{{!recorded}}" class="save-btn">
          <text class="btn-main-text">保存样本</text>
          <text class="btn-sub-text">确认保存当前录音</text>
        </button>
        <button bindtap="finishEnroll" disabled="{{sampleCount < 3}}" class="finish-btn">
          <text class="btn-main-text">完成注册</text>
          <text class="btn-sub-text">用全部样本生成声纹</text>
        </button>
      </view>
    </view>

    <text class="gesture-hint">短按：开始 / 启用 ｜ 滑动：切换功能 ｜ 双击：退出</text>

    <view class="sim-tap" bindtap="handleTap" bindlongpress="handleDoubleTap">
      <text class="sim-tap-text">仿真操作：点此=短按（开始向导 / 启用声纹）｜ 长按此区域=退出</text>
    </view>
  </view>
</page>

<style>
.container {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 16px;
  background-color: #000000;
  height: 100%;
  box-sizing: border-box;
}

.title {
  font-size: 26px;
  font-weight: bold;
  color: #40FF5E;
  margin-bottom: 10px;
}

/* ===== 向导卡片 ===== */
.wizard-card {
  width: 100%;
  background-color: #0d1a0d;
  border: 3px solid #40FF5E;
  border-radius: 14px;
  padding: 18px;
  margin-bottom: 12px;
  display: flex;
  flex-direction: column;
  align-items: center;
  box-sizing: border-box;
}

.wizard-caption {
  font-size: 26px;
  font-weight: bold;
  color: #7DFF90;
  text-align: center;
  line-height: 1.4;
  text-shadow: 0 0 8px rgba(64, 255, 94, 0.7);
  margin-bottom: 8px;
}

.countdown-box {
  display: flex;
  align-items: center;
  justify-content: center;
  margin: 10px 0;
}

.countdown-num {
  font-size: 72px;
  font-weight: bold;
  color: #FFFFFF;
  text-shadow: 0 0 16px rgba(64, 255, 94, 0.9);
}

.prompt-box {
  width: 100%;
  background-color: #001400;
  border: 2px dashed #40FF5E;
  border-radius: 12px;
  padding: 14px;
  margin: 10px 0;
  text-align: center;
  box-sizing: border-box;
}

.prompt-label {
  font-size: 15px;
  color: #40FF5E;
  opacity: 0.7;
  display: block;
  margin-bottom: 6px;
}

.prompt-text {
  font-size: 26px;
  font-weight: bold;
  color: #FFFFFF;
  line-height: 1.5;
  display: block;
  text-shadow: 0 0 5px rgba(255, 255, 255, 0.35);
}

.waveform-display {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  height: 60px;
  gap: 3px;
  width: 100%;
  margin: 8px 0;
}

.waveform-bar {
  flex: 1;
  background-color: #40FF5E;
  border-radius: 2px;
  min-height: 4px;
  transition: height 0.1s ease;
}

.wizard-hint {
  font-size: 17px;
  color: #CFFFD8;
  text-align: center;
  line-height: 1.4;
  margin-top: 6px;
}

.wizard-index {
  font-size: 14px;
  color: rgba(64, 255, 94, 0.7);
  margin-top: 8px;
}

.progress-indicator {
  display: flex;
  justify-content: center;
  gap: 18px;
  margin-top: 10px;
}

.progress-dot {
  width: 20px;
  height: 20px;
  border-radius: 50%;
  background-color: #333333;
  border: 3px solid #666666;
}

.progress-dot.completed {
  background-color: #40FF5E;
  border-color: #40FF5E;
}

/* ===== 手动模式 ===== */
.manual-toggle {
  width: 100%;
  padding: 10px;
  background-color: transparent;
  border: 1px solid rgba(64, 255, 94, 0.4);
  border-radius: 8px;
  margin-bottom: 8px;
}

.manual-toggle text {
  font-size: 14px;
  color: rgba(64, 255, 94, 0.8);
}

.manual-panel {
  width: 100%;
  margin-bottom: 8px;
}

.status-box {
  width: 100%;
  background-color: #1a1a1a;
  border: 2px solid #40FF5E;
  border-radius: 12px;
  padding: 14px;
  margin-bottom: 12px;
  text-align: center;
  box-sizing: border-box;
}

.status-box.recording {
  background-color: #2a1a1a;
  border-color: #FF4040;
  animation: pulse 1s infinite;
}

@keyframes pulse {
  0%, 100% { border-color: #FF4040; }
  50% { border-color: #FF8080; }
}

.status-text {
  font-size: 20px;
  color: #7DFF90;
  font-weight: bold;
  line-height: 1.5;
  text-shadow: 0 0 8px rgba(64, 255, 94, 0.8);
}

.status-box.recording .status-text {
  color: #FF4040;
}

.button-group {
  display: flex;
  flex-direction: column;
  gap: 10px;
  width: 100%;
}

button {
  padding: 14px;
  border-radius: 12px;
  border: 3px solid;
  font-size: 18px;
  display: flex;
  flex-direction: column;
  align-items: center;
}

button[disabled] {
  opacity: 0.4;
}

.record-btn { background-color: #40FF5E; border-color: #40FF5E; }
.stop-btn { background-color: #FF4040; border-color: #FF4040; }
.save-btn { background-color: #4090FF; border-color: #4090FF; }
.finish-btn { background-color: #40FF5E; border-color: #40FF5E; }

.btn-main-text {
  font-size: 20px;
  font-weight: bold;
  color: #000000;
  margin-bottom: 2px;
}

.stop-btn .btn-main-text {
  color: #FFFFFF;
}

.btn-sub-text {
  font-size: 13px;
  color: #000000;
  opacity: 0.8;
}

.gesture-hint {
  font-size: 15px;
  color: #E6E6E6;
  text-align: center;
  margin-bottom: 8px;
  text-shadow: 0 0 4px rgba(255, 255, 255, 0.2);
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

.sim-tap:active {
  background-color: rgba(64, 255, 94, 0.28);
}

.sim-tap-text {
  font-size: 15px;
  font-weight: bold;
  color: #7DFF90;
  text-shadow: 0 0 5px rgba(64, 255, 94, 0.6);
}
</style>
