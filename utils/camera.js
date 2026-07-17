/**
 * 相机（拍照 / 录像）适配层 —— 眼镜端拍摄
 *
 * 平台事实：AIUI media 文档提供 wx.createCameraContext()（微信兼容 CameraContext），
 * 配合页面里的 <camera> 组件使用；建议在 onReady() 之后创建 context。
 * 方法与微信小程序一致：takePhoto / startRecord / stopRecord。
 *
 * 平台缺口与应对（诚实标注，均做能力探测 + 降级，绝不在无能力时静默卡死）：
 *   - 无 wx.uploadFile：图片改为读成 base64，由 vision 层 POST 给多模态网关；
 *   - 读文件 / 取大小的 API 各运行时命名不一：pathToBase64 / getFileBytes 均做多路降级，
 *     任一可用即用，全不可用则返回 null（上层据此降级为「大小未知」或演示解说）。
 *
 * 全部封装为 Promise，异常一律 reject/返回 null，不抛穿到页面。
 */

import wx from 'wx';

/**
 * 安全获取 CameraContext。不同运行时位置可能不同（wx.createCameraContext / wx.media.createCameraContext）。
 * @returns {Object|null} CameraContext；无相机能力时返回 null
 */
export function acquireCameraContext() {
  const candidates = [];
  try {
    if (typeof wx.createCameraContext === 'function') candidates.push(() => wx.createCameraContext());
  } catch (e) {}
  try {
    if (wx && wx.media && typeof wx.media.createCameraContext === 'function') {
      candidates.push(() => wx.media.createCameraContext());
    }
  } catch (e) {}
  for (let i = 0; i < candidates.length; i++) {
    try {
      const ctx = candidates[i]();
      if (ctx) return ctx;
    } catch (e) {
      console.log('[camera] 创建 CameraContext 失败: ' + (e && e.message ? e.message : e));
    }
  }
  return null;
}

export function isCameraAvailable() {
  try {
    return typeof wx !== 'undefined' && wx &&
      (typeof wx.createCameraContext === 'function' ||
        (wx.media && typeof wx.media.createCameraContext === 'function'));
  } catch (e) {
    return false;
  }
}

/**
 * 拍照。
 * @param {Object} ctx CameraContext
 * @param {Object} [opts] { quality:'high'|'normal'|'low' }
 * @returns {Promise<{tempImagePath:string}>}
 */
export function takePhoto(ctx, opts) {
  return new Promise(function (resolve, reject) {
    if (!ctx || typeof ctx.takePhoto !== 'function') {
      reject(new Error('无拍照能力'));
      return;
    }
    try {
      ctx.takePhoto({
        quality: (opts && opts.quality) || 'high',
        success: function (res) {
          if (res && res.tempImagePath) resolve({ tempImagePath: res.tempImagePath });
          else reject(new Error('拍照未返回图片路径'));
        },
        fail: function (err) {
          reject(new Error((err && err.errMsg) || '拍照失败'));
        }
      });
    } catch (e) {
      reject(e);
    }
  });
}

/**
 * 开始录像。
 * @param {Object} ctx CameraContext
 * @param {Function} [onTimeout] 达到平台录制上限时的回调
 * @returns {Promise<void>}
 */
export function startRecord(ctx, onTimeout) {
  return new Promise(function (resolve, reject) {
    if (!ctx || typeof ctx.startRecord !== 'function') {
      reject(new Error('无录像能力'));
      return;
    }
    try {
      ctx.startRecord({
        success: function () { resolve(); },
        fail: function (err) { reject(new Error((err && err.errMsg) || '开始录像失败')); },
        timeoutCallback: function () { if (typeof onTimeout === 'function') onTimeout(); }
      });
    } catch (e) {
      reject(e);
    }
  });
}

/**
 * 停止录像。
 * @param {Object} ctx CameraContext
 * @param {Object} [opts] { compressed:boolean }
 * @returns {Promise<{tempVideoPath:string, tempThumbPath:string}>}
 */
export function stopRecord(ctx, opts) {
  return new Promise(function (resolve, reject) {
    if (!ctx || typeof ctx.stopRecord !== 'function') {
      reject(new Error('无录像能力'));
      return;
    }
    try {
      ctx.stopRecord({
        compressed: !!(opts && opts.compressed),
        success: function (res) {
          resolve({
            tempVideoPath: (res && res.tempVideoPath) || '',
            tempThumbPath: (res && res.tempThumbPath) || ''
          });
        },
        fail: function (err) {
          reject(new Error((err && err.errMsg) || '停止录像失败'));
        }
      });
    } catch (e) {
      reject(e);
    }
  });
}

