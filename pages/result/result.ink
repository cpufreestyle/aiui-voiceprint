<script def>
{
  "navigationBarTitleText": "验证结果 - 无障碍版",
  "description": "验证结果页面 - 为听障人士优化，提供大字体、高对比度的结果展示和振动反馈",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "title": {
          "type": "string",
          "description": "结果标题"
        },
        "message": {
          "type": "string",
          "description": "详细结果消息"
        },
        "isSuccess": {
          "type": "boolean",
          "description": "验证是否成功"
        },
        "confidence": {
          "type": "string",
          "description": "置信度分数"
        },
        "timestamp": {
          "type": "string",
          "description": "验证时间戳"
        }
      },
      "required": ["title", "message", "isSuccess"]
    }
  }
}
</script>

<script setup>
import wx from 'wx';
import { routeKeyEvent, installKeyboardFallback, removeKeyboardFallback, safeBack } from '../../utils/gesture.js';

export default {
  data: {
    title: '',
    message: '',
    isSuccess: false,
    confidence: '0.00',
    timestamp: '',
    // 预计算：结果图标/文案/样式类（避免模板三元式告警）
    resultIconClass: '',
    iconText: '',
    confidenceClass: '',
    resultLabelText: ''
  },
  onLoad(query) {
    console.log('结果页面加载 - 无障碍模式');
    const that = this;
    const success = query && query.success === 'true';
    const confidence = query && query.confidence ? query.confidence : (success ? '0.85' : '0.45');
    
    that.setData({
      isSuccess: success,
      title: success ? '✓ 验证成功' : '✗ 验证失败',
      message: success ? '身份确认通过' : '声纹不匹配，请重试',
      confidence: confidence,
      timestamp: new Date().toLocaleString(),
      resultIconClass: success ? 'success-icon' : 'failed-icon',
      iconText: success ? '✓' : '✗',
      confidenceClass: success ? 'success-value' : 'failed-value',
      resultLabelText: success ? '通过' : '未通过'
    });
    
    // 振动反馈
    const app = getApp();
    if (app && app.globalData && app.globalData.vibrationEnabled) {
      if (success) {
        // 成功：短振动两次
        wx.vibrateShort();
        setTimeout(() => wx.vibrateShort(), 200);
      } else {
        // 失败：长振动一次
        wx.vibrateLong();
      }
    }
  },

  onShow() {
    installKeyboardFallback(this);
  },

  onHide() {
    removeKeyboardFallback(this);
  },

  onUnload() {
    // 释放 window 级键盘兜底监听（redirectTo/navigateBack 走 onUnload，不一定触发 onHide）
    removeKeyboardFallback(this);
  },

  goHome() {
      safeBack();
    },
    tryAgain() {
      safeBack('/pages/verify/verify');
    },

  onKeyDown(event) {
    this._lastFrameworkKey = Date.now();
    routeKeyEvent(this, event, 'down');
  },

  onKeyUp(event) {
    if (!event) return;
    routeKeyEvent(this, event, 'up');
  },

  // 镜腿短按：进入 - 成功→返回主页，失败→重新验证
  handleTap() {
    if (this.data.isSuccess) {
      this.goHome();
    } else {
      this.tryAgain();
    }
  },

  // 镜腿双击：退出（返回主页）
  handleDoubleTap() {
    this.goHome();
  },

  // 镜腿滑动：左右选择相邻功能
  // 一侧→返回主页，另一侧→重新验证（仅失败时）
  handleSwipe(direction) {
    if (direction === 'right' || direction === 'down') {
      this.goHome();
    } else if (direction === 'left' || direction === 'up') {
      if (!this.data.isSuccess) {
        this.tryAgain();
      }
    }
  }
}
</script>

