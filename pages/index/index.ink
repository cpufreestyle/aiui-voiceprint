<script def>
{
  "navigationBarTitleText": "听障助手",
  "description": "主页，展示声纹管理界面，包含已注册用户列表、注册与验证入口，以及系统状态概览。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "userCount": {
          "type": "number",
          "description": "已注册声纹用户数量"
        },
        "status": {
          "type": "string",
          "enum": ["idle", "recording", "analyzing", "verified", "denied"],
          "description": "当前系统状态"
        },
        "statusText": {
          "type": "string",
          "description": "状态栏展示文字"
        },
        "registeredUsers": {
          "type": "array",
          "description": "已注册声纹用户列表",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string", "description": "用户唯一标识" },
              "name": { "type": "string", "description": "用户姓名" },
              "enrolledAt": { "type": "number", "description": "注册时间戳" }
            }
          }
        },
        "viewMode": {
          "type": "string",
          "enum": ["list", "grid"],
          "description": "当前用户展示的视图模式"
        },
        "menuItems": {
          "type": "array",
          "description": "主页功能菜单项",
          "items": {
            "type": "object",
            "properties": {
              "key": { "type": "string", "description": "菜单项标识" },
              "label": { "type": "string", "description": "菜单项显示文字" },
              "selectedClass": { "type": "string", "description": "当前是否高亮选中的样式类（selected 或空）" }
            }
          }
        },
        "selectedIndex": {
          "type": "number",
          "description": "当前高亮选中的菜单项索引"
        },
        "asrModeText": {
          "type": "string",
          "description": "app 内常听语音识别的模式徽章文案（Rokid ASR / 演示模式 / 不可用提示）"
        },
        "listening": {
          "type": "boolean",
          "description": "是否正在监听语音指令（识别器 onStart~onStop 之间）"
        },
        "listeningClass": {
          "type": "string",
          "description": "预计算的监听中样式类（active 或空），避免模板三元式"
        },
        "voiceHint": {
          "type": "string",
          "description": "最近一次语音识别结果或指令反馈提示文案"
        }
      },
      "required": ["userCount", "status", "statusText", "registeredUsers", "viewMode"]
    }
  }
}
</script>

<script setup>
import wx from 'wx';
import { routeKeyEvent, installKeyboardFallback, removeKeyboardFallback, safeBack } from '../../utils/gesture.js';
import { getActiveUser, setActiveUser, reconcileActiveUser } from '../../utils/active-user.js';
import { initAsr, startAsr, stopAsr, isAsrAvailable, asrMode } from '../../utils/asr.js';
import { speak } from '../../utils/tts.js';
import { routeIntent } from '../../utils/intent-router.js';

