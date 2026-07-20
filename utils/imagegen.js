/**
 * 图生图（相似图生成）适配层 —— 用例C「拍照→生成相似图→发手机」的生成环节
 *
 * 平台事实（与 utils/vision.js 同源约束，见 docs/架构-语音直呼集成.md §5.1）：
 *   - 端上无图像生成能力；网络只有 wx.request，没有 wx.uploadFile；
 *   - 因此无法走标准 OpenAI multipart 的 /images/edits（那需要 uploadFile 传文件），
 *     改用 JSON body（图片以 data URL/base64 内嵌）POST 到外部图像生成网关——
 *     形态对齐 vision.js 已验证可行的 chat/completions 多模态请求写法。
 *
 * 设计（对齐 vision.js 的「能力探测 + demo 降级」范式）：
 *   - 已配置 apiKey 且有 wx.request → 真机联网生成；
 *   - 未配置 / 无网络能力 / 请求失败 → 降级为演示文案，绝不冒充真实生成结果。
 *   - generateSimilar 永不 reject：失败一律 resolve 一个带 demo/error 标注的对象，
 *     由调用方（pages/genimg）据此渲染诚实的降级字幕。
 *
 * 安全：apiKey 不硬编码，存本地 storage（imagegen_config），由用户在设置面板填入。
 *
 * 供应商未最终选型（见文档 §8-5，未决项）：响应解析做多形态兼容尝试——
 *   ① OpenAI images 接口形态 { data: [{ url | b64_json }] }；
 *   ② chat/completions 多模态网关把图片挂在 message.images / content 分段；
 *   ③ 纯文本 content 里夹带图片链接或 data:image base64（兜底粗提取）。
 *   全部解析不到则判定为失败，交由降级路径处理。
 */

import wx from 'wx';
import { AGNES_API_KEY, AGNES_BASE_URL, AGNES_IMAGE_MODEL } from './cloud-ai.js';

const STORAGE_KEY = 'imagegen_config';

// 默认配置：与 vision.js 共用 cloud-ai.js 里同一个内置 Agnes Key/网关（统一多模态）。
// 测试版无需在眼镜端填 Key；用户仍可在设置面板临时覆盖（storage 优先级更高）。
const DEFAULT_CONFIG = {
  baseUrl: AGNES_BASE_URL,
  apiKey: AGNES_API_KEY,
  model: AGNES_IMAGE_MODEL
};

const REQUEST_TIMEOUT_MS = 30000; // 图像生成通常 5~30s，超时阈值比 vision.js 更宽松

const DEMO_TEXT = '演示：此处应生成一张相似图（未配置图像生成模型，此为演示文案）';

function requestAvailable() {
  return typeof wx !== 'undefined' && wx && typeof wx.request === 'function';
}

/** 读取当前图像生成配置（storage 覆盖默认值；但 storage 里 Key 为空时回退到内置 Key）。 */
export function getImagegenConfig() {
  let saved = null;
  try { saved = wx.getStorageSync(STORAGE_KEY); } catch (e) {}
  const cfg = Object.assign({}, DEFAULT_CONFIG, saved || {});
  // 内置测试 Key 兜底：避免历史「清除密钥」在 storage 留下空串把内置 Key 覆盖成空。
  if (!cfg.apiKey) cfg.apiKey = AGNES_API_KEY;
  if (!cfg.baseUrl) cfg.baseUrl = AGNES_BASE_URL;
  return cfg;
}

/** 写入/合并图像生成配置（如只更新 apiKey）。返回合并后的配置。 */
export function setImagegenConfig(patch) {
  const next = Object.assign({}, getImagegenConfig(), patch || {});
  try { wx.setStorageSync(STORAGE_KEY, next); } catch (e) {}
  return next;
}

/** 是否具备「真机联网生成」条件：有网络能力 + 已填 apiKey。 */
export function isImagegenConfigured() {
  const cfg = getImagegenConfig();
  return requestAvailable() && !!cfg.apiKey && !!cfg.baseUrl;
}

/** 当前生成模式：'live'（真实模型）/ 'demo'（演示）。 */
export function imagegenMode() {
  return isImagegenConfigured() ? 'live' : 'demo';
}

