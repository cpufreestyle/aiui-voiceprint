/**
 * 拍摄解说 · 媒体限制与多模态 payload 纯逻辑
 *
 * 本模块零平台依赖（不 import wx），只放「常量 + 纯函数」，因此可直接用 node 冒烟测试。
 * 负责：数量/大小硬约束、base64 字节估算、Agnes AI（OpenAI 兼容）请求体构造与响应解析、
 * 以及未配置视觉模型时的演示解说文本。
 *
 * 需求约束（用户指定）：
 *   - 一次解说最少 3 项、最多 5 项媒体
 *   - 单张图片 ≤ 5MB
 *   - 单个视频 ≤ 50MB
 */

// ===== 数量与大小硬约束 =====
export const MIN_ITEMS = 3;
export const MAX_ITEMS = 5;
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;   // 5MB
export const MAX_VIDEO_BYTES = 50 * 1024 * 1024;  // 50MB

// ===== 中文解说提示词（面向听障/需要「用眼睛替代」的场景）=====
export const IMAGE_PROMPT =
  '你是听障人士的眼睛。请用简洁口语化的中文，描述这张照片里的主要内容：场景、人物、物体和正在发生的事。' +
  '40 字以内，直接说重点，不要客套，不要以「这张照片」开头。';
export const VIDEO_PROMPT =
  '你是听障人士的眼睛。下面按时间顺序给出一段视频的若干关键帧。请综合它们，用简洁口语化的中文描述视频里发生了什么：' +
  '场景、人物动作、事件经过。50 字以内，直接说重点，不要客套。';

// 未配置视觉模型时的演示解说（明确标注，绝不冒充真实识别结果）
const DEMO_IMAGE_TEXTS = [
  '演示解说：画面正中似乎有一个人，背景像是明亮的室内。（未配置视觉模型，此为演示文本）',
  '演示解说：一张户外照片，光线充足，远处有建筑轮廓。（未配置视觉模型，此为演示文本）',
  '演示解说：近景物体占据画面，色彩偏暖。（未配置视觉模型，此为演示文本）'
];
const DEMO_VIDEO_TEXTS = [
  '演示解说：一段室内视频，画面里有人在走动。（未配置视觉模型，此为演示文本）',
  '演示解说：视频记录了一段户外场景，镜头有轻微移动。（未配置视觉模型，此为演示文本）'
];

/**
 * 估算 base64 字符串对应的原始字节数。
 * 支持带 dataURL 前缀（data:image/jpeg;base64,xxxx）或纯 base64。
 * @param {string} b64
 * @returns {number} 字节数
 */
export function base64ByteLength(b64) {
  if (!b64 || typeof b64 !== 'string') return 0;
  const comma = b64.indexOf(',');
  const pure = comma >= 0 && b64.slice(0, comma).indexOf('base64') >= 0
    ? b64.slice(comma + 1)
    : b64;
  const len = pure.length;
  if (len === 0) return 0;
  let padding = 0;
  if (pure.charCodeAt(len - 1) === 61) padding++;      // '='
  if (len > 1 && pure.charCodeAt(len - 2) === 61) padding++;
  return Math.max(0, Math.floor(len * 3 / 4) - padding);
}

/**
 * 人类可读的体积文字。
 * @param {number} bytes
 * @returns {string}
 */
export function formatBytes(bytes) {
  if (!bytes || bytes <= 0) return '0B';
  if (bytes < 1024) return bytes + 'B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + 'KB';
  return (bytes / 1024 / 1024).toFixed(1) + 'MB';
}

/**
 * 图片大小校验。
 * @param {number} bytes 字节数（0 或负数视为「大小未知」，放行但标记 unknown）
 * @returns {{ok:boolean, reason:string, unknown:boolean}}
 */
export function checkImageSize(bytes) {
  if (!bytes || bytes <= 0) return { ok: true, reason: '', unknown: true };
  if (bytes > MAX_IMAGE_BYTES) {
    return { ok: false, reason: '图片 ' + formatBytes(bytes) + ' 超过 5MB 上限', unknown: false };
  }
  return { ok: true, reason: '', unknown: false };
}