export default {
  data: {
    userCount: 0,
    status: 'idle',
    statusText: '就绪',
    registeredUsers: [],
    viewMode: 'list',
    // 默认聚焦「拍照识别」（首项 + selectedIndex=0），其余三项按语音常用度排列
    menuItems: [
      { key: 'media', label: '拍照识别', selectedClass: 'selected' },
      { key: 'conversation', label: '对话字幕', selectedClass: '' },
      { key: 'enroll', label: '录入声纹', selectedClass: '' },
      { key: 'verify', label: '验证身份', selectedClass: '' }
    ],
    selectedIndex: 0,
    // 预计算文本，避免模板三元式触发 ink 静态检查告警（missing from data）
    toggleText: '切换到网格',
    // 当前启用身份
    activeUserId: '',
    activeName: '未设置',
    // ====== app 内常听语音控制（见 setupVoiceControl）======
    asrModeText: '',
    listening: false,
    listeningClass: '',
    voiceHint: ''
  },

  onLoad() {
    this.loadVoiceprintDB();
    installKeyboardFallback(this);
    this.refreshMenuSelection();
  },

  onShow() {
    this.loadVoiceprintDB();
    installKeyboardFallback(this);
    this.setupVoiceControl();
  },

  onHide() {
    removeKeyboardFallback(this);
    this.teardownVoiceControl();
  },

  onKeyDown(event) {
    this._lastFrameworkKey = Date.now();
    routeKeyEvent(this, event, 'down');
  },

  onKeyUp(event) {
    if (!event) return;
    routeKeyEvent(this, event, 'up');
  },
  // 镜腿短按：进入当前高亮选中的功能
  handleTap() {
    this.enterSelected();
  },
  // 进入当前选中的菜单项
  enterSelected() {
    const item = this.data.menuItems[this.data.selectedIndex];
    if (!item) return;
    if (item.key === 'enroll') {
      this.goToEnroll();
    } else if (item.key === 'verify') {
      this.goToVerify();
    } else if (item.key === 'conversation') {
      this.goToConversation();
    } else if (item.key === 'media') {
      this.goToMedia();
    }
  },
  // 镜腿双击：退出（主页为顶层，尝试返回宿主/上一级）
  handleDoubleTap() {
    this.exitApp();
  },

  // 退出当前页面 / 返回宿主
  exitApp() {
    safeBack();
  },
  // 镜腿滑动：在菜单项间移动高亮（滑块），作为「滑动选取」；短按进入选中项。
  // 眼镜镜腿仅一条轴，系统上报 ArrowUp/ArrowDown；仿真平台键盘为 ArrowLeft/ArrowRight。
  // 前滑/左滑 → 上移高亮，后滑/右滑 → 下移高亮。
  handleSwipe(direction) {
    const count = this.data.menuItems.length;
    let idx = this.data.selectedIndex;
    if (direction === 'up' || direction === 'left') {
      idx = (idx - 1 + count) % count;
    } else if (direction === 'down' || direction === 'right') {
      idx = (idx + 1) % count;
    }
    this.setData({ selectedIndex: idx });
    this.refreshMenuSelection(idx);
  },

  // 预计算菜单高亮样式：把模板三元式 selectedIndex === index ? ... 改为简单字段，
  // 消除 ink 运行时“missing from data”静态检查告警。
  refreshMenuSelection(idx) {
    const sel = (typeof idx === 'number') ? idx : this.data.selectedIndex;
    const items = this.data.menuItems;
    const updated = items.map((it, i) => Object.assign({}, it, { selectedClass: i === sel ? 'selected' : '' }));
    this.setData({ menuItems: updated });
  },

  loadVoiceprintDB() {
    const db = wx.getStorageSync('voiceprint_db');
    if (db && db.users) {
      // 兼容旧数据：早期版本可能未给每条记录写入 id，
      // 会导致「删除」按 id 过滤失效，且渲染报 item.id missing。
      // 此处自动补齐 id 并写回存储，根治脏数据。
      let migrated = false;
      const users = db.users.map((u, i) => {
        if (u.id == null) {
          migrated = true;
          return Object.assign({}, u, { id: 'user_' + (u.enrolledAt || Date.now()) + '_' + i });
        }
        return u;
      });
      if (migrated) {
        db.users = users;
        try { wx.setStorageSync('voiceprint_db', db); } catch (e) {}
      }
      // 读取当前启用身份，并在列表上标注
      reconcileActiveUser();
      const active = getActiveUser();
      const activeId = active ? active.id : '';
      this.setData({
        userCount: users.length,
        activeUserId: activeId,
        activeName: active ? active.name : '未设置',
        registeredUsers: users.map((u) => ({
          id: u.id,
          name: u.name,
          enrolledAt: this.formatTime(u.enrolledAt),
          isActive: u.id === activeId,
          activeClass: u.id === activeId ? 'active' : '',
          activeTag: u.id === activeId ? '当前' : '启用'
        }))
      });
    } else {
      this.setData({ userCount: 0, activeUserId: '', activeName: '未设置', registeredUsers: [] });
    }
  },

  // 点击某个声纹卡片：设为当前启用身份，并刷新列表
  switchActiveUser(event) {
    const userId = event.currentTarget.dataset.id;
    if (!userId || userId === this.data.activeUserId) return;
    const user = setActiveUser(userId);
    if (user) {
      const app = getApp();
      if (app && app.globalData && app.globalData.vibrationEnabled) {
        try { wx.vibrateShort(); } catch (e) {}
      }
      this.setData({ statusText: '当前身份：' + user.name });
      this.loadVoiceprintDB();
    }
  },

  goToEnroll() {
    // 离开主页前先停常听，避免与目标页自己的 ASR 抢占同一个识别器单例
    this.teardownVoiceControl();
    wx.navigateTo({
      url: '/pages/enroll/enroll'
    });
  },

  goToVerify() {
    this.teardownVoiceControl();
    wx.navigateTo({
      url: '/pages/verify/verify'
    });
  },

  goToConversation() {
    this.teardownVoiceControl();
    wx.navigateTo({
      url: '/pages/conversation/conversation'
    });
  },

  // 进入图形识别模式：选中/短按进入时不自动拍照，让用户先取景，
  // 语音「开始拍照」走 startShootByVoice() 直接自动拍
  goToMedia() {
    this.teardownVoiceControl();
    wx.navigateTo({
      url: '/pages/media/media?mode=shape'
    });
  },

  // 语音「开始拍照」直达：进入图形识别页并自动拍照 + 分析（autoStart=1）
  startShootByVoice() {
    this.teardownVoiceControl();
    wx.navigateTo({
      url: '/pages/media/media?mode=shape&autoStart=1'
    });
  },

  // 语音「生成相似图 / 发到手机」直达：进入生成页并自动跑全流程（autoStart=1）
  goToGenimg() {
    this.teardownVoiceControl();
    wx.navigateTo({
      url: '/pages/genimg/genimg?mode=genimg&autoStart=1'
    });
  },

  // ====== 语音控制（app 内 ASR 常听：不依赖系统语音路由，自己听自己拍）======

  // 进入主页即开始常听语音指令；无 ASR 能力（仿真/非 Rokid 设备）时诚实降级为
  // 「仅滑动 + 短按」提示，不阻塞、不静默卡死原有手势路径。
  setupVoiceControl() {
    if (!isAsrAvailable()) {
      this.setData({ asrModeText: '语音不可用，用滑动+短按', listening: false, listeningClass: '' });
      // 诚实播报：无 ASR 能力时不能说"说话即可"，改为提示用滑动+短按操作
      speak('已进入听障助手，当前默认拍照识别，语音识别当前不可用，请用滑动选择、短按进入');
      return;
    }
    const that = this;
    this._voiceActive = true;
    initAsr({
      onStart: function () {
        that.setData({ listening: true, listeningClass: 'active' });
      },
      onFinal: function (text) {
        that.setData({ listening: false, listeningClass: '' });
        const navigated = that.onVoiceCommand(text);
        // 未跳转（指令未命中导航类，或明确留在主页）才重新开始听下一句；
        // 已跳转的话目标页面 onHide/onShow 会各自接管 ASR，这里不再抢着 restart。
        if (!navigated) that.scheduleRestartAsr();
      },
      onError: function (err) {
        console.log('[index] ASR 错误: ' + (err && err.message ? err.message : err));
        that.setData({ listening: false, listeningClass: '' });
        that.scheduleRestartAsr();
      }
    });
    this.setData({ asrModeText: asrMode() === 'rokid' ? 'Rokid ASR 聆听中' : '演示模式（模拟语音）' });
    startAsr({ lang: 'zh_CN' });
    speak('已进入听障助手，当前默认拍照识别，说"开始拍照"即可，或说对话字幕、生成相似图、录入声纹、验证身份');
  },

  // 真机识别器每次 onStop（=一次 onFinal/onError）后需要重新 start 才能继续听下一句。
  // 用 setTimeout 隔一拍再 start，避免在事件回调里同步重入 start 造成递归/时序问题。
  scheduleRestartAsr() {
    const that = this;
    if (this._voiceRestartTimer) return;
    this._voiceRestartTimer = setTimeout(function () {
      that._voiceRestartTimer = null;
      if (!that._voiceActive || !isAsrAvailable()) return;
      startAsr({ lang: 'zh_CN' });
    }, 400);
  },

  // 离开主页（onHide / 导航到子页面）时停止常听，避免和子页面自己的 ASR/相机抢占麦克风
  teardownVoiceControl() {
    this._voiceActive = false;
    if (this._voiceRestartTimer) {
      try { clearTimeout(this._voiceRestartTimer); } catch (e) {}
      this._voiceRestartTimer = null;
    }
    stopAsr();
  },

  // 语音指令分类执行。返回 true 表示已跳转到其它页面（调用方不再 restart 常听），
  // 返回 false/undefined 表示仍留在主页（继续常听下一句）。
  onVoiceCommand(text) {
    const raw = (text || '').trim();
    if (!raw) {
      this.setData({ voiceHint: '没听清，请再说一次' });
      return false;
    }
    this.setData({ voiceHint: '听到："' + raw + '"' });

    // 优先复用语音直呼意图路由器对 拍照(shape)/对话字幕(caption) 的判定，
    // 与 OS 语音直呼技能共用同一套关键词规则，避免两处维护、逐渐漂移。
    const route = routeIntent(raw);
    if (route.mode === 'shape' && route.confidence >= 0.9) {
      this.startShootByVoice();
      return true;
    }
    if (route.mode === 'caption' && route.confidence >= 0.9) {
      this.goToConversation();
      return true;
    }
    if (route.mode === 'genimg' && route.confidence >= 0.9) {
      this.goToGenimg();
      return true;
    }
    if (route.mode === 'home' && route.confidence >= 0.9) {
      // 明确说了「打开/进入听障助手」而已在主页：如实告知已在主页，而非误报"没听懂"
      this.setData({ voiceHint: '已在听障助手主页' });
      return false;
    }

    if (/录入|注册|声纹注册/.test(raw)) {
      this.goToEnroll();
      return true;
    }
    if (/验证/.test(raw)) {
      this.goToVerify();
      return true;
    }
    if (/下一个|下一项|切换/.test(raw)) {
      this.handleSwipe('down');
      this.setData({ voiceHint: '已切换到：' + this.data.menuItems[this.data.selectedIndex].label });
      return false;
    }
    if (/上一个|上一项/.test(raw)) {
      this.handleSwipe('up');
      this.setData({ voiceHint: '已切换到：' + this.data.menuItems[this.data.selectedIndex].label });
      return false;
    }

    // 都不命中：忽略并继续听，给轻提示而非报错卡死
    this.setData({ voiceHint: '没听懂："' + raw + '"，请再说一次' });
    return false;
  },

  toggleViewMode() {
    const newMode = this.data.viewMode === 'list' ? 'grid' : 'list';
    const toggleText = newMode === 'list' ? '切换到网格' : '切换到列表';
    this.setData({
      viewMode: newMode,
      toggleText: toggleText
    });
    this.setData({ statusText: `视图：${newMode === 'list' ? '列表' : '网格'}` });
  },

  clearAllUsers() {
    const db = wx.getStorageSync('voiceprint_db');
    if (db) {
      db.users = [];
      wx.setStorageSync('voiceprint_db', db);
      this.loadVoiceprintDB();
    }
  },

  deleteUser(event) {
    const userId = event.currentTarget.dataset.id;
    const db = wx.getStorageSync('voiceprint_db');
    if (db && db.users) {
      db.users = db.users.filter((u) => u.id !== userId);
      wx.setStorageSync('voiceprint_db', db);
      reconcileActiveUser(); // 若删掉的是当前身份，清空启用标记
      this.loadVoiceprintDB();
    }
  },

  formatTime(timestamp) {
    if (!timestamp) return '未知';
    const date = new Date(timestamp);
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    return `${month}/${day} ${hours}:${minutes}`;
  }
}
</script>