// 构造请求体：图片以 data URL 内嵌，要求模型参照原图生成风格/构图相似的新图。
function buildRequestBody(cfg, dataUrl, opts) {
  const url = dataUrl.indexOf('data:') === 0 ? dataUrl : ('data:image/jpeg;base64,' + dataUrl);
  const style = (opts && opts.style) || '相似示意图';
  const size = (opts && opts.size) || '1024x1024';
  const prompt = '参照这张照片，生成一张风格相近、主体结构相似的' + style +
    '。请直接返回生成图片（URL 或 base64），不要输出多余文字说明。';
  return {
    model: cfg.model,
    size: size,
    messages: [
      {
        role: 'user',
        content: [
          { type: 'text', text: prompt },
          { type: 'image_url', image_url: { url: url } }
        ]
      }
    ]
  };
}

/**
 * 从多种可能的响应形态中解析出生成图片的地址（URL 或 data: base64）。
 * @param {object} data wx.request success 回调里的 res.data
 * @returns {string|null}
 */
export function parseImagegenResult(data) {
  if (!data) return null;

  // 形态①：OpenAI images 接口 { data: [{ url }] } / { data: [{ b64_json }] }
  if (Array.isArray(data.data) && data.data.length) {
    const item = data.data[0];
    if (item && item.url) return item.url;
    if (item && item.b64_json) return 'data:image/png;base64,' + item.b64_json;
  }

  // 形态②：chat/completions 多模态网关
  const choices = data.choices;
  if (choices && choices.length) {
    const msg = choices[0].message || choices[0].delta;
    if (msg) {
      if (Array.isArray(msg.images) && msg.images.length) {
        const im = msg.images[0];
        const u = (im && im.image_url && im.image_url.url) || (im && im.url);
        if (u) return u;
      }
      if (Array.isArray(msg.content)) {
        for (let i = 0; i < msg.content.length; i++) {
          const c = msg.content[i];
          if (c && c.type === 'image_url' && c.image_url && c.image_url.url) return c.image_url.url;
        }
      }
      // 形态③：纯文本里夹带图片链接或 base64（兜底粗提取）
      if (typeof msg.content === 'string') {
        const m = msg.content.match(/https?:\/\/[^\s"')]+\.(png|jpe?g|webp)/i) ||
          msg.content.match(/data:image\/[a-zA-Z]+;base64,[A-Za-z0-9+/=]+/);
        if (m) return m[0];
      }
    }
  }

  return null;
}

// 统一的一次生成请求：成功 resolve 图片地址，失败 reject。
function postImagegen(cfg, body) {
  return new Promise(function (resolve, reject) {
    let done = false;
    const finish = (fn, arg) => { if (!done) { done = true; fn(arg); } };

    // 兜底超时：部分运行时 wx.request 不一定触发 fail
    const timer = setTimeout(function () {
      finish(reject, new Error('生成请求超时'));
    }, REQUEST_TIMEOUT_MS + 3000);

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
          let data = res && res.data;
          if (typeof data === 'string') {
            try { data = JSON.parse(data); } catch (e) {}
          }
          const url = parseImagegenResult(data);
          if (url) finish(resolve, url);
          else finish(reject, new Error('未解析到生成图片'));
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

/**
 * 生成一张与输入图相似的图。
 * @param {string} dataUrl 拍照 base64（data:image/...;base64,xxx 或纯 base64）；
 *   为空（如无相机时的演示拍照）也会直接走演示降级。
 * @param {Object} [opts] { style, size }
 * @returns {Promise<{ok:boolean, imageUrl:string, demo?:boolean, text?:string, error?:string}>}
 *   永不 reject：
 *     - 未配置/无输入图 → { ok:true, imageUrl:'', demo:true, text: 演示文案 }
 *     - 真机请求成功    → { ok:true, imageUrl: 生成图地址, demo:false }
 *     - 真机请求失败    → { ok:false, imageUrl:'', demo:true, text: 演示文案, error }
 */
export function generateSimilar(dataUrl, opts) {
  const cfg = getImagegenConfig();
  if (!isImagegenConfigured() || !dataUrl) {
    return Promise.resolve({ ok: true, imageUrl: '', demo: true, text: DEMO_TEXT });
  }
  const body = buildRequestBody(cfg, dataUrl, opts);
  return postImagegen(cfg, body)
    .then((url) => ({ ok: true, imageUrl: url, demo: false }))
    .catch((e) => ({
      ok: false,
      imageUrl: '',
      demo: true,
      text: DEMO_TEXT,
      error: (e && e.message) || String(e)
    }));
}
