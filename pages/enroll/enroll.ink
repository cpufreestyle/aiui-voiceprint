<script def>
{
  "navigationBarTitleText": "声纹注册 - 无障碍版",
  "description": "声纹注册页面 - 为听障人士优化，提供实时波形可视化、振动反馈和大字体文字提示",
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

export default {
  data: {
    status: '准备就绪 - 点击下方按钮开始录音',
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
    promptText: '今天的天气真不错，我们出去走走吧'
  },
  onLoad() {
    console.log('注册页面加载 - 无障碍模式');
    // 重置样本累积
    this.data.sampleFeatures = [];
    this.data.pendingFeature = null;
    this.data._finalized = false;
    // 初始化录音管理器（安全获取，不同运行时 API 位置不同）
    this.recorderManager = acquireRecorderManager();
    setupRecorderListeners(this);
  },
  onUnload() {
    // 清理录音监听器
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
          if (!isRecordingValid(combinedAudio, features)) {
            // 本次录音无效：清掉待定特征、退回未录状态，提示重录
            that.data.pendingFeature = null;
            that.setData({ recorded: false, status: '没录到清晰声音，请靠近麦克风重录' });
            speak('没录到清晰声音，请重录');
            return;
          }
          // 有效：暂存，待「保存样本」正式计入
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
      const app = getApp();
      if (app && app.globalData && app.globalData.vibrationEnabled) {
        wx.vibrateShort();
      }

      // 可继续录制更多样本（>3 也可），或点击「完成注册」
      const nextPrompt = that.data.samplePrompts[newCount % that.data.samplePrompts.length];
      setTimeout(function() {
        that.setData({
          status: newCount >= 3 ? '可继续录制，或点击「完成注册」' : '准备录制第 ' + (newCount + 1) + ' 个样本 - 点击开始录音',
          promptText: nextPrompt
        });
      }, 1500);
    },

    // 手动完成注册：用全部已录样本生成模板并入库（支持超过 3 个样本）
    finishEnroll() {
      const that = this;
      // 门槛以「实际有效特征数」为准（与 sampleCount 一致）
      if (that.data.sampleFeatures.length < 3) {
        that.setData({ status: '至少录制并保存 3 个有效样本后再完成' });
        speak('至少录制3个样本');
        return;
      }
      if (that.data._finalized) return;

      // 用全部样本生成声纹模板
      let template = null;
      try {
        template = createTemplate(that.data.sampleFeatures);
      } catch (e) {
        console.log('生成模板失败: ' + e);
      }
      // 模板无效则中止入库：绝不存进 template:null 的「空模板用户」——
      // 否则验证时会被 identifySpeaker 跳过，表现为「注册成功却永远验证不了」。
      if (!template) {
        that.setData({ status: '声纹生成失败，请重新录制样本' });
        speak('声纹生成失败，请重试');
        return;
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

      that.setData({
        status: '注册完成！声纹已保存为「' + name + '」',
        progressText: '已录制 ' + that.data.sampleCount + ' 个样本 - 完成'
      });
      // 语音提示：注册完成
      speak('注册完成，声纹已保存为' + name);

      // 延迟后返回主页（safeBack 兼容无栈/单页仿真，避免 navigateBack 静默失败卡死）
      setTimeout(function() {
        wx.showToast({
          title: '声纹注册成功',
          icon: 'success',
          duration: 2000
        });

        setTimeout(function() {
          safeBack();
        }, 2000);
      }, 1000);
    },

    cancelEnroll() {
      safeBack();
    },

  // 镜腿短按：单键推进整条流程
  // 录音中→停止；已录待存→保存样本；已满 3 个样本→完成注册；否则→开始录音。
  // 双击已用于「退出」，故完成注册并入短按流程（录满 3 个后短按即完成）。
  handleTap() {
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

  // 镜腿双击：退出（返回主页）
  handleDoubleTap() {
    this.cancelEnroll();
  },

  // 镜腿滑动：左右选择相邻功能（一侧→验证身份，另一侧→返回主页）
  handleSwipe(direction) {
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
    <text class="instruction">请清晰说话，录制至少 3 个声音样本（可更多）</text>
    <text class="gesture-hint">短按：开始/停止/保存（满3个再按=完成注册）｜ 滑动：选择功能 ｜ 双击：退出</text>
    
    <view class="progress-bar">
      <text class="progress-text">{{progressText}}</text>
      <view class="progress-indicator">
        <view class="progress-dot {{progressDots[0]}}"></view>
        <view class="progress-dot {{progressDots[1]}}"></view>
        <view class="progress-dot {{progressDots[2]}}"></view>
      </view>
    </view>
    
    <view class="waveform-container">
      <text class="waveform-label">声音样本</text>
      <view class="prompt-box">
        <text class="prompt-label">请朗读</text>
        <text class="prompt-text">{{promptText}}</text>
      </view>
      <view class="waveform-display">
        <view wx:for="{{waveformData}}" wx:key="index" wx:for-item="item">
          <view class="waveform-bar" style="height: {{item * 100}}%;"></view>
        </view>
      </view>
    </view>
    
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
      
      <button bindtap="cancelEnroll" class="cancel-btn">
        <text class="btn-main-text">取消返回</text>
      </button>
    </view>

    <view class="sim-tap" bindtap="handleTap" bindlongpress="handleDoubleTap">
      <text class="sim-tap-text">仿真操作：点此=短按（开始/停止/保存/完成）｜ 长按此区域=退出 ｜ 键盘双击空格=退出</text>
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
  margin-bottom: 8px;
}

.instruction {
  font-size: 21px;
  color: #FFFFFF;
  margin-bottom: 16px;
  text-align: center;
  text-shadow: 0 0 4px rgba(255, 255, 255, 0.3);
}

.gesture-hint {
  font-size: 16px;
  color: #E6E6E6;
  margin-bottom: 12px;
  text-align: center;
  opacity: 1;
  text-shadow: 0 0 4px rgba(255, 255, 255, 0.2);
}

.progress-bar {
  width: 100%;
  background-color: #1a1a1a;
  border-radius: 12px;
  padding: 16px;
  margin-bottom: 16px;
  border: 2px solid #333333;
}

.progress-text {
  font-size: 22px;
  color: #7DFF90;
  font-weight: bold;
  display: block;
  margin-bottom: 12px;
  text-align: center;
  text-shadow: 0 0 6px rgba(64, 255, 94, 0.7);
}

.progress-indicator {
  display: flex;
  justify-content: center;
  gap: 20px;
}

.progress-dot {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  background-color: #333333;
  border: 3px solid #666666;
}

.progress-dot.completed {
  background-color: #40FF5E;
  border-color: #40FF5E;
}

.waveform-container {
  width: 100%;
  background-color: #1a1a1a;
  border-radius: 12px;
  padding: 16px;
  margin-bottom: 16px;
  border: 2px solid #333333;
}

.waveform-label {
  font-size: 22px;
  font-weight: bold;
  color: #40FF5E;
  display: block;
  margin-bottom: 12px;
}

.prompt-box {
  width: 100%;
  background-color: #0d1a0d;
  border: 2px dashed #40FF5E;
  border-radius: 12px;
  padding: 16px;
  margin-bottom: 12px;
  text-align: center;
}

.prompt-label {
  font-size: 16px;
  color: #40FF5E;
  opacity: 0.7;
  display: block;
  margin-bottom: 8px;
}

.prompt-text {
  font-size: 28px;
  font-weight: bold;
  color: #FFFFFF;
  line-height: 1.6;
  display: block;
  text-shadow: 0 0 5px rgba(255, 255, 255, 0.35);
}

.waveform-display {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  height: 80px;
  gap: 4px;
}

.waveform-bar {
  flex: 1;
  background-color: #40FF5E;
  border-radius: 2px;
  min-height: 4px;
  transition: height 0.1s ease;
}

.status-box {
  width: 100%;
  background-color: #1a1a1a;
  border: 3px solid #40FF5E;
  border-radius: 12px;
  padding: 20px;
  margin-bottom: 20px;
  text-align: center;
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
  font-size: 27px;
  color: #7DFF90;
  font-weight: bold;
  line-height: 1.6;
  text-shadow: 0 0 8px rgba(64, 255, 94, 0.8);
}

.status-box.recording .status-text {
  color: #FF4040;
}

.button-group {
  display: flex;
  flex-direction: column;
  gap: 12px;
  width: 100%;
}

button {
  padding: 18px;
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

.record-btn {
  background-color: #40FF5E;
  border-color: #40FF5E;
}

.stop-btn {
  background-color: #FF4040;
  border-color: #FF4040;
}

.save-btn {
  background-color: #4090FF;
  border-color: #4090FF;
}

.finish-btn {
  background-color: #40FF5E;
  border-color: #40FF5E;
}

.cancel-btn {
  background-color: #333333;
  border-color: #666666;
}

.btn-main-text {
  font-size: 22px;
  font-weight: bold;
  color: #000000;
  margin-bottom: 4px;
}

.stop-btn .btn-main-text,
.cancel-btn .btn-main-text {
  color: #FFFFFF;
}

.btn-sub-text {
  font-size: 14px;
  color: #000000;
  opacity: 0.8;
}

.cancel-btn .btn-sub-text {
  color: #CCCCCC;
}

.sim-tap {
  width: 100%;
  padding: 14px;
  background-color: rgba(64, 255, 94, 0.12);
  border: 2px dashed #40FF5E;
  border-radius: 12px;
  text-align: center;
  margin-top: 8px;
  box-sizing: border-box;
}

.sim-tap:active {
  background-color: rgba(64, 255, 94, 0.28);
}

.sim-tap-text {
  font-size: 16px;
  font-weight: bold;
  color: #7DFF90;
  text-shadow: 0 0 5px rgba(64, 255, 94, 0.6);
}
</style>