<page>
  <view class="page-container">
    <view class="header">
      <text class="title">听障助手</text>
      <text class="subtitle">说话人识别系统</text>
    </view>

    <view class="status-card">
      <view class="status-row">
        <text class="status-label">状态</text>
        <text class="status-value">{{statusText}}</text>
      </view>
      <view class="status-row">
        <text class="status-label">已注册用户</text>
        <text class="status-value">{{userCount}}</text>
      </view>
      <view class="status-row" ink:if="{{userCount > 0}}">
        <text class="status-label">当前身份</text>
        <text class="status-value active-name">{{activeName}}</text>
      </view>
    </view>

    <view class="action-row">
      <view
        class="menu-item {{item.selectedClass}}"
        ink:for="{{menuItems}}"
        ink:key="key"
        bindtap="enterSelected">
        <text class="menu-text">{{item.label}}</text>
      </view>
    </view>

    <view class="voice-panel">
      <text class="voice-badge">🎙 语音：说"开始拍照"即可直接拍摄</text>
      <text class="voice-mode-text {{listeningClass}}">{{asrModeText}}</text>
    </view>
    <view class="voice-hint-row" ink:if="{{voiceHint !== ''}}">
      <text class="voice-hint-text">{{voiceHint}}</text>
    </view>

    <view class="view-toggle" ink:if="{{userCount > 0}}">
      <button class="btn-toggle" bindtap="toggleViewMode">
        <text>{{toggleText}}</text>
      </button>
    </view>

    <view class="users-section" ink:if="{{userCount > 0}}">
      <text class="section-title">已注册声纹（点击切换当前身份）</text>
      
      <scroll-view class="user-list" scroll-y="true" ink:if="{{viewMode === 'list'}}">
        <view class="user-card {{item.activeClass}}" ink:for="{{registeredUsers}}" ink:key="id">
          <view class="user-info" bindtap="switchActiveUser" data-id="{{item.id}}">
            <text class="user-name">{{item.name}}</text>
            <text class="user-time">{{item.enrolledAt}}</text>
          </view>
          <view class="user-actions">
            <button class="btn-switch {{item.activeClass}}" bindtap="switchActiveUser" data-id="{{item.id}}">
              <text>{{item.activeTag}}</text>
            </button>
            <button class="btn-delete" bindtap="deleteUser" data-id="{{item.id}}">
              <text>删除</text>
            </button>
          </view>
        </view>
      </scroll-view>

      <view class="user-grid" ink:if="{{viewMode === 'grid'}}">
        <view class="grid-card {{item.activeClass}}" ink:for="{{registeredUsers}}" ink:key="id" bindtap="switchActiveUser" data-id="{{item.id}}">
          <text class="grid-tag" ink:if="{{item.isActive}}">当前</text>
          <text class="grid-name">{{item.name}}</text>
          <text class="grid-time">{{item.enrolledAt}}</text>
        </view>
      </view>
    </view>

    <view class="empty-state" ink:if="{{userCount === 0}}">
      <text class="empty-text">暂无声纹记录</text>
      <text class="empty-hint">点击"录入声纹"开始</text>
    </view>

    <view class="footer" ink:if="{{userCount > 0}}">
      <button class="btn-clear" bindtap="clearAllUsers">
        <text>清空全部</text>
      </button>
    </view>

    <view class="key-hints">
      <text class="hint-text">滑动：选择功能 ｜ 短按：进入 ｜ 双击：退出 ｜ 返回：后退</text>
    </view>

    <view class="sim-tap" bindtap="handleTap" bindlongpress="handleDoubleTap">
      <text class="sim-tap-text">仿真操作：点此=短按（进入）｜ 长按此区域=退出 ｜ 键盘双击空格=退出</text>
    </view>
  </view>
