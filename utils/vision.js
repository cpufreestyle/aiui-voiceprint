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

const STORAGE_KEY = 'vision_config';

// 默认配置：预填 Agnes AI 网关与模型；apiKey 留空（=演示模式），由用户在设置里填入。
// agnes-2.0-flash 为多模态理解模型（已实测支持 image_url + base64 图片识别）。
const DEFAULT_CONFIG = {
  baseUrl: 'https://apihub.agnes-ai.com/v1/chat/completions',
  apiKey: '',
  model: 'agnes-2.0-flash'
};

const REQUEST_TIMEOUT_MS = 20000;

let _demoIdx = 0;

function requestAvailable() {
  return typeof wx !== 'undefined' && wx && typeof wx.request === 'function';
}

/** 读取当前视觉配置（storage 覆盖默认值）。 */
export function getVisionConfig() {
  let saved = null;
  try { saved = wx.getStorageSync(STORAGE_KEY); } catch (e) {}
  return Object.assign({}, DEFAULT_CONFIG, saved || {});
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

/**
 * 解说一张图片。
 * @param {string} dataUrl data:image/...;base64,xxx 或纯 base64
 * @returns {Promise<{ok:boolean, text:string, mode:'live'|'demo', error?:string}>}
 *          永不 reject：真机失败会自动降级为演示文本并带 error 说明。
 */
export function describeImage(dataUrl) {
  const cfg = getVisionConfig();
  if (!isVisionConfigured() || !dataUrl) {
    const text = demoDescription('image', _demoIdx++);
    return Promise.resolve({ ok: true, text: text, mode: 'demo' });
  }
  const body = buildImageRequest(cfg.model, dataUrl);
  return postVision(cfg, body)
    .then((text) => ({ ok: true, text: text, mode: 'live' }))
    .catch((e) => ({
      ok: false,
      text: demoDescription('image', _demoIdx++),
      mode: 'demo',
      error: (e && e.message) || String(e)
    }));
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