/**
 * 视频大小校验。
 * @param {number} bytes 字节数（0 或负数视为「大小未知」，放行但标记 unknown）
 * @returns {{ok:boolean, reason:string, unknown:boolean}}
 */
export function checkVideoSize(bytes) {
  if (!bytes || bytes <= 0) return { ok: true, reason: '', unknown: true };
  if (bytes > MAX_VIDEO_BYTES) {
    return { ok: false, reason: '视频 ' + formatBytes(bytes) + ' 超过 50MB 上限', unknown: false };
  }
  return { ok: true, reason: '', unknown: false };
}

/**
 * 是否已达到可以「开始解说」的数量（≥MIN_ITEMS）。
 */
export function canDescribe(count) {
  return count >= MIN_ITEMS;
}

/**
 * 是否已达到数量上限（≥MAX_ITEMS，不能再采集）。
 */
export function isFull(count) {
  return count >= MAX_ITEMS;
}

/**
 * 构造 Agnes AI（OpenAI 兼容 /chat/completions）单张图片请求体。
 * @param {string} model  模型名（如 agnes-2.0-flash）
 * @param {string} dataUrl data:image/...;base64,xxx 或纯 base64
 * @param {string} [prompt]
 * @returns {object} 可直接 JSON.stringify 作为 wx.request 的 data
 */
export function buildImageRequest(model, dataUrl, prompt) {
  const url = dataUrl.indexOf('data:') === 0 ? dataUrl : ('data:image/jpeg;base64,' + dataUrl);
  return {
    model: model,
    messages: [
      {
        role: 'user',
        content: [
          { type: 'text', text: prompt || IMAGE_PROMPT },
          { type: 'image_url', image_url: { url: url } }
        ]
      }
    ]
  };
}

/**
 * 构造视频请求体：把若干关键帧作为多张图片一并送入，让模型综合描述。
 * （平台无 uploadFile、50MB 视频整体 base64 上传不现实，故以关键帧近似「识别视频内容」。）
 * @param {string} model
 * @param {string[]} frameDataUrls 关键帧 dataURL 数组（按时间顺序）
 * @param {string} [prompt]
 * @returns {object}
 */
export function buildVideoRequest(model, frameDataUrls, prompt) {
  const content = [{ type: 'text', text: prompt || VIDEO_PROMPT }];
  for (const f of (frameDataUrls || [])) {
    const url = f.indexOf('data:') === 0 ? f : ('data:image/jpeg;base64,' + f);
    content.push({ type: 'image_url', image_url: { url: url } });
  }
  return { model: model, messages: [{ role: 'user', content: content }] };
}

/**
 * 从 Agnes / OpenAI 兼容响应体中取出解说文字。
 * 兼容 content 为字符串或分段数组两种形态；取不到返回 null。
 * @param {object} data wx.request success 回调里的 res.data
 * @returns {string|null}
 */
export function parseVisionText(data) {
  if (!data) return null;
  const choices = data.choices;
  if (!choices || !choices.length) return null;
  const msg = choices[0].message || choices[0].delta;
  if (!msg) return null;
  let content = msg.content;
  if (typeof content === 'string') return content.trim() || null;
  if (Array.isArray(content)) {
    const parts = content
      .map((c) => (c && (c.text || c.content)) || '')
      .filter(Boolean);
    const joined = parts.join('').trim();
    return joined || null;
  }
  return null;
}

/**
 * 演示解说文本（轮换），供未配置真实视觉模型时使用。
 * @param {'image'|'video'} kind
 * @param {number} idx 轮换索引
 */
export function demoDescription(kind, idx) {
  const pool = kind === 'video' ? DEMO_VIDEO_TEXTS : DEMO_IMAGE_TEXTS;
  return pool[(idx || 0) % pool.length];
}