/**
 * 把本地临时文件路径读为 base64（不含 dataURL 前缀）。多路降级：
 *   1) wx.getFileSystemManager().readFile({ encoding:'base64' })
 *   2) wx.readFile（部分运行时）
 *   3) Web 标准 fetch(path) → blob → FileReader.readAsDataURL
 * 全部不可用 / 失败则 resolve(null)，由上层降级处理。
 * @param {string} path 临时文件路径（tempImagePath / tempThumbPath）
 * @returns {Promise<string|null>} 纯 base64（无前缀）或 null
 */
export function pathToBase64(path) {
  return new Promise(function (resolve) {
    if (!path) { resolve(null); return; }

    // 路线 1：FileSystemManager.readFile
    try {
      if (typeof wx.getFileSystemManager === 'function') {
        const fsm = wx.getFileSystemManager();
        if (fsm && typeof fsm.readFile === 'function') {
          fsm.readFile({
            filePath: path,
            encoding: 'base64',
            success: function (res) { resolve(stripDataUrl(res && res.data) || null); },
            fail: function () { tryFetch(path, resolve); }
          });
          return;
        }
      }
    } catch (e) {}

    // 路线 2：wx.readFile（少数运行时）
    try {
      if (typeof wx.readFile === 'function') {
        wx.readFile({
          filePath: path,
          encoding: 'base64',
          success: function (res) { resolve(stripDataUrl(res && res.data) || null); },
          fail: function () { tryFetch(path, resolve); }
        });
        return;
      }
    } catch (e) {}

    // 路线 3：Web fetch
    tryFetch(path, resolve);
  });
}

// Web 标准兜底：fetch 本地路径 → blob → dataURL → 剥前缀
function tryFetch(path, resolve) {
  try {
    if (typeof fetch !== 'function' || typeof FileReader !== 'function') {
      resolve(null);
      return;
    }
    fetch(path)
      .then((r) => r.blob())
      .then((blob) => {
        const reader = new FileReader();
        reader.onloadend = function () { resolve(stripDataUrl(reader.result) || null); };
        reader.onerror = function () { resolve(null); };
        reader.readAsDataURL(blob);
      })
      .catch(function () { resolve(null); });
  } catch (e) {
    resolve(null);
  }
}

function stripDataUrl(s) {
  if (!s || typeof s !== 'string') return s;
  const comma = s.indexOf(',');
  if (s.indexOf('data:') === 0 && comma >= 0) return s.slice(comma + 1);
  return s;
}

/**
 * 获取本地文件字节数。多路降级：
 *   1) wx.getFileSystemManager().getFileInfo / statSync
 *   2) wx.getFileInfo
 * 全部不可用 / 失败则 resolve(null)（上层按「大小未知」放行并提示）。
 * @param {string} path
 * @returns {Promise<number|null>}
 */
export function getFileBytes(path) {
  return new Promise(function (resolve) {
    if (!path) { resolve(null); return; }

    // 路线 1：FileSystemManager
    try {
      if (typeof wx.getFileSystemManager === 'function') {
        const fsm = wx.getFileSystemManager();
        if (fsm && typeof fsm.getFileInfo === 'function') {
          fsm.getFileInfo({
            filePath: path,
            success: function (res) { resolve(typeof res.size === 'number' ? res.size : null); },
            fail: function () { resolve(null); }
          });
          return;
        }
        if (fsm && typeof fsm.statSync === 'function') {
          try {
            const st = fsm.statSync(path);
            resolve(st && typeof st.size === 'number' ? st.size : null);
          } catch (e) { resolve(null); }
          return;
        }
      }
    } catch (e) {}

    // 路线 2：wx.getFileInfo
    try {
      if (typeof wx.getFileInfo === 'function') {
        wx.getFileInfo({
          filePath: path,
          success: function (res) { resolve(typeof res.size === 'number' ? res.size : null); },
          fail: function () { resolve(null); }
        });
        return;
      }
    } catch (e) {}

    resolve(null);
  });
}