<page>
  <view class="container">
    <text class="gesture-hint">短按：成功→返回主页 / 失败→重新验证 ｜ 滑动：选择功能 ｜ 双击：退出</text>
    <view class="result-icon {{resultIconClass}}">
      <text class="icon-text">{{iconText}}</text>
    </view>
    
    <text class="title">{{title}}</text>
    <text class="message">{{message}}</text>
    
    <view class="details-box">
      <text class="detail-label">验证详情</text>
      <view class="detail-row">
        <text class="detail-key">置信度:</text>
        <text class="detail-value {{confidenceClass}}">{{confidence}}</text>
      </view>
      <view class="detail-row">
        <text class="detail-key">验证时间:</text>
        <text class="detail-value">{{timestamp}}</text>
      </view>
      <view class="detail-row">
        <text class="detail-key">验证状态:</text>
        <text class="detail-value {{confidenceClass}}">{{resultLabelText}}</text>
      </view>
    </view>
    
    <view class="button-group">
      <button bindtap="goHome" class="home-btn">
        <text class="btn-main-text">返回主页</text>
      </button>
      <button bindtap="tryAgain" class="retry-btn" wx:if="{{!isSuccess}}">
        <text class="btn-main-text">重新验证</text>
      </button>
    </view>

    <view class="sim-tap" bindtap="handleTap" bindlongpress="handleDoubleTap">
      <text class="sim-tap-text">仿真操作：点此=短按（成功→返回主页 / 失败→重新验证）｜ 长按此区域=退出 ｜ 键盘双击空格=退出</text>
    </view>
  </view>
</page>

<style>
.container {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  height: 100%;
  padding: 24px;
  background-color: #000000;
}

.gesture-hint {
  font-size: 16px;
  color: #E6E6E6;
  margin-bottom: 16px;
  text-align: center;
  opacity: 1;
  text-shadow: 0 0 4px rgba(255, 255, 255, 0.2);
}

.result-icon {
  width: 100px;
  height: 100px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  margin-bottom: 24px;
  border: 4px solid;
}

.success-icon {
  background-color: #1a2a1a;
  border-color: #40FF5E;
}

.failed-icon {
  background-color: #2a1a1a;
  border-color: #FF4040;
}

.icon-text {
  font-size: 60px;
  font-weight: bold;
}

.success-icon .icon-text {
  color: #40FF5E;
}

.failed-icon .icon-text {
  color: #FF4040;
}

.title {
  font-size: 40px;
  font-weight: bold;
  margin-bottom: 12px;
  text-align: center;
  text-shadow: 0 0 8px rgba(64, 255, 94, 0.5);
}

.success-icon ~ .title {
  color: #40FF5E;
}

.failed-icon ~ .title {
  color: #FF4040;
}

.message {
  font-size: 26px;
  color: #FFFFFF;
  margin-bottom: 32px;
  text-align: center;
  line-height: 1.6;
  text-shadow: 0 0 5px rgba(255, 255, 255, 0.3);
}

.details-box {
  width: 100%;
  background-color: #1a1a1a;
  border-radius: 12px;
  padding: 20px;
  margin-bottom: 32px;
  border: 2px solid #333333;
}

.detail-label {
  font-size: 18px;
  font-weight: bold;
  color: #FFFFFF;
  display: block;
  margin-bottom: 16px;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 12px;
  padding-bottom: 8px;
  border-bottom: 1px solid #333333;
}

.detail-row:last-child {
  border-bottom: none;
  margin-bottom: 0;
  padding-bottom: 0;
}

.detail-key {
  font-size: 18px;
  color: #BFBFBF;
}

.detail-value {
  font-size: 21px;
  color: #FFFFFF;
  font-weight: bold;
  text-shadow: 0 0 4px rgba(255, 255, 255, 0.25);
}

.success-value {
  color: #40FF5E;
}

.failed-value {
  color: #FF4040;
}

.button-group {
  display: flex;
  flex-direction: column;
  gap: 16px;
  width: 100%;
}

button {
  padding: 20px;
  border-radius: 12px;
  border: 3px solid;
  font-size: 20px;
  display: flex;
  flex-direction: column;
  align-items: center;
}

.home-btn {
  background-color: #40FF5E;
  border-color: #40FF5E;
}

.retry-btn {
  background-color: #4090FF;
  border-color: #4090FF;
}

.btn-main-text {
  font-size: 24px;
  font-weight: bold;
  color: #000000;
}

.retry-btn .btn-main-text {
  color: #FFFFFF;
}

.sim-tap {
  width: 100%;
  padding: 16px;
  background-color: rgba(64, 255, 94, 0.12);
  border: 2px dashed #40FF5E;
  border-radius: 12px;
  text-align: center;
  margin-top: 12px;
  box-sizing: border-box;
}

.sim-tap:active {
  background-color: rgba(64, 255, 94, 0.28);
}

.sim-tap-text {
  font-size: 17px;
  font-weight: bold;
  color: #7DFF90;
  text-shadow: 0 0 5px rgba(64, 255, 94, 0.6);
}
</style>
