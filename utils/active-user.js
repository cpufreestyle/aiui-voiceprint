/**
 * 当前启用身份（Active User）管理
 *
 * 声纹库 voiceprint_db 结构：{ users: [...], activeUserId: 'user_xxx' }
 * 「启用某个声纹」= 把它设为当前身份，主页显示、可来回切换。
 *
 * 说明：
 * - 仅做「当前身份标识」，不改动验证（verify）的 1:N 识别逻辑。
 * - 同步写入 globalData.currentUser，方便其它页面直接读取。
 */

import wx from 'wx';

function readDB() {
  const db = wx.getStorageSync('voiceprint_db');
  if (db && db.users) return db;
  return { users: [] };
}

function writeDB(db) {
  try { wx.setStorageSync('voiceprint_db', db); } catch (e) {}
}

function syncGlobal(user) {
  const app = getApp();
  if (app && app.globalData) app.globalData.currentUser = user || null;
}

// 读取当前启用的用户对象（含 id/name），无则返回 null
export function getActiveUser() {
  const db = readDB();
  if (!db.activeUserId) return null;
  const user = db.users.find((u) => u.id === db.activeUserId);
  return user || null;
}

// 设为当前启用身份；返回该用户对象（找不到返回 null）
export function setActiveUser(id) {
  const db = readDB();
  const user = db.users.find((u) => u.id === id);
  if (!user) return null;
  db.activeUserId = id;
  writeDB(db);
  syncGlobal({ id: user.id, name: user.name });
  return user;
}

// 清除当前启用身份
export function clearActiveUser() {
  const db = readDB();
  if (db.activeUserId) {
    delete db.activeUserId;
    writeDB(db);
  }
  syncGlobal(null);
}

// 删除用户后调用：若删掉的正是当前启用身份，则清空启用标记，避免悬空引用
export function reconcileActiveUser() {
  const db = readDB();
  if (db.activeUserId && !db.users.find((u) => u.id === db.activeUserId)) {
    delete db.activeUserId;
    writeDB(db);
    syncGlobal(null);
  } else {
    const cur = db.users.find((u) => u.id === db.activeUserId);
    syncGlobal(cur ? { id: cur.id, name: cur.name } : null);
  }
}
