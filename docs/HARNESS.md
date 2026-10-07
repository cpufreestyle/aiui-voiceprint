# Harness — 听障助手 验收自检

> 配套 docs/SPEC.md 使用；修改 pages/ 或 utils/ 后必须跑一遍。

## 自动自检（提交前）

```bash
node scripts/verify.js
```

覆盖项：

1. app.json 声明的每个页面在 pages/ 下有对应 .ink 文件。
2. 每个 .ink 有 <script def> 头部且带 data schema。
3. 每个页面接入手势（page-shell.js 或自身 onKeyDown），防止预览 / 审核点击无响应。
4. utils/recorder.js 的 start() 只传 4 参，无 duration / encodeBitRate（回归第 3 轮驳回）。
5. utils/recording-session.js 对 frameBuffer.slice(0) 复制（防空帧导致录入死循环）。
6. 仓库内不存在被追踪的 DS_Store / 日志 / 备份等垃圾文件。
7. .ink 内不散落硬编码绿色十六进制（统一走主题 token）。
8. pages/ 或 utils/ 比产物 aiui-voiceprint.aix 新时提醒重新打包。

## 人工清单（提审前对照 docs/SPEC.md §6–§8）

- [ ] 手势冒烟：主页拖拽 ≠ 点击；短按进入；长按退出。
- [ ] 录入链路：3 句样本 → 保存 → 主页出现对应用户。
- [ ] 验证链路：3 秒录音 → 文字结果反馈。
- [ ] 对话字幕：连续听 / 暂停 / 起名 / 回看 50 条。
- [ ] 拍摄解说：拍照 / 录像 → 有 API Key 真实解说，无 Key 演示模式。
- [ ] 导入导出：剪贴板 JSON 往返，含保密提示与「不支持剪贴板」降级路径。

## 打包与提审

```bash
git status --short          # 确认无意外文件
node scripts/verify.js      # 自动自检
# pages/ 或 utils/ 有改动 → 在 AIUI Studio 重新导出 aiui-voiceprint.aix
git add -A && git commit -m "..." && git push origin main
```
