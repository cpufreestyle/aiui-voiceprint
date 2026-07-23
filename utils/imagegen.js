/**
 * 相似图生成适配层 —— 用例C「拍照→生成相似图→发手机」的生成环节
 *
 * 平台事实（见 docs/架构-语音直呼集成.md §5.1 + Rokid 官方文档 + 2026-07 实测）：
 *   - 端上无图像生成能力；网络只有 wx.request，没有 wx.uploadFile；
 *   - 标准「图生图」/images/edits 需 multipart 上传文件（uploadFile），端上做不到；
 *   - 实测：图像模型打 /chat/completions 会确定性 404，文生图须走 /images/generations
 *     （返回 { data: [{ url }] }，agnes-image-2.1-flash + 1024x1024 已实测出图成功）。
 *   → 因此用「图→文→图」两跳近似图生图：先用 vision.describeImage 把照片转成画面描述，
 *     再把描述交给 /images/generations 文生图，得到风格/主体相近的新图。
 *
 * 设计（对齐 vision.js 的「能力探测 + demo 降级」范式）：
 *   - 已配置 apiKey 且有 wx.request → 真机联网生成；否则/失败 → 演示文案，绝不冒充真实生成。
 *   - generateSimilar 永不 reject：失败一律 resolve 带 demo/error 标注的对象，pages/genimg 诚实降级。
 *   - 换风格重生成：调用方传 opts.baseDesc 复用首次的画面描述，免二次视觉调用；成功回传 basedOn 供缓存。
 *
 * 安全：apiKey 统一读 cloud-ai.js 内置 Agnes Key（与主持人V2同一个），用户可在设置面板覆盖。
 */

import wx from 'wx';
import { AGNES_API_KEY, AGNES_IMAGE_URL, AGNES_IMAGE_MODEL } from './cloud-ai.js';
import { describeImage } from './vision.js';

const STORAGE_KEY = 'imagegen_config';

// 默认配置：与 vision.js 共用 cloud-ai.js 里同一个内置 Agnes Key/网关（统一多模态）。
// 测试版无需在眼镜端填 Key；用户仍可在设置面板临时覆盖（storage 优先级更高）。
const DEFAULT_CONFIG = {
  baseUrl: AGNES_IMAGE_URL, // 文生图端点 /images/generations（实测可用；chat 端点会 404）
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
  if (!cfg.baseUrl) cfg.baseUrl = AGNES_IMAGE_URL;
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

// 构造文生图请求体（/images/generations 形态）：把「画面描述」拼成生成 prompt。
// desc 来自 vision.describeImage 对照片的结构化描述（或 opts.baseDesc 缓存）。
function buildGenBody(cfg, desc, opts) {
  const style = (opts && opts.style) || '相似示意图';
  const extra = (opts && opts.extra) ? ('，' + opts.extra) : '';
  const size = (opts && opts.size) || '1024x1024'; // 实测正方形可用；16:9 建议 1280x720
  const prompt = '参照以下画面描述，生成一张风格相近、主体结构相似的' + style + '：' + desc + extra;
  return {
    model: cfg.model,
    prompt: prompt,
    size: size,
    n: 1
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
 * 生成一张与输入图相似的图（图→文→图两跳）。
 * @param {string} dataUrl 拍照 base64（data:image/...;base64,xxx 或纯 base64）；换风格重生成时可传 null。
 * @param {Object} [opts] { style, size, extra, baseDesc }
 *   - baseDesc：首次生成缓存的画面描述；有它则跳过视觉调用直接文生图（换风格重生成用）。
 *   - extra：追加到 prompt 的风格扩写词（如「水彩风格」）。
 * @returns {Promise<{ok:boolean, imageUrl:string, demo?:boolean, text?:string, basedOn?:string, error?:string}>}
 *   永不 reject：
 *     - 未配置/无底稿来源 → { ok:true, imageUrl:'', demo:true, text: 演示文案 }
 *     - 生成成功         → { ok:true, imageUrl: 生成图地址, demo:false, basedOn: 画面描述 }
 *     - 描述/生成失败     → { ok:false, imageUrl:'', demo:true, text: 演示文案, error }
 */
export function generateSimilar(dataUrl, opts) {
  const cfg = getImagegenConfig();
  const baseDesc = opts && opts.baseDesc;
  // 需要「有网络+key」且「有底稿来源」：底稿 = 现成 baseDesc，或一张可供描述的照片
  if (!isImagegenConfigured() || (!dataUrl && !baseDesc)) {
    return Promise.resolve({ ok: true, imageUrl: '', demo: true, text: DEMO_TEXT });
  }

  // 第一跳：拿画面描述。换风格重生成传了 baseDesc 就直接复用（可信、免二次视觉调用）；
  // 否则用 vision.describeImage 真实描述照片——若视觉未走 live（失败/降级）则不拿演示文案冒充。
  const descPromise = baseDesc
    ? Promise.resolve({ text: baseDesc, live: true })
    : describeImage(dataUrl).then((r) => ({ text: (r && r.text) || '', live: !!(r && r.mode === 'live') }));

  return descPromise.then((d) => {
    if (!d.text || !d.live) {
      return { ok: false, imageUrl: '', demo: true, text: DEMO_TEXT, error: d.text ? '照片描述未走真实视觉，放弃生成以免出错图' : '照片描述失败' };
    }
    // 第二跳：把描述交给 /images/generations 文生图
    const body = buildGenBody(cfg, d.text, opts);
    return postImagegen(cfg, body)
      .then((url) => ({ ok: true, imageUrl: url, demo: false, basedOn: d.text }))
      .catch((e) => ({ ok: false, imageUrl: '', demo: true, text: DEMO_TEXT, error: (e && e.message) || String(e) }));
  });
}
