<script def>
{
  "navigationBarTitleText": "声纹验证 - 无障碍版",
  "description": "声纹验证页面 - 为听障人士优化，提供实时波形可视化、振动反馈和大字体文字提示",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "status": {
          "type": "string",
          "description": "当前验证状态文字提示"
        },
        "isVerifying": {
          "type": "boolean",
          "description": "是否正在验证"
        },
        "verificationPath": {
          "type": "string",
          "description": "验证录音文件路径"
        },
        "waveformData": {
          "type": "array",
          "description": "实时波形数据数组",
          "items": {
            "type": "number"
          }
        },
        "result": {
          "type": "object",
          "description": "验证结果对象",
          "properties": {
            "success": {
              "type": "boolean",
              "description": "验证是否成功"
            },
            "confidence": {
              "type": "string",
              "description": "验证置信度"
            },
            "message": {
              "type": "string",
              "description": "验证结果消息"
            },
            "timestamp": {
              "type": "string",
              "description": "验证时间戳"
            }
          }
        }
      },
      "required": ["status", "isVerifying", "waveformData"]
    }
  }
}
</script>

<script setup>
import wx from 'wx';
import { safeBack } from '../../utils/gesture.js';
import { gestureKeyDown, gestureKeyUp, shellInstallKeyboard, shellRemoveKeyboard } from '../../utils/page-shell.js';
import { acquireRecorderManager } from '../../utils/recorder.js';
import { extractFeatures, identifySpeaker, isRecordingValid } from '../../utils/voiceprint-engine.js';
import { setupRecorderListeners, startRecordingSession, stopRecordingSession } from '../../utils/recording-session.js';
import { speak } from '../../utils/tts.js';