</page>

<style>
.page-container {
  display: flex;
  flex-direction: column;
  width: var(--app-width, 448px);
  min-height: var(--app-height-min, 120px);
  max-height: var(--app-height-max, 352px);
  background-color: var(--color-background, #000000);
  padding: var(--spacing-md, 16px);
  gap: var(--spacing-md, 12px);
  box-sizing: border-box;
}

.header {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}

.title {
  font-size: 22px;
  font-weight: bold;
  color: var(--color-primary, #40FF5E);
}

.subtitle {
  font-size: 12px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.6));
}

.version {
  font-size: 11px;
  margin-top: 4px;
  letter-spacing: 1px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.45));
}

.status-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: var(--spacing-md, 12px);
  background-color: var(--color-surface, rgba(64, 255, 94, 0.05));
  border: var(--border-width-default, 2px) solid var(--border-color-default, var(--color-primary-40, rgba(64, 255, 94, 0.4)));
  border-radius: var(--radius-md, 12px);
}

.status-row {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
}

.status-label {
  font-size: 16px;
  color: var(--color-text-secondary, rgba(120, 255, 140, 0.9));
}

.status-value {
  font-size: 19px;
  font-weight: bold;
  color: #7DFF90;
  text-shadow: 0 0 6px rgba(64, 255, 94, 0.7);
}

