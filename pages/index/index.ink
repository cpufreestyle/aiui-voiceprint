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
              "enrolledAt": { "type": "number", "description": "注册时间戳" },
              "selectedClass": { "type": "string", "description": "预留选中样式类（用户列表恒为空）" }
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
              "id": { "type": "string", "description": "菜单项标识（与 key 一致，供模板绑定）" },
              "label": { "type": "string", "description": "菜单项显示文字" },
              "selectedClass": { "type": "string", "description": "当前是否高亮选中的样式类（selected 或空）" }
            }
          }
        },
        "selectedIndex": {
          "type": "number",
          "description": "当前高亮选中的菜单项索引"
        }
      },
      "required": ["userCount", "status", "statusText", "registeredUsers", "viewMode"]
    }
  }
}
</script>

<script setup>
import wx from 'wx';
import { installKeyboardFallback, removeKeyboardFallback, safeBack } from '../../utils/gesture.js';
import { gestureKeyDown, gestureKeyUp, gestureVoiceWakeup } from '../../utils/page-shell.js';
import { getActiveUser, setActiveUser, reconcileActiveUser } from '../../utils/active-user.js';
import { speak } from '../../utils/tts.js';

export default {
  data: {
    userCount: 0,
    status: 'idle',
    statusText: '就绪',
    registeredUsers: [],
    viewMode: 'list',
    menuItems: [
      { key: 'enroll', id: 'enroll', label: '录入声纹', selectedClass: 'selected' },
      { key: 'verify', id: 'verify', label: '验证身份', selectedClass: '' },
      { key: 'conversation', id: 'conversation', label: '对话字幕', selectedClass: '' },
      { key: 'media', id: 'media', label: '拍摄解说', selectedClass: '' }
    ],
    selectedIndex: 0,
    // 预计算文本，避免模板三元式触发 ink 静态检查告警（missing from data）
    toggleText: '切换到网格',
    // 当前启用身份
    activeUserId: '',
    activeName: '未设置'
  },

  onLoad() {
    this.loadVoiceprintDB();
    installKeyboardFallback(this);
    this.refreshMenuSelection();
    this.speakWelcome();
  },

  onShow() {
    this.loadVoiceprintDB();
    installKeyboardFallback(this);
  },

  onHide() {
    removeKeyboardFallback(this);
  },

  speakWelcome() {
    const db = wx.getStorageSync('voiceprint_db');
    const count = (db && db.users) ? db.users.length : 0;
    const text = count === 0
      ? '欢迎使用听障助手。先选录入声纹，为家人或同事建立声纹；之后即可识别说话人、显示对话字幕。滑动选功能，短按进入。'
      : '欢迎使用听障助手。已录入 ' + count + ' 位说话人。选择对话字幕即可开始交流。';
    speak(text);
  },
  onKeyDown: gestureKeyDown,
  onKeyUp: gestureKeyUp,

  // 语音 / 触控唤醒通道（官方 onVoiceWakeup；触控唤醒 keyword = 'clickAiAssist'）
  onVoiceWakeup: gestureVoiceWakeup,
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
    safeBack(null, this);
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
          selectedClass: '',
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
    wx.navigateTo({
      url: '/pages/enroll/enroll'
    });
  },

  goToVerify() {
    wx.navigateTo({
      url: '/pages/verify/verify'
    });
  },

  goToConversation() {
    wx.navigateTo({
      url: '/pages/conversation/conversation'
    });
  },

  goToMedia() {
    wx.navigateTo({
      url: '/pages/media/media'
    });
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

  // 统一写库：失败时给失败提示，绝不假报成功（存储写满/异常时兜底）
  saveDb(db, okMsg) {
    try {
      wx.setStorageSync('voiceprint_db', db);
      if (okMsg) wx.showToast({ title: okMsg, icon: 'success', duration: 1500 });
      return true;
    } catch (e) {
      wx.showToast({ title: '保存失败，请清理存储后重试', icon: 'none', duration: 2000 });
      return false;
    }
  },

  clearAllUsers() {
    const db = wx.getStorageSync('voiceprint_db');
    if (db) {
      db.users = [];
      this.saveDb(db);
      this.loadVoiceprintDB();
    }
  },

  deleteUser(event) {
    const userId = event.currentTarget.dataset.id;
    const db = wx.getStorageSync('voiceprint_db');
    if (db && db.users) {
      db.users = db.users.filter((u) => u.id !== userId);
      this.saveDb(db);
      reconcileActiveUser(); // 若删掉的是当前身份，清空启用标记
      this.loadVoiceprintDB();
    }
  },

  // 重命名声纹：弹输入框改姓名，写回 voiceprint_db
  renameUser(event) {
    const that = this;
    const userId = event.currentTarget.dataset.id;
    const db = wx.getStorageSync('voiceprint_db');
    if (!db || !db.users) return;
    const user = db.users.find((u) => u.id === userId);
    if (!user) return;
    wx.showModal({
      title: '重命名声纹',
      editable: true,
      placeholderText: user.name || '输入新姓名',
      success(res) {
        if (!res.confirm) return;
        const name = (res.content || '').trim();
        if (!name) {
          wx.showToast({ title: '名字不能为空', icon: 'none', duration: 1500 });
          return;
        }
        const db2 = wx.getStorageSync('voiceprint_db');
        const u = db2 && db2.users ? db2.users.find((x) => x.id === userId) : null;
        if (!u) return;
        u.name = name;
        if (that.saveDb(db2, '已重命名：' + name)) {
          that.loadVoiceprintDB();
        }
      }
    });
  },

  // 导出声纹库：序列化为 JSON 复制到剪贴板，供换镜/多设备迁移
  exportDb() {
    const db = wx.getStorageSync('voiceprint_db');
    if (!db || !db.users || db.users.length === 0) {
      wx.showToast({ title: '声纹库为空，无可导出', icon: 'none', duration: 1800 });
      return;
    }
    const count = db.users.length;
    // 声纹模板属于生物特征信息，导出过剪贴板（明文、可被其他应用读取）前必须警示
    wx.showModal({
      title: '导出声纹库',
      content: '将复制 ' + count + ' 条声纹数据（含声纹特征模板，属于生物特征信息）到剪贴板。剪贴板为明文、其他应用可能读取，请只粘贴到可信位置。确认导出？',
      confirmText: '复制',
      success(res) {
        if (!res.confirm) return;
        const payload = {
          app: 'aiui-voiceprint',
          version: 1,
          exportedAt: Date.now(),
          users: db.users
        };
        try {
          wx.setClipboardData({
            data: JSON.stringify(payload),
            success() {
              wx.showToast({ title: '已复制 ' + count + ' 条声纹到剪贴板', icon: 'success', duration: 2000 });
            },
            fail() {
              wx.showToast({ title: '复制失败，请重试', icon: 'none', duration: 1800 });
            }
          });
        } catch (e) {
          wx.showToast({ title: '导出失败：' + e, icon: 'none', duration: 2000 });
        }
      }
    });
  },

  // 导入声纹库：从剪贴板读取 JSON，校验后按 id 去重合并（同 id 覆盖为新数据）
  importDb() {
    const that = this;
    wx.getClipboardData({
      success(res) {
        const raw = (res && res.data ? res.data : '').trim();
        if (!raw) {
          wx.showToast({ title: '剪贴板为空', icon: 'none', duration: 1500 });
          return;
        }
        let payload = null;
        try { payload = JSON.parse(raw); } catch (e) {
          wx.showToast({ title: '内容不是有效 JSON，导入取消', icon: 'none', duration: 2000 });
          return;
        }
        const users = payload && Array.isArray(payload.users) ? payload.users : null;
        if (!users || users.length === 0 ||
            !users.every((u) => u && u.id && u.name && u.template)) {
          wx.showToast({ title: '格式不符：缺少 users/模板，导入取消', icon: 'none', duration: 2200 });
          return;
        }
        wx.showModal({
          title: '导入声纹库',
          content: '将导入 ' + users.length + ' 条声纹（同名同 id 的会被覆盖）。确认导入？',
          success(m) {
            if (!m.confirm) return;
            const db = wx.getStorageSync('voiceprint_db') || { users: [] };
            if (!Array.isArray(db.users)) db.users = [];
            const byId = {};
            db.users.forEach((u) => { byId[u.id] = u; });
            users.forEach((u) => { byId[u.id] = u; });
            db.users = Object.keys(byId).map((k) => byId[k]);
            if (that.saveDb(db, '导入完成，共 ' + db.users.length + ' 条')) {
              reconcileActiveUser();
              that.loadVoiceprintDB();
            }
          }
        });
      },
      fail() {
        wx.showToast({ title: '读取剪贴板失败', icon: 'none', duration: 1500 });
      }
    });
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
        bindtap="enterSelected" data-gesture-ignore="1">
        <text class="menu-text">{{item.label}}</text>
      </view>
    </view>

    <view class="view-toggle" ink:if="{{userCount > 0}}">
      <button class="btn-toggle" bindtap="toggleViewMode" data-gesture-ignore="1">
        <text>{{toggleText}}</text>
      </button>
    </view>

    <view class="users-section" ink:if="{{userCount > 0}}">
      <text class="section-title">已注册声纹（点击切换当前身份）</text>
      
      <scroll-view class="user-list" scroll-y="true" ink:if="{{viewMode === 'list'}}">
        <view class="user-card {{item.activeClass}}" ink:for="{{registeredUsers}}" ink:key="id">
          <view class="user-info" bindtap="switchActiveUser" data-id="{{item.id}}" data-gesture-ignore="1">
            <text class="user-name">{{item.name}}</text>
            <text class="user-time">{{item.enrolledAt}}</text>
          </view>
          <view class="user-actions">
            <button class="btn-switch {{item.activeClass}}" bindtap="switchActiveUser" data-id="{{item.id}}" data-gesture-ignore="1">
              <text>{{item.activeTag}}</text>
            </button>
            <button class="btn-rename" bindtap="renameUser" data-id="{{item.id}}" data-gesture-ignore="1">
              <text>改名</text>
            </button>
            <button class="btn-delete" bindtap="deleteUser" data-id="{{item.id}}" data-gesture-ignore="1">
              <text>删除</text>
            </button>
          </view>
        </view>
      </scroll-view>

      <view class="user-grid" ink:if="{{viewMode === 'grid'}}">
        <view class="grid-card {{item.activeClass}}" ink:for="{{registeredUsers}}" ink:key="id" bindtap="switchActiveUser" data-id="{{item.id}}" data-gesture-ignore="1">
          <text class="grid-tag" ink:if="{{item.isActive}}">当前</text>
          <text class="grid-name">{{item.name}}</text>
          <text class="grid-time">{{item.enrolledAt}}</text>
        </view>
      </view>
    </view>

    <view class="onboarding" ink:if="{{userCount === 0}}">
      <text class="onb-title">首次使用引导</text>

      <view class="onb-step">
        <text class="onb-num">1</text>
        <text class="onb-text">录入声纹：进入「录入声纹」，按提示朗读 3 句以上，为一位家人或同事建档（建议每位都录一次）</text>
      </view>

      <view class="onb-step">
        <text class="onb-num">2</text>
        <text class="onb-text">验证身份：说一句话，系统判断当前说话的人是谁，并给出相似度</text>
      </view>

      <view class="onb-step">
        <text class="onb-num">3</text>
        <text class="onb-text">对话字幕：实时把对方的话转为带「说话人姓名」的字幕；陌生人可现场起名</text>
      </view>

      <text class="onb-cta">👉 现在就选中「录入声纹」，短按进入开始第一步</text>
      <text class="onb-hint">操作：滑动选功能 ｜ 短按进入 ｜ 双击退出</text>
    </view>

    <view class="footer" ink:if="{{userCount > 0}}">
      <button class="btn-io" bindtap="exportDb" data-gesture-ignore="1">
        <text>导出声纹库</text>
      </button>
      <button class="btn-io" bindtap="importDb" data-gesture-ignore="1">
        <text>导入声纹库</text>
      </button>
      <button class="btn-clear" bindtap="clearAllUsers" data-gesture-ignore="1">
        <text>清空全部</text>
      </button>
    </view>

    <view class="footer" ink:if="{{userCount === 0}}">
      <button class="btn-io" bindtap="importDb" data-gesture-ignore="1">
        <text>从剪贴板导入声纹库</text>
      </button>
    </view>

    <view class="key-hints">
      <text class="hint-text">滑动：选择功能 ｜ 短按：进入 ｜ 双击：退出 ｜ 返回：后退</text>
    </view>

    <view class="sim-tap" bindtap="handleTap" bindlongpress="handleDoubleTap" data-gesture-ignore="1">
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

.btn-rename {
  padding: 6px 12px;
  background-color: transparent;
  border: var(--border-width-thin, 1px) solid var(--border-color-muted, rgba(64, 255, 94, 0.4));
  border-radius: var(--radius-sm, 6px);
}

.btn-rename text {
  font-size: 11px;
  color: var(--color-primary, #40FF5E);
}

.btn-io {
  padding: 8px 14px;
  margin: 0 6px;
  background-color: transparent;
  border: var(--border-width-thin, 1px) solid var(--border-color-muted, rgba(64, 255, 94, 0.4));
  border-radius: var(--radius-sm, 8px);
}

.btn-io text {
  font-size: 12px;
  color: var(--color-primary, #40FF5E);
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

.onboarding {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 10px 12px;
  background-color: var(--color-surface, rgba(64, 255, 94, 0.05));
  border: 2px solid var(--color-primary-40, rgba(64, 255, 94, 0.4));
  border-radius: var(--radius-md, 12px);
}

.onb-title {
  font-size: 13px;
  font-weight: bold;
  color: var(--color-primary, #40FF5E);
  margin-bottom: 2px;
}

.onb-step {
  display: flex;
  flex-direction: row;
  align-items: flex-start;
  gap: 8px;
}

.onb-num {
  width: 18px;
  height: 18px;
  min-width: 18px;
  font-size: 12px;
  font-weight: bold;
  color: #000000;
  background-color: var(--color-primary, #40FF5E);
  border-radius: 50%;
  text-align: center;
  line-height: 18px;
}

.onb-text {
  flex: 1;
  font-size: 12px;
  color: var(--color-text-primary, #FFFFFF);
  line-height: 1.5;
}

.onb-hint {
  font-size: 11px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.6));
  text-align: center;
  margin-top: 4px;
}

.onb-cta {
  font-size: 12px;
  font-weight: bold;
  color: #000000;
  background-color: var(--color-primary, #40FF5E);
  border-radius: 8px;
  padding: 6px 10px;
  text-align: center;
  margin-top: 4px;
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
