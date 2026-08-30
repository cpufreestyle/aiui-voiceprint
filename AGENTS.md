# 听障助手 (Rokid AIUI Agent)

Rokid AIUI 智能体应用，面向听障人群提供说话人识别与实时对话字幕辅助，基于声纹生物特征技术识别说话人身份。

## Getting Started

本工程无第三方依赖，不需要安装依赖包。运行方式：

1. 用 Rokid AIUI Studio 直接打开本项目目录（入口配置 `app.json`）；或
2. 在 Rokid AIUI Studio 中导入 `aiui-voiceprint.aix` 产物包；或
3. Rokid 眼镜真机调试

> `.aix` 是产物包，修改 `pages/`、`utils/` 后需重新打包，否则会缺失新增页面。

## Capabilities

- Voiceprint enrollment with multi-sample recording（声纹注册）
- Speaker verification using acoustic feature matching（说话人验证）
- Conversation subtitles / real-time transcription（对话字幕）
- Glasses capture narration / vision description（眼镜拍摄解说）
- AI-assisted voice analysis（AI 辅助语音分析）

## Permissions

- microphone
- network
- audio
- storage
- camera

## Interaction (全应用统一)

- 滑动（左右/上下）= 选择功能
- 短按（镜腿/点击）= 进入·执行
- 双击（镜腿/长按）= 退出

Enjoy!