export default {
  data: {
    status: '准备就绪 - 点击下方按钮开始验证',
    isVerifying: false,
    verificationPath: null,
    waveformData: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    result: null,
    // 预计算：状态框样式类（合并 isVerifying/result 的三元式，消除 ink 静态检查告警）
    statusBoxClass: 'status-box',
    frameBuffers: [],
    recorderManager: null
  },
  onLoad() {
    console.log('验证页面加载 - 无障碍模式');
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

    startVerification() {
      startRecordingSession(this, {
        recordingKey: 'isVerifying',
        classKey: 'statusBoxClass',
        recordingClass: 'verifying',
        statusText: '正在录音 - 请清晰说话3秒钟',
        startSpeak: '请说话进行验证',
        stopMethod: 'stopVerification',
        extraData: { result: null }
      });
    },

    stopVerification() {
      stopRecordingSession(this,
        {
          recordingKey: 'isVerifying',
          classKey: 'statusBoxClass',
          extraData: { verificationPath: 'verification_' + Date.now() }
        },
        (combinedAudio) => {
          // 执行验证
          this.verifyVoiceprint(combinedAudio);
        }
      );
    },
    
    verifyVoiceprint(audioData) {
      const that = this;
      that.setData({ status: '正在验证身份...' });

      setTimeout(function() {
        // 用真实声纹引擎比对已注册用户
        let features = null;
        try {
          features = extractFeatures(audioData || new Uint8Array(0));
        } catch (e) {
          console.log('提取特征失败: ' + e);
        }

        // 录音无效（太短 / 静音）直接提示重试，不进入比对——
        // 否则全 0 特征会给出误导性分数（可能误判成功或以假分数拒绝）。
        if (!isRecordingValid(audioData, features)) {
          const invalid = {
            success: false,
            confidence: '0.00',
            message: '没录到清晰声音，请重试',
            timestamp: new Date().toLocaleString()
          };
          that.setData({ status: invalid.message, result: invalid, statusBoxClass: 'failed' });
          speak('没录到清晰声音，请重试');
          return;
        }

        const db = wx.getStorageSync('voiceprint_db');
        if (!db || !db.users || db.users.length === 0) {
          const result = {
            success: false,
            confidence: '0.00',
            message: '暂无注册用户，请先录入声纹',
            timestamp: new Date().toLocaleString()
          };
          that.setData({ status: result.message, result: result, statusBoxClass: 'failed' });
          return;
        }

        const candidates = identifySpeaker(features, db.users, 0.65);
        const top = candidates[0];
        const success = top && top.matched;
        const result = {
          success: success,
          confidence: top ? top.score.toFixed(2) : '0.00',
          message: success ? ('身份验证成功：' + top.name) : '身份验证失败',
          timestamp: new Date().toLocaleString()
        };

        that.setData({
          status: result.message,
          result: result,
          statusBoxClass: success ? 'success' : 'failed'
        });

        // 语音提示：验证结果
        speak(result.message);
        // 振动反馈结果
        const app = getApp();
        if (app && app.globalData && app.globalData.vibrationEnabled) {
          if (success) {
            wx.vibrateShort();
            setTimeout(() => wx.vibrateShort(), 200);
          } else {
            wx.vibrateLong();
          }
        }
      }, 1500);
    },
    
    goHome() {
      safeBack();
    },
    
    tryAgain() {
      this.setData({
        status: '准备就绪 - 点击下方按钮开始验证',
        isVerifying: false,
        statusBoxClass: '',
        verificationPath: null,
        waveformData: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        result: null,
        frameBuffers: []
      });
    },

  // 镜腿短按：进入 - 开始验证 / 完成后重新验证
  handleTap() {
    if (this.data.isVerifying) {
      return;
    } else if (this.data.result) {
      this.tryAgain();
      this.startVerification();
    } else {
      this.startVerification();
    }
  },

  // 镜腿双击：退出（返回主页）
  handleDoubleTap() {
    this.goHome();
  },

  // 镜腿滑动：左右选择相邻功能（一侧→录入身份，另一侧→返回主页）
  handleSwipe(direction) {
    if (direction === 'left' || direction === 'up') {
      wx.redirectTo({ url: '/pages/enroll/enroll' });
    } else if (direction === 'right' || direction === 'down') {
      this.goHome();
    }
  }
}
</script>

<page>
  <view class="container">
    <text class="title">声纹验证</text>
    <text class="instruction">请清晰说话，验证您的身份</text>
    <text class="gesture-hint">短按：开始/重新验证 ｜ 滑动：选择功能 ｜ 双击：退出</text>
    
    <view class="waveform-container">
      <text class="waveform-label">实时波形：</text>
      <view class="waveform-display">
        <view ink:for="{{waveformData}}" ink:key="index" ink:for-item="item">
          <view class="waveform-bar" style="height: {{item * 100}}%;"></view>
        </view>
      </view>
    </view>
    
    <view class="{{statusBoxClass}}">
      <text class="status-text">{{status}}</text>
      <text class="confidence-text" ink:if="{{result}}">置信度: {{result.confidence}}</text>
    </view>
    
    <view class="result-details" ink:if="{{result}}">
      <text class="result-title">验证详情</text>
      <text class="result-item">时间: {{result.timestamp}}</text>
      <text class="result-item">结果: {{result.message}}</text>
      <text class="result-item">置信度: {{result.confidence}}</text>
    </view>
    
    <view class="button-group">
      <button bindtap="startVerification" disabled="{{isVerifying}}" class="verify-btn">
        <text class="btn-main-text">开始验证</text>
        <text class="btn-sub-text">录制3秒钟</text>
      </button>
      
      <button bindtap="tryAgain" class="retry-btn" ink:if="{{result}}">
        <text class="btn-main-text">重新验证</text>
      </button>
      
      <button bindtap="goHome" class="home-btn">
        <text class="btn-main-text">返回主页</text>
      </button>
    </view>

    <view class="sim-tap" bindtap="handleTap" bindlongpress="handleDoubleTap">
      <text class="sim-tap-text">仿真操作：点此=短按（开始验证）｜ 长按此区域=退出 ｜ 键盘双击空格=退出</text>
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

.waveform-container {
  width: 100%;
  background-color: #1a1a1a;
  border-radius: 12px;
  padding: 16px;
  margin-bottom: 16px;
  border: 2px solid #333333;
}

.waveform-label {
  font-size: 19px;
  color: #E6E6E6;
  display: block;
  margin-bottom: 12px;
  text-shadow: 0 0 4px rgba(255, 255, 255, 0.2);
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
  margin-bottom: 16px;
  text-align: center;
}

.status-box.verifying {
  background-color: #2a1a1a;
  border-color: #FF4040;
  animation: pulse 1s infinite;
}

.status-box.success {
  background-color: #1a2a1a;
  border-color: #40FF5E;
}

.status-box.failed {
  background-color: #2a1a1a;
  border-color: #FF4040;
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
  display: block;
  margin-bottom: 8px;
  text-shadow: 0 0 8px rgba(64, 255, 94, 0.8);
}

.confidence-text {
  font-size: 19px;
  color: #E6E6E6;
  display: block;
  text-shadow: 0 0 4px rgba(255, 255, 255, 0.2);
}

.status-box.verifying .status-text {
  color: #FF4040;
}

.status-box.success .status-text {
  color: #40FF5E;
}

.status-box.failed .status-text {
  color: #FF4040;
}

.result-details {
  width: 100%;
  background-color: #1a1a1a;
  border-radius: 12px;
  padding: 16px;
  margin-bottom: 16px;
  border: 2px solid #333333;
}

.result-title {
  font-size: 18px;
  font-weight: bold;
  color: #FFFFFF;
  display: block;
  margin-bottom: 12px;
}

.result-item {
  font-size: 19px;
  color: #E6E6E6;
  display: block;
  margin-bottom: 8px;
  line-height: 1.5;
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

.verify-btn {
  background-color: #40FF5E;
  border-color: #40FF5E;
}

.retry-btn {
  background-color: #4090FF;
  border-color: #4090FF;
}

.home-btn {
  background-color: #333333;
  border-color: #666666;
}

.btn-main-text {
  font-size: 22px;
  font-weight: bold;
  color: #000000;
  margin-bottom: 4px;
}

.home-btn .btn-main-text {
  color: #FFFFFF;
}

.btn-sub-text {
  font-size: 14px;
  color: #000000;
  opacity: 0.8;
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
