---
workflow: product-launch-video
flow: automation
storyboard: no
message: "听障助手让听障用户看清对话里「谁在说、说了什么」"
destination: youtube
aspect: "16:9"
language: zh-CN
audience: 听障用户、家属、Rokid 开发者社区
length: 45s
angle: "以「看清谁在说、说了什么」为情感主线，按使用顺序串起四大功能"
voice: "macOS 中文 TTS（zh_CN 男声 Reed）"
capture_mode: no-capture
assets_used:
  - assets/icons/icon-a-bubble-waveform-512.png
  - previews/preview-1-overview.png
  - previews/preview-2-gesture-guide.png
  - previews/preview-3-conversation-subtitle.png
---

# BRIEF — 听障助手 产品宣传视频

## Intent
面向听障人群与 Rokid 开发者社区的产品宣传短片。无官网可抓取，采用 **no-capture** 模式：
以自有图标与预览图为视觉素材，用动画合成页呈现产品价值，而非录屏。

## 叙事线（45s / 中文旁白）
1. 痛点钩子（0–5s）：面对面交流时，听不清「谁在说、说了什么」。
2. 产品登场（5–10s）：听障助手，运行在 Rokid 智能眼镜上。
3. 录入声纹（10–17s）：为常接触的人录 3 句以上，建立声纹。
4. 对话字幕·核心（17–28s）：实时字幕标注「说话人：内容」，陌生人可现场起名。
5. 验证身份（28–34s）：说一句话，确认现在是谁在说话。
6. 拍摄解说（34–40s）：拍下眼前画面，AI 解说并播报。
7. 收尾 CTA（40–45s）：戴上眼镜，重新「看见」每一句对话。

## Customizations
- 画幅 16:9（1920×1080）。
- 中文旁白由 macOS `say` 生成（zh_CN），与动画时间线对齐。
- 视觉：深色科技底 + 声纹波形/对话气泡意象，复用应用图标与三张预览图。

## Notes
- hyperframes 技能仓库（heygen-com/hyperframes）在本机网络下无法克隆，
  改用本地 HTML+Playwright+ffmpeg 管线渲染，交付物等价。
- 旁白配音替代方案：若 Reed 音色不可用，回退 Eddy/Flo（zh_CN）。
