/**
 * 云 relay 客户端 —— 用例C「生成结果 → 手机」的中转桥（眼镜端只做客户端）
 *
 * 依据 docs/架构-语音直呼集成.md §5.2/§5.3 契约（云端 relay 是必须新建的外部组件，
 * 由另一 Agent 负责实现与部署，本文件不涉及服务端逻辑，只按契约调用）：
 *
 *   POST {RELAY_BASE}/push   body: { code, imageUrl, ttlSec }
 *     resp: { ok:true, pullUrl } | { ok:false, msg }
 *     行为: relay 内存/Redis 存 code→imageUrl，TTL 过期即焚
 *
 *   GET  {RELAY_BASE}/pull?code=xxxx   —— 手机侧调用，本文件不涉及
 *   GET  {RELAY_BASE}/r/{code}         —— 手机 H5 结果页，本文件不涉及
 *   GET  {RELAY_BASE}/qr?code=xxxx     —— relay 代画二维码 PNG，供眼镜端 <image> 加载
 *
 * 设计（对齐 vision.js / imagegen.js 的「能力探测 + 降级」范式）：
 *   - pushResult 永不 reject：失败一律 resolve { ok:false, error }，
 *     由调用方（pages/genimg）据此渲染「发送手机失败，图片地址：...」的诚实降级字幕
 *     （见文档 §5.2 注释：至少给出 URL 口述，不能静默卡死）。
 *
 * 二维码三级降级（见文档 §5.2 / §7 表「端上二维码渲染」行）：
 *   ① 内置纯 JS qrcode 库直接生成 dataURL —— 本期未内置（体积/依赖未评估），显式跳过；
 *   ② relay 代画：<image src="{RELAY_BASE}/qr?code=xxxx">（本文件 qrImageUrl 即此，走第②级）；
 *   ③ 都不行时页面仍展示大号取件码 + TTS 逐位播报作最终兜底
 *     （该兜底文案与 UI 由 pages/genimg 负责渲染，非本文件职责——本文件只负责把
 *     二维码地址算出来，<image> 加载失败与否是页面层的事）。
 */

import wx from 'wx';

const STORAGE_KEY = 'relay_base';

// 占位默认值：必须由部署方在设置面板里改成真实 relay 域名（见 §5.3 契约，需另建云端服务）。
// 仍是占位值时视为「未配置」，pushResult 会直接给出清晰的错误说明，不会真的发请求出去。
const DEFAULT_RELAY_BASE = 'https://relay.example.com';

function requestAvailable() {
  return typeof wx !== 'undefined' && wx && typeof wx.request === 'function';
}

/** 读取当前 relay 域名（storage 覆盖默认占位值，末尾斜杠已去除）。 */
export function getRelayBase() {
  let saved = null;
  try { saved = wx.getStorageSync(STORAGE_KEY); } catch (e) {}
  const v = (saved && typeof saved === 'string' && saved.trim()) || DEFAULT_RELAY_BASE;
  return v.replace(/\/+$/, '');
}

/** 写入 relay 域名。返回写入后的规范化值。 */
export function setRelayBase(base) {
  const trimmed = (base || '').trim().replace(/\/+$/, '');
  const next = trimmed || DEFAULT_RELAY_BASE;
  try { wx.setStorageSync(STORAGE_KEY, next); } catch (e) {}
  return next;
}

/** 是否已配置真实 relay 地址（而非仍是占位域名）且具备网络能力。 */
export function isRelayConfigured() {
  const base = getRelayBase();
  return requestAvailable() && !!base && base !== DEFAULT_RELAY_BASE;
}

/**
 * 生成 4 位数字取件码（字符串，含前导零，便于逐位语音播报）。
 * @returns {string}
 */
export function makeCode() {
  return String(Math.floor(Math.random() * 10000)).padStart(4, '0');
}

/**
 * 把生成结果推给 relay，换取手机侧可访问的拉取地址。
 * @param {string} code 4 位取件码
 * @param {string} imageUrl 生成图片的地址（URL 或 data: base64，是否落地成文件由 relay 决定）
 * @returns {Promise<{ok:boolean, pullUrl?:string, error?:string}>}
 *   永不 reject：网络失败 / relay 返回失败 / 未配置 relay 地址，均以 { ok:false, error } 呈现。
 */
export function pushResult(code, imageUrl) {
  return new Promise(function (resolve) {
    const base = getRelayBase();

    if (!requestAvailable()) {
      resolve({ ok: false, error: '当前环境无网络请求能力（wx.request 不可用）' });
      return;
    }
    if (!code || !imageUrl) {
      resolve({ ok: false, error: '缺少取件码或图片地址' });
      return;
    }
    if (base === DEFAULT_RELAY_BASE) {
      resolve({ ok: false, error: 'relay 服务地址未配置（仍是占位域名），请先在设置里填入真实地址' });
      return;
    }

    let done = false;
    const finish = (arg) => { if (!done) { done = true; resolve(arg); } };

    // 兜底超时：部分运行时 wx.request 不一定触发 fail
    const timer = setTimeout(function () {
      finish({ ok: false, error: '推送到手机超时' });
    }, 15000);

    try {
      wx.request({
        url: base + '/push',
        method: 'POST',
        timeout: 12000,
        header: { 'Content-Type': 'application/json' },
        data: { code: code, imageUrl: imageUrl, ttlSec: 1800 },
        success: function (res) {
          clearTimeout(timer);
          const status = res && res.statusCode;
          if (status && status >= 400) {
            finish({ ok: false, error: '服务返回 ' + status });
            return;
          }
          let data = res && res.data;
          if (typeof data === 'string') {
            try { data = JSON.parse(data); } catch (e) {}
          }
          if (data && data.ok) {
            finish({ ok: true, pullUrl: data.pullUrl || (base + '/r/' + code) });
          } else {
            finish({ ok: false, error: (data && data.msg) || '推送失败' });
          }
        },
        fail: function (err) {
          clearTimeout(timer);
          finish({ ok: false, error: (err && err.errMsg) || '网络请求失败' });
        }
      });
    } catch (e) {
      clearTimeout(timer);
      finish({ ok: false, error: (e && e.message) || String(e) });
    }
  });
}

/**
 * 手机扫码直达的二维码图片地址（降级序第②级：relay 代画）。
 * 依赖 relay 已实现 GET /qr?code=xxxx 返回 PNG（见 §5.3），
 * 且当前 wx <image> 组件能加载外网图片（文档 §8 未决项 7，未证实，需实机验证；
 * 加载失败时页面上并存的大号取件码文案即是第③级最终兜底，不依赖这张图能否显示）。
 * @param {string} code
 * @returns {string} 完整 URL，供 <image src> 直接使用
 */
export function qrImageUrl(code) {
  return getRelayBase() + '/qr?code=' + encodeURIComponent(code || '');
}
