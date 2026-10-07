#!/usr/bin/env node
/**
 * 听障助手 — 仓库自检 harness
 * 用法：node scripts/verify.js
 * 无第三方依赖。覆盖 docs/HARNESS.md 中「自动自检」的检查项。
 */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
let failures = 0;
const fail = (msg) => { failures++; console.log('  FAIL  ' + msg); };
const pass = (msg) => console.log('  ok    ' + msg);
const section = (t) => console.log('\n== ' + t + ' ==');

function read(p) { return fs.readFileSync(path.join(ROOT, p), 'utf8'); }
function readJson(p) { return JSON.parse(read(p)); }

// 1. app.json 页面声明 ↔ 实际页面
section('1. app.json 页面声明 ↔ 实际页面');
const appJson = readJson('app.json');
for (const page of appJson.pages) {
  const ink = page + '.ink';
  if (fs.existsSync(path.join(ROOT, ink))) pass(ink);
  else fail(ink + ' 缺失');
}

// 2. 每个页面都有 <script def> + schema
section('2. 每个页面 <script def> + schema');
for (const page of appJson.pages) {
  const src = read(page + '.ink');
  const hasDef = src.includes('<script def>');
  const hasSchema = /"schema"\s*:/.test(src) && /"data"\s*:/.test(src);
  if (hasDef && hasSchema) pass(page);
  else fail(page + ' 缺 script def 或 schema');
}

// 3. 每个页面接入手势（page-shell 或自身 onKeyDown）
section('3. 手势接入');
for (const page of appJson.pages) {
  const src = read(page + '.ink');
  if (src.includes('page-shell.js') || src.includes('onKeyDown')) pass(page);
  else fail(page + ' 未接入手势系统');
}

// 4. recorder.start() 只传 4 参
section('4. recorder.js 4 参签名（回归 2026-09-26 驳回）');
const recorderSrc = read('utils/recorder.js');
if (/(duration|encodeBitRate)/.test(recorderSrc)) {
  fail('utils/recorder.js 出现 duration/encodeBitRate');
} else pass('recorder.js 不含 duration / encodeBitRate');

// 5. recording-session 必须复制 frameBuffer
section('5. recording-session frameBuffer 复制');
const sessionSrc = read('utils/recording-session.js');
if (sessionSrc.includes('.slice(0)')) pass('frameBuffer.slice(0) 存在');
else fail('frameBuffer 未做 .slice(0) 复制');

// 6. 无被追踪的垃圾文件
section('6. 无被追踪垃圾文件');
let junk = [];
try {
  junk = execSync('git ls-files', { cwd: ROOT }).toString().split('\n')
    .filter(f => /(^|\/)\.DS_Store$|\.log$|\.bak$|__pycache__|nohup\.out$/i.test(f.trim()));
} catch (e) { /* git 不可用则跳过 */ }
if (junk.length === 0) pass('垃圾文件清单为空');
else fail('垃圾文件: ' + junk.join(', '));

// 7. .ink 不散落硬编码绿色十六进制
section('7. 主题色统一（无硬编码绿色十六进制）');
const HEX = /#[0-9a-f]{6}\b/gi;
const GREEN_HEX = new Set([
  '#4caf50', '#43a047', '#388e3c', '#2e7d32', '#1b5e20',
  '#66bb6a', '#81c784', '#a5d6a7', '#00e676', '#00c853'
]);
const offenders = [];
for (const page of appJson.pages) {
  const src = read(page + '.ink');
  const matches = src.match(HEX) || [];
  if (matches.some(m => GREEN_HEX.has(m.toLowerCase()))) offenders.push(page);
}
if (offenders.length === 0) pass('无散落绿色十六进制');
else fail('硬编码绿色: ' + offenders.join(', '));

// 8. .aix 同步状况
section('8. 产物包同步');
const aixPath = path.join(ROOT, 'aiui-voiceprint.aix');
if (fs.existsSync(aixPath)) {
  const aixMtime = fs.statSync(aixPath).mtimeMs;
  let newestSrc = 0;
  for (const dir of ['pages', 'utils']) {
    const walk = (d) => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) walk(p);
        else newestSrc = Math.max(newestSrc, fs.statSync(path.join(ROOT, p)).mtimeMs);
      }
    };
    walk(dir);
  }
  if (newestSrc <= aixMtime) pass('aiui-voiceprint.aix 与源码同步');
  else console.log('  WARN  pages/ utils/ 比 .aix 新；若已提审可忽略，否则请重新打包');
} else fail('aiui-voiceprint.aix 不存在');

console.log('\n' + (failures === 0 ? '✔ 全部通过' : '✘ ' + failures + ' 项未通过'));
process.exit(failures === 0 ? 0 : 1);

