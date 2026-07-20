<script def>
{
  "navigationBarTitleText": "拍摄解说 - 无障碍版",
  "description": "眼镜拍摄照片/视频并用多模态大模型（Agnes AI）解说画面内容，再语音播报 + 大字幕呈现。为听障/需要用眼睛替代的人群优化：一次采集 3~5 项，单图≤5MB、单视频≤50MB。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "wizardStep": {
          "type": "string",
          "enum": ["intro", "capturing", "describing", "result"],
          "description": "向导当前步骤"
        },
        "pageMode": {
          "type": "string",
          "enum": ["general", "shape"],
          "description": "页面语境模式：general=通用拍摄解说，shape=图形识别（语音直呼 mode=shape 进入）"
        },
        "pageTitleText": { "type": "string", "description": "顶部标题文案，随 pageMode 切换" },
        "caption": { "type": "string", "description": "主字幕文案" },
        "hint": { "type": "string", "description": "副提示文案" },
        "shootBtnText": { "type": "string", "description": "拍照按钮主文案，随 pageMode 切换" },
        "describeBtnText": { "type": "string", "description": "开始解说/识别按钮主文案，随 pageMode 切换" },
        "captureMode": { "type": "string", "enum": ["photo", "video"], "description": "当前采集模式：拍照/录像" },
        "captureModeText": { "type": "string", "description": "采集模式按钮文案" },
        "isRecording": { "type": "boolean", "description": "是否正在录像" },
        "recordBtnText": { "type": "string", "description": "录像按钮文案" },
        "count": { "type": "number", "description": "已采集媒体项数量" },
        "countText": { "type": "string", "description": "数量进度文案，如「已采集 3 / 5（至少 3）」" },
        "canDescribe": { "type": "boolean", "description": "是否已满足开始解说的数量（≥3）" },
        "isFull": { "type": "boolean", "description": "是否已达采集上限（5）" },
        "cameraReady": { "type": "boolean", "description": "相机是否可用（否则演示采集）" },
        "visionModeText": { "type": "string", "description": "视觉解说模式徽章文案" },
        "visionBadgeClass": { "type": "string", "description": "视觉徽章样式类：live / demo" },
        "showVisionSetting": { "type": "boolean", "description": "是否展开视觉设置面板" },
        "apiKeyMasked": { "type": "string", "description": "已保存 apiKey 的脱敏显示" },
        "items": {
          "type": "array",
          "description": "已采集媒体项列表",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "number" },
              "kindText": { "type": "string", "description": "图片 / 视频" },
              "previewSrc": { "type": "string", "description": "缩略图路径或 dataURL" },
              "sizeText": { "type": "string", "description": "体积文案" },
              "descText": { "type": "string", "description": "解说文字（未解说时为占位）" },
              "descClass": { "type": "string", "description": "解说样式类：pending / live / demo" },
              "descLines": {
                "type": "array",
                "items": { "type": "string" },
                "description": "结构化解说分行（图形识别模式下按【】分段拆行，便于分节渲染字幕）"
              }
            }
          }
        }
      },
      "required": ["wizardStep", "caption", "captureMode", "count", "items"]
    }
  }
}
</script>

<script setup>
import wx from 'wx';
import { routeKeyEvent, installKeyboardFallback, removeKeyboardFallback, safeBack } from '../../utils/gesture.js';
import { speak } from '../../utils/tts.js';
import {
  acquireCameraContext, isCameraAvailable, takePhoto,
  startRecord, stopRecord, pathToBase64, getFileBytes
} from '../../utils/camera.js';
import {
  describeImage, describeShape, describeVideoFrames, isVisionConfigured, setVisionConfig, getVisionConfig
} from '../../utils/vision.js';
import {
  MIN_ITEMS, MAX_ITEMS, formatBytes, checkImageSize, checkVideoSize, canDescribe, isFull
} from '../../utils/media-limits.js';
import { initAsr, startAsr, stopAsr, isAsrAvailable } from '../../utils/asr.js';

