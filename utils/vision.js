/**
 * 多模态视觉解说适配层（Agnes AI，OpenAI 兼容 /chat/completions）
 *
 * 平台事实（见 AIUI 文档调研）：
 *   - AIUI 内置 AI 只有「纯文本大模型」session.prompt()，没有视觉/多模态接口；
 *   - 网络能力有 wx.request，但没有 wx.uploadFile。
 * 因此「解说图片/视频内容」走 wx.request POST 到外部多模态网关（默认 Agnes AI）。
 *
 * 设计（对齐项目既有 asr/tts 的「能力探测 + demo 降级」范式）：
 *   - 已配置 apiKey 且有 wx.request → 真机联网解说（mode:'live'）；
 *   - 未配置 / 无网络能力 / 请求失败 → 演示解说文本（mode:'demo'），并明确标注，绝不冒充真实识别。
 *
 * 安全：API Key 不硬编码进源码，存本地 storage（vision_config），由用户在「视觉设置」填入。
 *
 * Agnes AI 文档：https://agnes-ai.com/doc （OpenAI 兼容；已实测 agnes-2.0-flash 支持图片理解）
 *   Base URL：https://apihub.agnes-ai.com/v1
 */

import wx from 'wx';
import {
  buildImageRequest, buildVideoRequest, parseVisionText, demoDescription
} from './media-limits.js';
import { AGNES_API_KEY, AGNES_BASE_URL, AGNES_VISION_MODEL } from './cloud-ai.js';

const STORAGE_KEY = 'vision_config';

// 默认配置：统一读 cloud-ai.js 的内置 Agnes Key/网关/模型（测试版无需在眼镜端填 Key）。
// 用户仍可在设置面板临时覆盖（storage 优先级高于此默认），但测试版通常不需要。
const DEFAULT_CONFIG = {
  baseUrl: AGNES_BASE_URL,
  apiKey: AGNES_API_KEY,
  model: AGNES_VISION_MODEL
};

const REQUEST_TIMEOUT_MS = 20000;

// 图形识别结构化 prompt（用例B：拍照识别图形，见 docs/架构-语音直呼集成.md §4.1）。
// 服务对象仍是听障用户，但目标从「整体解说画面」换成「结构化拆解一个图形/物体」。
const SHAPE_PROMPT =
  '你是视觉结构分析助手，服务对象是听障用户，请分析这张照片中的主要图形/物体，' +
  '严格按以下结构输出（没有的项写"无"，不要输出多余寒暄）：\n' +
  '【类别】图形/物体是什么（如：三角形标志、机械零件、流程图、建筑立面）\n' +
  '【形状构成】由哪些基本形状组成（圆/方/三角/多边形/曲线），各自数量与嵌套关系\n' +
  '【尺寸比例】各部分相对大小与比例关系（如：主体占画面约2/3，左圆约为右方形的一半）\n' +
  '【颜色】主要颜色及分布位置\n' +
  '【文字】图上出现的所有文字，逐条列出\n' +
  '【空间关系】各元素的上下左右/包含/相交关系\n' +
  '【可能用途】这个图形/物体最可能是什么、用来做什么（给1-2个推断并说明依据）\n' +
  '语言简洁，总长不超过300字，适合语音播报。';

// 图形识别专用演示文案（未配置视觉模型 / 请求失败时使用，明确标注，绝不冒充真实识别结果）
const SHAPE_DEMO_TEXTS = [
  '演示解说：【类别】几何图形示意图（未配置视觉模型，此为演示文本）\n' +
  '【形状构成】一个圆形与两个三角形\n【尺寸比例】圆形直径约占画面一半，三角形分列两侧，各约为圆形的三分之一\n' +
  '【颜色】黑白线条为主\n【文字】无\n【空间关系】两个三角形分别位于圆形左右两侧，互不重叠\n' +
  '【可能用途】常见于教学示意图，用于讲解几何关系',
  '演示解说：【类别】流程图卡片（未配置视觉模型，此为演示文本）\n' +
  '【形状构成】三个矩形与连接箭头\n【尺寸比例】三个矩形大小接近，纵向排列\n' +
  '【颜色】以蓝白配色为主\n【文字】"开始""处理""结束"三个词\n【空间关系】矩形自上而下依次由箭头连接\n' +
  '【可能用途】用于展示一个简单流程的三个步骤'
];

let _demoIdx = 0;
let _shapeDemoIdx = 0;

function requestAvailable() {
  return typeof wx !== 'undefined' && wx && typeof wx.request === 'function';
}

/** 读取当前视觉配置（storage 覆盖默认值；但 storage 里 Key 为空时回退到内置 Key）。 */
export function getVisionConfig() {
  let saved = null;
  try { saved = wx.getStorageSync(STORAGE_KEY); } catch (e) {}
  const cfg = Object.assign({}, DEFAULT_CONFIG, saved || {});
  // 内置测试 Key 兜底：避免历史「清除密钥」在 storage 留下空串把内置 Key 覆盖成空。
  if (!cfg.apiKey) cfg.apiKey = AGNES_API_KEY;
  if (!cfg.baseUrl) cfg.baseUrl = AGNES_BASE_URL;
  return cfg;
}

/** 写入/合并视觉配置（如只更新 apiKey）。返回合并后的配置。 */
export function setVisionConfig(patch) {
  const next = Object.assign({}, getVisionConfig(), patch || {});
  try { wx.setStorageSync(STORAGE_KEY, next); } catch (e) {}
  return next;
}