.active-name {
  color: #FFFFFF;
}

.action-row {
  display: flex;
  flex-direction: row;
  gap: var(--spacing-sm, 8px);
}

.menu-item {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 12px;
  background-color: transparent;
  border: var(--border-width-default, 2px) solid var(--color-primary, #40FF5E);
  border-radius: var(--radius-md, 12px);
  opacity: 0.5;
  transition: all 0.15s ease;
}

.menu-item.selected {
  background-color: transparent;
  border-color: #FFFFFF;
  opacity: 1;
}

.menu-text {
  font-size: 14px;
  font-weight: bold;
  color: var(--color-primary, #40FF5E);
}

.menu-item.selected .menu-text {
  color: #FFFFFF;
}

.voice-panel {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
  padding: 8px 12px;
  background-color: rgba(64, 255, 94, 0.06);
  border: var(--border-width-thin, 1px) solid var(--border-color-muted, rgba(64, 255, 94, 0.25));
  border-radius: var(--radius-sm, 8px);
}

.voice-badge {
  font-size: 12px;
  color: var(--color-text-secondary, rgba(120, 255, 140, 0.85));
}

.voice-mode-text {
  font-size: 11px;
  font-weight: bold;
  color: rgba(64, 255, 94, 0.6);
}

.voice-mode-text.active {
  color: #40FF5E;
  text-shadow: 0 0 6px rgba(64, 255, 94, 0.8);
}

.voice-hint-row {
  display: flex;
  justify-content: center;
}

.voice-hint-text {
  font-size: 12px;
  color: #FFC93C;
  text-align: center;
}

.view-toggle {
  display: flex;
  justify-content: center;
}

.btn-toggle {
  padding: 8px 16px;
  background-color: transparent;
  border: var(--border-width-thin, 1px) solid var(--color-primary-60, rgba(64, 255, 94, 0.6));
  border-radius: var(--radius-sm, 8px);
}

.btn-toggle text {
  font-size: 12px;
  color: var(--color-primary-60, rgba(64, 255, 94, 0.6));
}

.users-section {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.section-title {
  font-size: 13px;
  font-weight: bold;
  color: var(--color-text-primary, #40FF5E);
}

.user-list {
  max-height: 120px;
}

.user-card {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  padding: 10px;
  background-color: var(--color-surface, rgba(64, 255, 94, 0.05));
  border: var(--border-width-thin, 1px) solid var(--border-color-muted, rgba(64, 255, 94, 0.2));
  border-radius: var(--radius-sm, 8px);
  margin-bottom: 6px;
}

.user-card.active {
  border-color: #40FF5E;
  background-color: rgba(64, 255, 94, 0.14);
}

.user-info {
  display: flex;
  flex-direction: column;
  gap: 2px;
  flex: 1;
}

.user-actions {
  display: flex;
  flex-direction: row;
  gap: 6px;
  align-items: center;
}

.btn-switch {
  padding: 6px 12px;
  background-color: transparent;
  border: 1px solid var(--color-primary-60, rgba(64, 255, 94, 0.6));
  border-radius: 6px;
}

.btn-switch text {
  font-size: 11px;
  color: var(--color-primary, #40FF5E);
}

.btn-switch.active {
  background-color: #40FF5E;
  border-color: #40FF5E;
}

.btn-switch.active text {
  color: #000000;
  font-weight: bold;
}

.user-name {
  font-size: 13px;
  color: var(--color-text-primary, #40FF5E);
}

.user-time {
  font-size: 10px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.4));
}

.btn-delete {
  padding: 6px 12px;
  background-color: transparent;
  border: var(--border-width-thin, 1px) solid var(--border-color-danger, #FF4040);
  border-radius: var(--radius-sm, 6px);
}

.btn-delete text {
  font-size: 11px;
  color: var(--border-color-danger, #FF4040);
}

.user-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 8px;
  max-height: 120px;
  overflow-y: auto;
}

.grid-card {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 12px;
  background-color: var(--color-surface, rgba(64, 255, 94, 0.05));
  border: var(--border-width-thin, 1px) solid var(--border-color-muted, rgba(64, 255, 94, 0.2));
  border-radius: var(--radius-sm, 8px);
  gap: 4px;
}

.grid-card.active {
  border-color: #40FF5E;
  background-color: rgba(64, 255, 94, 0.14);
}

.grid-tag {
  font-size: 10px;
  font-weight: bold;
  color: #000000;
  background-color: #40FF5E;
  border-radius: 4px;
  padding: 1px 6px;
  margin-bottom: 2px;
}

.grid-name {
  font-size: 13px;
  font-weight: bold;
  color: var(--color-text-primary, #40FF5E);
}

.grid-time {
  font-size: 10px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.4));
}

.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 24px;
  gap: 6px;
}

.empty-text {
  font-size: 14px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.4));
}

.empty-hint {
  font-size: 11px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.3));
}

.footer {
  display: flex;
  justify-content: center;
}

.btn-clear {
  padding: 8px 20px;
  background-color: transparent;
  border: var(--border-width-thin, 1px) solid var(--border-color-danger, #FF4040);
  border-radius: var(--radius-sm, 8px);
}

.btn-clear text {
  font-size: 12px;
  color: var(--border-color-danger, #FF4040);
}

.key-hints {
  display: flex;
  justify-content: center;
  padding: 4px;
}

.hint-text {
  font-size: 14px;
  color: rgba(120, 255, 140, 0.7);
  text-shadow: 0 0 4px rgba(64, 255, 94, 0.4);
}

.sim-tap {
  width: 100%;
  padding: 14px;
  background-color: rgba(64, 255, 94, 0.12);
  border: 2px dashed #40FF5E;
  border-radius: 12px;
  text-align: center;
  margin-top: 4px;
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