export default {
  data: {
    wizardStep: 'intro',
    // pageMode：语音直呼「拍照识别图形」经 mode=shape 进入时切换为 shape，
    // 叠加在通用拍摄解说流程之上，不改变原有拍照/录像/采集数量逻辑（见 onLoad）
    pageMode: 'general',
    pageTitleText: '拍摄解说',
    caption: '拍下眼前的画面，我来讲给你听',
    hint: '点一下开始拍摄，最少 3 张、最多 5 项（照片或视频）',
    shootBtnText: '拍照',
    describeBtnText: '开始解说',
    captureMode: 'photo',
    captureModeText: '切换到录像',
    isRecording: false,
    recordBtnText: '开始录像',
    // 预计算录像按钮样式类，避免模板三元式触发 ink 静态检查告警
    recordBtnClass: '',
    count: 0,
    countText: '已采集 0 / ' + MAX_ITEMS + '（至少 ' + MIN_ITEMS + '）',
    canDescribe: false,
    isFull: false,
    cameraReady: false,
    visionModeText: '演示模式',
    visionBadgeClass: 'demo',
    showVisionSetting: false,
    apiKeyMasked: '未设置',
    items: [],
    // 运行期（不进 schema 渲染）
    cameraCtx: null,
    _describing: false
  },

  onLoad(query) {
    console.log('拍摄解说页面加载');
    this.data.items = [];
    this._nextId = 1;
    this._apiKeyDraft = '';
    this._pendingAutoStart = false;

    // 语音直呼模式解析：优先当前页面 query（mode=shape&autoStart=1，见 app.js _dispatch）；
    // 部分固件 redirectTo 传参可能丢失，兜底读 getApp().globalData.launchIntent
    // （app.js 冷/热启动分发时写入，见 docs/架构-语音直呼集成.md §2.3）
    const q = query || {};
    let mode = q.mode || '';
    let autoStart = q.autoStart || '';
    if (!mode) {
      const app = getApp();
      const intent = app && app.globalData && app.globalData.launchIntent;
      if (intent && intent.route && intent.route.mode === 'shape') {
        mode = 'shape';
        // app.js 分发拼接 URL 时固定带 autoStart=1，兜底沿用同一约定
        autoStart = '1';
      }
    }
    const isShape = mode === 'shape';
    this.data.pageMode = isShape ? 'shape' : 'general';

    if (isShape) {
      this.setData({
        pageMode: 'shape',
        pageTitleText: '图形识别',
        caption: '对准要识别的图形，我来告诉你它的详细信息',
        hint: '点一下开始拍摄，我会识别图形的类别、构成、比例与用途',
        shootBtnText: '拍摄图形',
        describeBtnText: '开始识别'
      });
    }

    this.refreshVisionBadge();
    this.refreshApiKeyMasked();
    // 相机上下文建议 onReady 后创建；此处先尝试一次，onReady 再兜底
    this.data.cameraCtx = acquireCameraContext();
    this.setData({ cameraReady: isCameraAvailable() });

    if (isShape && autoStart === '1') {
      // 语音直呼「拍照识别图形」：onReady 相机就绪后自动触发一次拍照流程
      this._pendingAutoStart = true;
    }
  },

  onReady() {
    if (!this.data.cameraCtx) {
      this.data.cameraCtx = acquireCameraContext();
      this.setData({ cameraReady: isCameraAvailable() });
    }
    if (this._pendingAutoStart) {
      this._pendingAutoStart = false;
      const that = this;
      // 复用现有向导流转 + 拍照按钮同款 handler，不新写拍照逻辑：
      // 先 startCapture() 切到 capturing 步骤（<camera> 组件才会挂载），
      // 留一拍再调 onTakePhoto()（无相机时它会自动降级为演示采集，同现有逻辑）
      this.startCapture();
      setTimeout(function () { that.onTakePhoto(); }, 500);
    }
    // 图形识别模式：相机就绪后一并开启语音常听（ASR 用麦、拍照用摄像头，
    // 二者可并存，见 setupShapeVoice 注释）
    this.setupShapeVoice();
  },

  onShow() {
    installKeyboardFallback(this);
    // 从子流程/系统返回本页时（onReady 只在首次渲染触发一次），
    // 若语音常听已被 onHide 关掉，这里补一次，setupShapeVoice 内部按 _voiceActive 去重。
    this.setupShapeVoice();
  },
  onHide() {
    removeKeyboardFallback(this);
    this.teardownShapeVoice();
  },
  onUnload() {
    // 录像中则收尾，避免占用相机
    if (this.data.isRecording && this.data.cameraCtx) {
      try { stopRecord(this.data.cameraCtx, {}); } catch (e) {}
    }
    // 离场释放语音识别器：ASR 与拍照虽可并存，但离开本页后必须停掉，
    // 否则会和下一个打开 ASR 的页面抢占同一个识别器单例
    this.teardownShapeVoice();
    removeKeyboardFallback(this);
  },

  vibrate() {
    const app = getApp();
    if (app && app.globalData && app.globalData.vibrationEnabled) {
      try { wx.vibrateShort(); } catch (e) {}
    }
  },

  refreshVisionBadge() {
    const live = isVisionConfigured();
    this.setData({
      visionModeText: live ? 'Agnes 在线' : '演示模式',
      visionBadgeClass: live ? 'live' : 'demo'
    });
  },

  refreshApiKeyMasked() {
    const cfg = getVisionConfig();
    const k = cfg.apiKey || '';
    this.setData({
      apiKeyMasked: k ? (k.slice(0, 4) + '****' + k.slice(-4)) : '未设置'
    });
  },

  // ====== 向导流转 ======

  startCapture() {
    const isShape = this.data.pageMode === 'shape';
    const target = isShape ? '图形' : '画面';
    this.setData({
      wizardStep: 'capturing',
      caption: this.data.captureMode === 'photo' ? ('对准' + target + '，拍一张') : ('对准' + target + '，开始录像'),
      hint: this.data.cameraReady
        ? ('短按=拍摄' + target + ' ｜ 滑动=切换拍照/录像 ｜ 采够 3 项后双击=开始' + (isShape ? '识别' : '解说'))
        : '当前无相机（演示采集）：短按=添加一项演示媒体'
    });
    speak(this.data.cameraReady ? ('开始拍摄' + target) : '当前没有相机，进入演示采集');
  },

  // 采集上限拦截
  guardFull() {
    if (isFull(this.data.count)) {
      this.setData({ hint: '已采集满 ' + MAX_ITEMS + ' 项，双击开始解说' });
      speak('已经采集满了，双击开始解说');
      return true;
    }
    return false;
  },

  // ====== 拍照 ======
  onTakePhoto() {
    if (this.data.wizardStep !== 'capturing') return;
    if (this.guardFull()) return;
    if (!this.data.cameraReady || !this.data.cameraCtx) {
      this.addDemoItem('image');
      return;
    }
    const that = this;
    this.setData({ hint: '正在拍照…' });
    takePhoto(this.data.cameraCtx, { quality: 'high' })
      .then(function (res) { return that.ingestImage(res.tempImagePath); })
      .catch(function (e) {
        console.log('拍照失败: ' + e);
        that.setData({ hint: '拍照失败，请重试' });
        speak('拍照失败，请重试');
      });
  },

  // 处理一张图片：取大小→校验≤5MB→读 base64→入列
  ingestImage(path) {
    const that = this;
    return getFileBytes(path).then(function (bytes) {
      const chk = checkImageSize(bytes || 0);
      if (!chk.ok) {
        that.setData({ hint: chk.reason + '，未加入' });
        speak('这张图片太大，超过 5 兆，没有加入');
        return;
      }
      return pathToBase64(path).then(function (b64) {
        const sizeText = bytes ? formatBytes(bytes) : '大小未知';
        that.pushItem({
          kind: 'image',
          kindText: '图片',
          previewSrc: path,
          base64: b64 || null,
          frames: b64 ? [b64] : [],
          sizeText: sizeText + (chk.unknown ? '（近似放行）' : '')
        });
      });
    });
  },

  // ====== 录像 ======
  onToggleRecord() {
    if (this.data.wizardStep !== 'capturing') return;
    if (!this.data.isRecording && this.guardFull()) return;
    if (!this.data.cameraReady || !this.data.cameraCtx) {
      // 无相机：演示添加一段视频项
      if (!this.data.isRecording) this.addDemoItem('video');
      return;
    }
    if (this.data.isRecording) this.stopVideo();
    else this.startVideo();
  },

  startVideo() {
    const that = this;
    startRecord(this.data.cameraCtx, function () {
      // 达到平台录制上限，自动停止
      if (that.data.isRecording) that.stopVideo();
    })
      .then(function () {
        that.setData({ isRecording: true, recordBtnText: '停止录像', recordBtnClass: 'recording', caption: '录像中…', hint: '再按一次停止' });
        that.vibrate();
        speak('开始录像');
      })
      .catch(function (e) {
        console.log('开始录像失败: ' + e);
        that.setData({ hint: '开始录像失败，请重试' });
        speak('开始录像失败');
      });
  },

  stopVideo() {
    const that = this;
    this.setData({ isRecording: false, recordBtnText: '开始录像', recordBtnClass: '', hint: '正在保存视频…' });
    stopRecord(this.data.cameraCtx, { compressed: true })
      .then(function (res) { return that.ingestVideo(res.tempVideoPath, res.tempThumbPath); })
      .catch(function (e) {
        console.log('停止录像失败: ' + e);
        that.setData({ hint: '保存视频失败，请重试' });
        speak('保存视频失败');
      });
  },

  // 处理一段视频：取大小→校验≤50MB→读封面帧 base64（作为解说关键帧）→入列
  ingestVideo(videoPath, thumbPath) {
    const that = this;
    return getFileBytes(videoPath).then(function (bytes) {
      const chk = checkVideoSize(bytes || 0);
      if (!chk.ok) {
        that.setData({ hint: chk.reason + '，未加入' });
        speak('这段视频太大，超过 50 兆，没有加入');
        return;
      }
      return pathToBase64(thumbPath || videoPath).then(function (b64) {
        const sizeText = bytes ? formatBytes(bytes) : '大小未知';
        that.pushItem({
          kind: 'video',
          kindText: '视频',
          previewSrc: thumbPath || '',
          base64: b64 || null,
          frames: b64 ? [b64] : [], // 封面帧作为视频关键帧喂给多模态模型
          sizeText: sizeText + (chk.unknown ? '（近似放行）' : '') + ' · 基于封面帧解说'
        });
      });
    });
  },

  // ====== 无相机时的演示采集 ======
  addDemoItem(kind) {
    if (this.guardFull()) return;
    this.pushItem({
      kind: kind,
      kindText: kind === 'video' ? '视频（演示）' : '图片（演示）',
      previewSrc: '',
      base64: null,
      frames: [],
      sizeText: '演示项 · 无真实文件'
    });
    speak(kind === 'video' ? '已添加一段演示视频' : '已添加一张演示图片');
  },

  // 入列 + 刷新计数
  pushItem(raw) {
    const item = {
      id: this._nextId++,
      kind: raw.kind,
      kindText: raw.kindText,
      previewSrc: raw.previewSrc || '',
      base64: raw.base64,
      frames: raw.frames || [],
      sizeText: raw.sizeText || '',
      descText: '待解说',
      descClass: 'pending',
      descLines: []
    };
    const items = this.data.items.concat([item]);
    const count = items.length;
    this.setData({
      items: items,
      count: count,
      countText: '已采集 ' + count + ' / ' + MAX_ITEMS + '（至少 ' + MIN_ITEMS + '）',
      canDescribe: canDescribe(count),
      isFull: isFull(count),
      caption: '已采集 ' + count + ' 项',
      hint: canDescribe(count)
        ? '够了！双击或点「开始解说」；也可继续采集到 ' + MAX_ITEMS + ' 项'
        : '再采集 ' + (MIN_ITEMS - count) + ' 项就能解说'
    });
    this.vibrate();
    speak('已采集第 ' + count + ' 项');
  },

  // 删除最后一项（重来一步）
  removeLast() {
    if (this.data.items.length === 0) return;
    const items = this.data.items.slice(0, -1);
    const count = items.length;
    this.setData({
      items: items,
      count: count,
      countText: '已采集 ' + count + ' / ' + MAX_ITEMS + '（至少 ' + MIN_ITEMS + '）',
      canDescribe: canDescribe(count),
      isFull: isFull(count)
    });
    speak('已删除最后一项');
  },

  // ====== 解说（逐项调用多模态模型 + 语音播报）======
  startDescribe() {
    if (this.data._describing) return;
    const isShape = this.data.pageMode === 'shape';
    const verb = isShape ? '识别' : '解说';
    if (!canDescribe(this.data.count)) {
      this.setData({ hint: '至少采集 ' + MIN_ITEMS + ' 项才能' + verb });
      speak('至少采集三项才能' + verb);
      return;
    }
    this.data._describing = true;
    this.refreshVisionBadge();
    const live = isVisionConfigured();
    this.setData({
      wizardStep: 'describing',
      caption: isShape ? '正在识别图形结构' : '正在解说画面内容',
      hint: live
        ? ('Agnes 视觉模型' + verb + '中，请稍候')
        : ('演示模式（未配置视觉模型），展示' + (isShape ? '图形识别演示文案' : '演示解说'))
    });
    speak(live ? ('开始' + verb + '，正在识别画面') : ('开始演示' + verb));
    this.describeAt(0);
  },

  // 串行解说第 idx 项：调模型 → 更新该项文案 → 语音播报 → 下一项
  describeAt(idx) {
    const that = this;
    const items = this.data.items;
    if (idx >= items.length) {
      this.finishDescribe();
      return;
    }
    const item = items[idx];
    this.markItem(idx, '识别中…', 'pending');

    const isShape = this.data.pageMode === 'shape';
    const p = item.kind === 'video'
      ? describeVideoFrames(item.frames)
      : (isShape ? describeShape(item.base64) : describeImage(item.base64));

    p.then(function (res) {
      const cls = res.mode === 'live' ? 'live' : 'demo';
      const prefix = item.kindText + '：';
      that.markItem(idx, res.text, cls);
      // 逐条语音播报解说内容
      speak(prefix + res.text);
      // 播报留出时间，再解说下一项
      setTimeout(function () { that.describeAt(idx + 1); }, res.text.length > 20 ? 3200 : 2200);
    });
  },

  // 更新第 idx 项的解说文案与样式；图形识别模式下若文本含【】结构标记，
  // 按换行拆成 descLines 供模板分节渲染（更易读，非结构化文本时回退整段展示）
  markItem(idx, text, cls) {
    const isShape = this.data.pageMode === 'shape';
    const lines = (isShape && text && text.indexOf('【') >= 0)
      ? text.split('\n').map(function (l) { return l.trim(); }).filter(function (l) { return l.length > 0; })
      : [];
    const items = this.data.items.map(function (it, i) {
      if (i !== idx) return it;
      return Object.assign({}, it, { descText: text, descClass: cls, descLines: lines });
    });
    this.setData({ items: items });
  },

  finishDescribe() {
    this.data._describing = false;
    const live = isVisionConfigured();
    const isShape = this.data.pageMode === 'shape';
    this.setData({
      wizardStep: 'result',
      caption: isShape ? '图形识别完成' : '解说完成',
      hint: live
        ? ('以上为 Agnes ' + (isShape ? '图形识别' : '识别') + '结果 ｜ 双击退出 ｜ 短按返回主页')
        : ('以上为' + (isShape ? '图形识别演示' : '演示解说') + ' ｜ 填入 API Key 可获得真实识别 ｜ 双击退出')
    });
    this.vibrate();
    speak(isShape ? '图形识别完成' : '解说完成');
  },

  // 全部重来
  resetAll() {
    const isShape = this.data.pageMode === 'shape';
    this.data.items = [];
    this._nextId = 1;
    this.data._describing = false;
    this.setData({
      wizardStep: 'capturing',
      items: [],
      count: 0,
      countText: '已采集 0 / ' + MAX_ITEMS + '（至少 ' + MIN_ITEMS + '）',
      canDescribe: false,
      isFull: false,
      isRecording: false,
      recordBtnText: '开始录像',
      recordBtnClass: '',
      caption: isShape ? '重新开始识别' : '重新开始采集',
      hint: isShape ? '短按拍摄图形，滑动切换拍照/录像' : '短按拍照，滑动切换拍照/录像'
    });
    speak('已清空，重新采集');
  },

  // ====== 采集模式切换 ======
  toggleCaptureMode() {
    if (this.data.isRecording) return; // 录像中不切换
    const next = this.data.captureMode === 'photo' ? 'video' : 'photo';
    this.setData({
      captureMode: next,
      captureModeText: next === 'photo' ? '切换到录像' : '切换到拍照',
      caption: next === 'photo' ? '对准画面，拍一张' : '对准画面，开始录像'
    });
    speak(next === 'photo' ? '拍照模式' : '录像模式');
  },

  // ====== 视觉设置（填 API Key）======
  toggleVisionSetting() {
    this.setData({ showVisionSetting: !this.data.showVisionSetting });
  },

  onApiKeyInput(e) {
    this._apiKeyDraft = (e && e.detail && e.detail.value) || '';
  },

  saveApiKey() {
    const key = (this._apiKeyDraft || '').trim();
    if (!key) {
      this.setData({ hint: 'API Key 不能为空' });
      speak('密钥不能为空');
      return;
    }
    setVisionConfig({ apiKey: key });
    this.refreshVisionBadge();
    this.refreshApiKeyMasked();
    this.setData({ showVisionSetting: false, hint: '已保存密钥，现在可获得真实解说' });
    speak('已保存密钥，现在可以真实识别');
    try { wx.showToast({ title: '密钥已保存', icon: 'success', duration: 1500 }); } catch (e) {}
  },

  clearApiKey() {
    setVisionConfig({ apiKey: '' });
    this.refreshVisionBadge();
    this.refreshApiKeyMasked();
    this.setData({ hint: '已清除密钥，回到演示模式' });
    speak('已清除密钥');
  },

  // 相机组件报错（无权限/被占用）：降级为演示采集，不卡死
  onCameraError(e) {
    console.log('[camera] 组件报错: ' + JSON.stringify(e && e.detail));
    this.setData({ cameraReady: false, hint: '相机不可用，已切换为演示采集' });
    speak('相机不可用，切换为演示采集');
  },

  // ====== 语音控制（仅 shape=图形识别模式常听，见 AGENTS.md 技能2）======
  // ASR 用麦克风、拍照用摄像头，二者可在真机上并存；但离场（onHide/onUnload）
  // 必须释放识别器，避免占着麦克风、也避免和下一页面的 ASR 抢单例。
  // general 模式（拍摄解说通用流程）不强制常听，autoStart 系统语音路径不受影响。
  setupShapeVoice() {
    if (this.data.pageMode !== 'shape') return;
    if (this._voiceActive) return; // 已在监听中，避免 onReady/onShow 重复触发 double start
    if (!isAsrAvailable()) return; // 无 ASR 能力：诚实保持原有 autoStart/手势路径，不额外报错
    const that = this;
    this._voiceActive = true;
    initAsr({
      onFinal: function (text) { that.onShapeVoiceCommand(text); }
    });
    startAsr({ lang: 'zh_CN' });
  },

  // 真机识别器 onStop 后需重新 start 才能继续听下一句，隔一拍再 start 避免同步重入
  scheduleShapeRestart() {
    const that = this;
    if (this._shapeVoiceRestartTimer) return;
    this._shapeVoiceRestartTimer = setTimeout(function () {
      that._shapeVoiceRestartTimer = null;
      if (!that._voiceActive || !isAsrAvailable()) return;
      startAsr({ lang: 'zh_CN' });
    }, 400);
  },

  teardownShapeVoice() {
    this._voiceActive = false;
    if (this._shapeVoiceRestartTimer) {
      try { clearTimeout(this._shapeVoiceRestartTimer); } catch (e) {}
      this._shapeVoiceRestartTimer = null;
    }
    stopAsr();
  },

  // 语音指令分类：拍照/识别/返回三类，全部复用现有 handler，不新写拍摄或解说逻辑
  onShapeVoiceCommand(text) {
    const raw = (text || '').trim();
    if (!raw) { this.scheduleShapeRestart(); return; }

    if (/拍/.test(raw)) {
      // 复用 handleTap 同款的步骤流转：intro 时先进入拍摄，capturing 时才真正拍照
      if (this.data.wizardStep === 'intro') this.startCapture();
      if (this.data.wizardStep === 'capturing') this.onTakePhoto();
      this.scheduleShapeRestart();
      return;
    }
    if (/识别|分析|解说|讲讲/.test(raw)) {
      if (this.data.count >= 1) {
        // startDescribe() 内部已对「不足 MIN_ITEMS」做校验 + 语音提示，这里只做基本门槛
        this.startDescribe();
      } else {
        this.setData({ hint: '还没有采集任何画面，请先拍照' });
        speak('还没有采集任何画面，请先拍照');
      }
      this.scheduleShapeRestart();
      return;
    }
    if (/返回|退出/.test(raw)) {
      this.teardownShapeVoice();
      safeBack();
      return;
    }

    // 未命中：继续听下一句，不报错卡死
    this.scheduleShapeRestart();
  },

  // ====== 导航与手势 ======
  goBackHome() { safeBack(); },

  onKeyDown(event) {
    this._lastFrameworkKey = Date.now();
    routeKeyEvent(this, event, 'down');
  },
  onKeyUp(event) {
    if (!event) return;
    routeKeyEvent(this, event, 'up');
  },

  // 短按：intro=开始；capturing=拍照(拍照模式)/停止录像(录像中)；result=返回主页
  handleTap() {
    const step = this.data.wizardStep;
    if (step === 'intro') { this.startCapture(); return; }
    if (step === 'capturing') {
      if (this.data.captureMode === 'video') this.onToggleRecord();
      else this.onTakePhoto();
      return;
    }
    if (step === 'result') { this.goBackHome(); return; }
  },

  // 双击：capturing 且够数=开始解说；否则退出
  handleDoubleTap() {
    if (this.data.wizardStep === 'capturing' && this.data.canDescribe) {
      this.startDescribe();
      return;
    }
    if (this.data.isRecording && this.data.cameraCtx) {
      try { stopRecord(this.data.cameraCtx, {}); } catch (e) {}
    }
    safeBack();
  },

  // 滑动：capturing 时切换拍照/录像；其余忽略
  handleSwipe(direction) {
    if (this.data.wizardStep === 'capturing') {
      this.toggleCaptureMode();
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
      <text class="title">{{pageTitleText}}</text>
      <view class="mode-badge {{visionBadgeClass}}" bindtap="toggleVisionSetting">
        <text>{{visionModeText}}</text>
      </view>
    </view>

    <!-- 视觉设置面板：填入 Agnes API Key -->
    <view class="vision-setting" wx:if="{{showVisionSetting}}">
      <text class="vs-title">视觉模型设置（Agnes AI）</text>
      <text class="vs-line">当前密钥：{{apiKeyMasked}}</text>
      <input class="vs-input" type="text" password="{{true}}" placeholder="粘贴 Agnes API Key（sk-...）" bindinput="onApiKeyInput" />
      <view class="vs-btns">
        <button class="vs-save" bindtap="saveApiKey"><text>保存密钥</text></button>
        <button class="vs-clear" bindtap="clearApiKey"><text>清除</text></button>
      </view>
      <text class="vs-note">未填写时为演示模式；填入后拍摄内容将由 Agnes 视觉模型真实识别解说。</text>
    </view>

    <!-- 主字幕 -->
    <view class="caption-card">
      <text class="caption">{{caption}}</text>
      <text class="hint" wx:if="{{hint}}">{{hint}}</text>
      <text class="count-text">{{countText}}</text>
    </view>

    <!-- 相机取景（拍摄阶段）-->
    <view class="camera-box" wx:if="{{wizardStep === 'capturing' && cameraReady}}">
      <camera class="camera" device-position="back" flash="off" binderror="onCameraError"></camera>
      <view class="rec-dot" wx:if="{{isRecording}}"></view>
    </view>
    <view class="camera-fallback" wx:if="{{wizardStep === 'capturing' && !cameraReady}}">
      <text class="fallback-text">当前环境无相机，进入演示采集</text>
    </view>

    <!-- 采集操作区 -->
    <view class="capture-ops" wx:if="{{wizardStep === 'capturing'}}">
      <button class="op-btn shoot" bindtap="onTakePhoto" wx:if="{{captureMode === 'photo'}}">
        <text class="op-main">{{shootBtnText}}</text>
        <text class="op-sub">采集一张图片（≤5MB）</text>
      </button>
      <button class="op-btn record {{recordBtnClass}}" bindtap="onToggleRecord" wx:if="{{captureMode === 'video'}}">
        <text class="op-main">{{recordBtnText}}</text>
        <text class="op-sub">采集一段视频（≤50MB）</text>
      </button>
      <button class="op-btn switch" bindtap="toggleCaptureMode">
        <text class="op-main">{{captureModeText}}</text>
      </button>
      <button class="op-btn describe" bindtap="startDescribe" disabled="{{!canDescribe}}">
        <text class="op-main">{{describeBtnText}}</text>
        <text class="op-sub">对已采集的 {{count}} 项逐一识别播报</text>
      </button>
      <button class="op-btn undo" bindtap="removeLast" disabled="{{count === 0}}">
        <text class="op-main">删除上一项</text>
      </button>
    </view>

    <!-- 结果区操作 -->
    <view class="result-ops" wx:if="{{wizardStep === 'result'}}">
      <button class="op-btn again" bindtap="resetAll"><text class="op-main">再拍一组</text></button>
      <button class="op-btn home" bindtap="goBackHome"><text class="op-main">返回主页</text></button>
    </view>

    <!-- 采集/解说列表 -->
    <scroll-view class="item-list" scroll-y="true" wx:if="{{items.length > 0}}">
      <view class="item-row" wx:for="{{items}}" wx:key="id">
        <view class="item-head">
          <text class="item-kind">{{item.kindText}}</text>
          <text class="item-size">{{item.sizeText}}</text>
        </view>
        <image class="item-thumb" src="{{item.previewSrc}}" mode="aspectFill" wx:if="{{item.previewSrc}}"></image>
        <!-- 图形识别模式下若解说文本含【】结构标记，按行分节渲染，可读性优于整段 -->
        <view class="item-desc-block" wx:if="{{item.descLines.length > 0}}">
          <text class="item-desc-line {{item.descClass}}" wx:for="{{item.descLines}}" wx:for-item="ln" wx:key="index">{{ln}}</text>
        </view>
        <text class="item-desc {{item.descClass}}" wx:if="{{item.descLines.length === 0}}">{{item.descText}}</text>
      </view>
    </scroll-view>

    <view class="empty-tip" wx:if="{{wizardStep === 'intro'}}">
      <text class="empty-text">拍照或录像后，我会用大模型识别画面并读给你听</text>
    </view>

    <text class="gesture-hint">短按：拍照/开始 ｜ 滑动：拍照↔录像 ｜ 双击：够 3 项则解说，否则退出</text>

    <view class="sim-tap" bindtap="handleTap" bindlongpress="handleDoubleTap">
      <text class="sim-tap-text">仿真操作：点此=短按（开始 / 拍照 / 返回）｜ 长按此区域=解说或退出</text>
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

.mode-badge {
  font-size: 12px;
  font-weight: bold;
  padding: 4px 10px;
  border-radius: 12px;
  border: 1px solid;
}
.mode-badge.live { color: #000000; background-color: #40FF5E; border-color: #40FF5E; }
.mode-badge.demo { color: #FFB000; background-color: rgba(255, 176, 0, 0.1); border-color: #FFB000; }

.vision-setting {
  background-color: #0d1a0d;
  border: 2px solid #40FF5E;
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 10px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.vs-title { font-size: 16px; font-weight: bold; color: #7DFF90; }
.vs-line { font-size: 13px; color: #CFFFD8; }
.vs-input {
  background-color: #001400;
  border: 1px solid #40FF5E;
  border-radius: 8px;
  padding: 10px;
  color: #FFFFFF;
  font-size: 15px;
}
.vs-btns { display: flex; flex-direction: row; gap: 8px; }
.vs-save { flex: 1; background-color: #40FF5E; border: none; border-radius: 8px; padding: 10px; }
.vs-save text { color: #000000; font-weight: bold; font-size: 15px; }
.vs-clear { flex: 0 0 auto; background-color: transparent; border: 1px solid #FF4040; border-radius: 8px; padding: 10px 16px; }
.vs-clear text { color: #FF4040; font-size: 14px; }
.vs-note { font-size: 12px; color: #FFC93C; line-height: 1.4; }

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
.caption {
  font-size: 22px;
  font-weight: bold;
  color: #7DFF90;
  text-align: center;
  line-height: 1.35;
  text-shadow: 0 0 8px rgba(64, 255, 94, 0.7);
}
.hint { font-size: 15px; color: #CFFFD8; text-align: center; line-height: 1.4; }
.count-text { font-size: 14px; color: rgba(64, 255, 94, 0.8); margin-top: 2px; }

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
.rec-dot {
  position: absolute;
  top: 10px;
  right: 10px;
  width: 16px;
  height: 16px;
  border-radius: 50%;
  background-color: #FF4040;
  animation: blink 1s infinite;
}
@keyframes blink { 0%,100% { opacity: 1; } 50% { opacity: 0.2; } }

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

.capture-ops, .result-ops {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 10px;
}

.op-btn {
  padding: 12px;
  border-radius: 12px;
  border: 3px solid #40FF5E;
  background-color: transparent;
  display: flex;
  flex-direction: column;
  align-items: center;
}
.op-btn[disabled] { opacity: 0.4; }
.op-main { font-size: 19px; font-weight: bold; color: #7DFF90; }
.op-sub { font-size: 12px; color: rgba(207, 255, 216, 0.8); margin-top: 2px; }

.op-btn.shoot { background-color: #40FF5E; border-color: #40FF5E; }
.op-btn.shoot .op-main, .op-btn.shoot .op-sub { color: #000000; }
.op-btn.record { border-color: #FF4040; }
.op-btn.record .op-main { color: #FF6060; }
.op-btn.record.recording { background-color: #2a1a1a; animation: blink 1s infinite; }
.op-btn.describe { background-color: #40FF5E; border-color: #40FF5E; }
.op-btn.describe .op-main, .op-btn.describe .op-sub { color: #000000; }
.op-btn.describe[disabled] { background-color: transparent; }
.op-btn.describe[disabled] .op-main, .op-btn.describe[disabled] .op-sub { color: #7DFF90; }
.op-btn.switch, .op-btn.undo, .op-btn.again, .op-btn.home { border-color: rgba(64, 255, 94, 0.5); }

.item-list {
  flex: 1;
  min-height: 60px;
  background-color: #0d0d0d;
  border: 2px solid #333333;
  border-radius: 12px;
  padding: 10px;
  margin-bottom: 10px;
  box-sizing: border-box;
}
.item-row {
  border-bottom: 1px solid #222222;
  padding-bottom: 10px;
  margin-bottom: 10px;
}
.item-head {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 6px;
}
.item-kind { font-size: 15px; font-weight: bold; color: #40FF5E; }
.item-size { font-size: 12px; color: rgba(255, 255, 255, 0.5); }
.item-thumb {
  width: 100%;
  height: 120px;
  border-radius: 8px;
  background-color: #111111;
  margin-bottom: 6px;
}
.item-desc { font-size: 20px; line-height: 1.5; color: #FFFFFF; }
.item-desc.pending { color: #888888; }
.item-desc.live { color: #FFFFFF; text-shadow: 0 0 4px rgba(64, 255, 94, 0.3); }
.item-desc.demo { color: #FFC93C; }

/* 图形识别结构化分行渲染（【类别】【形状构成】…按行分节，可读性优于整段） */
.item-desc-block { display: flex; flex-direction: column; gap: 4px; }
.item-desc-line { font-size: 18px; line-height: 1.5; color: #FFFFFF; }
.item-desc-line.pending { color: #888888; }
.item-desc-line.live { color: #FFFFFF; text-shadow: 0 0 4px rgba(64, 255, 94, 0.3); }
.item-desc-line.demo { color: #FFC93C; }

.empty-tip { padding: 20px; text-align: center; }
.empty-text { font-size: 15px; color: #999999; line-height: 1.5; }

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