/** 是否具备「真机联网解说」条件：有网络能力 + 已填 apiKey。 */
export function isVisionConfigured() {
  const cfg = getVisionConfig();
  return requestAvailable() && !!cfg.apiKey && !!cfg.baseUrl;
}

/** 当前解说模式：'live'（真实模型）/ 'demo'（演示）。 */
export function visionMode() {
  return isVisionConfigured() ? 'live' : 'demo';
}

// 统一的一次多模态请求：成功 resolve 文字，失败 reject。
function postVision(cfg, body) {
  return new Promise(function (resolve, reject) {
    let done = false;
    const finish = (fn, arg) => { if (!done) { done = true; fn(arg); } };

    // 兜底超时：部分运行时 wx.request 不一定触发 fail
    const timer = setTimeout(function () {
      finish(reject, new Error('请求超时'));
    }, REQUEST_TIMEOUT_MS + 2000);

    try {
      wx.request({
        url: cfg.baseUrl,
        method: 'POST',
        timeout: REQUEST_TIMEOUT_MS,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + cfg.apiKey
        },
        data: body,
        success: function (res) {
          clearTimeout(timer);
          const code = res && res.statusCode;
          if (code && code >= 400) {
            finish(reject, new Error('服务返回 ' + code));
            return;
          }
          // res.data 可能是对象或 JSON 字符串
          let data = res && res.data;
          if (typeof data === 'string') {
            try { data = JSON.parse(data); } catch (e) {}
          }
          const text = parseVisionText(data);
          if (text) finish(resolve, text);
          else finish(reject, new Error('未解析到解说内容'));
        },
        fail: function (err) {
          clearTimeout(timer);
          finish(reject, new Error((err && err.errMsg) || '网络请求失败'));
        }
      });
    } catch (e) {
      clearTimeout(timer);
      finish(reject, e);
    }
  });
}

// 内部薄封装：单图请求的「构造 body → postVision → 失败降级为演示文案」共用路径。
// describeImage / describeShape 都是它的薄封装，只是 prompt 与演示文案来源不同——
// 不复制请求/降级逻辑（要求见任务说明）。
// @param {string} dataUrl
// @param {string} [prompt] 传给 buildImageRequest 的自定义 prompt；不传则用其内置默认 IMAGE_PROMPT
// @param {Function} demoTextFn 生成演示文案的函数（未配置/失败时调用）
function requestImageDescription(dataUrl, prompt, demoTextFn) {
  const cfg = getVisionConfig();
  if (!isVisionConfigured() || !dataUrl) {
    return Promise.resolve({ ok: true, text: demoTextFn(), mode: 'demo' });
  }
  const body = buildImageRequest(cfg.model, dataUrl, prompt);
  return postVision(cfg, body)
    .then((text) => ({ ok: true, text: text, mode: 'live' }))
    .catch((e) => ({
      ok: false,
      text: demoTextFn(),
      mode: 'demo',
      error: (e && e.message) || String(e)
    }));
}

/**
 * 解说一张图片（通用画面解说）。
 * @param {string} dataUrl data:image/...;base64,xxx 或纯 base64
 * @returns {Promise<{ok:boolean, text:string, mode:'live'|'demo', error?:string}>}
 *          永不 reject：真机失败会自动降级为演示文本并带 error 说明。
 */
export function describeImage(dataUrl) {
  return requestImageDescription(dataUrl, undefined, () => demoDescription('image', _demoIdx++));
}

/**
 * 识别一张图形/物体照片，输出结构化【类别/形状构成/尺寸比例/颜色/文字/空间关系/可能用途】。
 * 用例B：拍照识别图形（见 docs/架构-语音直呼集成.md §4.1）。与 describeImage 共用同一条
 * postVision 请求 + demo 降级路径，仅 prompt 与演示文案不同。
 * @param {string} dataUrl data:image/...;base64,xxx 或纯 base64
 * @returns {Promise<{ok:boolean, text:string, mode:'live'|'demo', error?:string}>}
 */
export function describeShape(dataUrl) {
  return requestImageDescription(dataUrl, SHAPE_PROMPT, () => SHAPE_DEMO_TEXTS[_shapeDemoIdx++ % SHAPE_DEMO_TEXTS.length]);
}

/**
 * 解说一段视频（以若干关键帧近似）。
 * @param {string[]} frameDataUrls 关键帧 dataURL 数组（按时间顺序，1~N 帧）
 * @returns {Promise<{ok:boolean, text:string, mode:'live'|'demo', error?:string}>}
 */
export function describeVideoFrames(frameDataUrls) {
  const cfg = getVisionConfig();
  const frames = (frameDataUrls || []).filter(Boolean);
  if (!isVisionConfigured() || frames.length === 0) {
    const text = demoDescription('video', _demoIdx++);
    return Promise.resolve({ ok: true, text: text, mode: 'demo' });
  }
  const body = buildVideoRequest(cfg.model, frames);
  return postVision(cfg, body)
    .then((text) => ({ ok: true, text: text, mode: 'live' }))
    .catch((e) => ({
      ok: false,
      text: demoDescription('video', _demoIdx++),
      mode: 'demo',
      error: (e && e.message) || String(e)
    }));
}
