# 听障助手 (Rokid AIUI Agent)

Rokid AIUI 智能体应用，面向听障人群提供说话人识别与实时对话字幕辅助，基于声纹生物特征技术识别说话人身份。

## Getting Started

本工程无第三方依赖，不需要安装依赖包。运行方式：

1. 用 Rokid AIUI Studio 直接打开本项目目录（入口配置 `app.json`）；或
2. 在 Rokid AIUI Studio 中导入 `aiui-voiceprint.aix` 产物包；或
3. Rokid 眼镜真机调试

> `.aix` 是产物包，修改 `pages/`、`utils/` 后需重新打包，否则会缺失新增页面。

## Capabilities（功能介绍）

面向听障人群的交流辅助：看清「谁在说」「说了什么」。

1. **录入声纹（首次必做）**：按提示朗读，录满 3 句以上建立说话人声纹。建议为家人、同事各录一次。
2. **验证身份**：说一句话，系统判断当前说话的是谁（需先录入声纹）。
3. **对话字幕（核心）**：实时把对方的话转为字幕，并在前面标注说话人姓名；已录入显示姓名，未录入显示「陌生人N」，可短按现场起名。
4. **拍摄解说**：拍摄眼前画面，由 AI 生成解说并语音播报（需配置视觉 API Key，否则为演示模式）。

上手路径：先「录入声纹」→ 再用「对话字幕」日常交流；想确认某人用「验证身份」，看不清事物用「拍摄解说」。

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
