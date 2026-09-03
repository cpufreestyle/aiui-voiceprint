# 基于 Rokid AIUI 的听障助手：声纹识别 + 实时字幕实战

> 发布草稿，供粘贴到 CSDN 博客（https://editor.csdn.net/md/）
> 发布前请替换 `[待补充]`，并插入代码截图 / 运行截图。

## 摘要

本文记录一个运行在 Rokid 智能眼镜（AIUI / JSAR 框架）上的听障辅助智能体 **听障助手** 的实现思路。它不只是把语音转成文字，而是**先做说话人识别、再叠加上字幕**，解决听障用户「听不清内容」和「分不清谁在说」两个叠加问题。文章覆盖功能设计、关键技术实现（自研声纹引擎 + Rokid ASR/TTS）、以及开发中踩到的 5 个真实坑（.ink 指令前缀、.aix 打包、录音卡死、手势去抖、审核驳回）。

**关键词**：Rokid AIUI、声纹识别、说话人标注、实时字幕、无障碍、JSAR

---

## 一、背景与目标

听障人群面对面交流的痛点有两个层次：

1. 听不清对方说话的**内容**；
2. 多人场景下分不清**是谁在说**。

多数转写工具只解决第 1 点。但如果不知道说话人是谁，字幕的价值会显著下降。因此本项目的核心目标定为：

> **不只转写内容，还要标出说话人。**

最终形态：眼镜屏幕上实时显示 `说话人：内容`，已录入声纹的直接显示姓名，未录入的显示「陌生人N」并支持现场起名。

## 二、功能设计

四个功能，按使用顺序组织：

| 功能 | 作用 | 关键说明 |
| --- | --- | --- |
| 录入声纹 | 建立说话人声纹 | 按提示朗读，**录满 3 句以上**；建议为家人、同事各录一次 |
| 验证身份 | 判断「现在是谁在说」 | 说一句话，返回最匹配身份 + 相似度 |
| 对话字幕 | 实时字幕 + 说话人标注 | 核心功能；陌生人可**短按现场起名**并入库 |
| 拍摄解说 | 拍摄画面 → AI 解说 | 调用外部多模态网关（GLM-4V），需配置 API Key |

**上手路径**：先「录入声纹」→ 再用「对话字幕」日常交流；要确认某人用「验证身份」，看不清事物用「拍摄解说」。

## 三、关键技术实现

### 3.1 自研声纹引擎

`utils/voiceprint-engine.js` 实现了完整的特征提取与比对：

```js
// 特征：能量 / 谱质心 / 过零率 / 谱通量 / MFCC 近似
export function extractFeatures(samples, sampleRate = 16000) { /* ... */ }

// 模板：多样本求均值与标准差
export function createTemplate(featureList) { /* ... */ }

// 相似度：MFCC 余弦相似度 50% + 能量 15% + ZCR 10% + 谱质心 15% + 谱通量 10%
export function calculateSimilarity(features, template) { /* ... */ }

export function identifySpeaker(features, templates, threshold = 0.65) { /* ... */ }
```

要点：
- 特征用**均值 + 标准差**建模板，比对时标量特征走高斯相似度，MFCC 走余弦相似度。
- `identifySpeaker` 里我已加保护：**跳过 `template` 为空的用户**，否则空模板会让比对直接抛异常崩页。
- 所有数据存设备本地 storage（`voiceprint_db`），**不上传服务器**。

### 3.2 语音转文字：直接复用 Rokid 能力

AIUI 提供了 Rokid 特有的语音识别器（兼容微信写法），比自己接云端 ASR 简单得多：

```js
const recognizer = wx.getSpeechRecognizer();
recognizer.onRecognize((res) => { /* res.result 中间结果 */ });
recognizer.onStop((res) => { /* res.result 最终结果 */ });
recognizer.start({ lang: 'zh_CN' });
```

我在 `utils/asr.js` 里做了适配：真机走真实识别，仿真环境没有该能力时自动回退演示文本，保证页面始终可跑。

### 3.3 语音播报：TTS

同样用 Rokid 的 `wx.getSpeechSynthesizer()`，封装在 `utils/tts.js`：

```js
export function speak(text) {
  // 关键状态（开始/暂停聆听、完成起名）与报错/卡死都用它播报
}
```

**重点**：不只是播报正常流程，**报错和卡死也播报**（启动录音失败、录音无响应、本句识别出错等），让用户不用一直盯着屏幕。

### 3.4 无障碍设计

- 大字体、高对比（黑底 `#000` + 绿字 `#40FF5E`）；
- 振动 + 语音双反馈；
- 说话人用绿色（已录入）/ 琥珀色（陌生人）区分。

## 四、踩坑记录（最有价值的部分）

### 坑 1：`.ink` 模板指令前缀是 `ink:` 不是 `wx:`

依据官方 aiui-dev skill 与 `samples/capabilities`，标准写法是 `ink:if` / `ink:elif` / `ink:for` / `ink:key`。我早期统一改成了 `wx:`，属于误判，后来全量改回（42 处、5 个页面）。

### 坑 2：`.aix` 是 zip 产物，改完代码必须重打包

`.aix` 本质是 zip：根级 `app.json / app.js / package.json / AGENTS.md / README.md` + `pages/` + `utils/`。**每次改页面/utils 后必须重新打包**，否则导入运行会缺页面、缺 utils。

```bash
zip -r aiui-voiceprint.aix app.json app.js package.json AGENTS.md README.md pages utils -x '*.DS_Store' '*.aix'
```

### 坑 3：录音卡死、退不出来

现象：点开始录音后状态卡在「开始录音」再也不动。

根因很隐蔽：`startRecording()` 里先调用了 `recorderManager.start()`，**然后**才排「3 秒后自动停止」的定时器。如果 `start()` 抛错（PCM 格式 / 权限等），定时器就永远排不上。

正确写法：**定时器先排，`start()` 用 try/catch 包住**。

```js
// 先排定时，保证一定会收尾
clearTimeout(that._autoStop);
that._autoStop = setTimeout(() => that.stopRecording(), 3000);
try {
  that.recorderManager.start({ duration: 3000, sampleRate: 16000, /* ... */ });
} catch (e) {
  clearTimeout(that._autoStop);
  that.setData({ status: '启动录音失败，请重试', isRecording: false });
}
```

配套还要做三件事：
- `stop()` 也包 `try/catch`，保证后续处理一定执行；
- 停止逻辑加**幂等标志**，避免定时器与手动点击重复处理；
- 加**卡死看门狗**：超过「时长 + 2.5s」仍未结束就语音提示并强制收尾。

### 坑 4：真机镜腿手势 —— 滑动不可靠 + 按键重复上报

用户实测反馈两个问题：
- 眼镜上**滑动经常不触发**；
- 一次物理按压可能被上报成**多次 keyup**，导致单击被误判成双击，进而误触发退出。

解法（`utils/gesture.js`）：

```js
export const TAP_DEBOUNCE_MS = 150;  // 去抖：忽略设备重复上报
export const DOUBLE_TAP_MS = 300;

export function classifyTap(ctx) {
  const now = Date.now();
  if (ctx._lastTapRaw && now - ctx._lastTapRaw < TAP_DEBOUNCE_MS) return 'ignore';
  ctx._lastTapRaw = now;
  const last = ctx._lastTapTime || 0;
  if (last && now - last < DOUBLE_TAP_MS) { ctx._lastTapTime = 0; return 'double'; }
  ctx._lastTapTime = now;
  return 'single';
}
```

同时把关键操作改为**短按 / 双击**驱动，**不依赖滑动**；引导材料也改成以文字和预览图为主。

### 坑 5：Rokid 审核被驳回

驳回意见：① 修改功能介绍、增强用户引导；② 在 AIUI Studio 中增加预览图（用于增加指引）。

整改：
- 主页新增「首次使用引导」卡片（无声纹记录时显示三步引导 + 手势说明）；
- `README.md` / `AGENTS.md` 功能介绍改为按使用顺序的引导式说明；
- 做了 3 张预览图（功能总览 / 手势指引 / 字幕场景）。

**注意：预览图只能人工在 AIUI Studio 后台上传，代码里无法代传。**

## 五、总结

- 声纹 + ASR 的组合，在「眼镜」这种第一人称、双手占用的形态上非常自然，是听障辅助的一个有效方向。
- Rokid AIUI 把 ASR（`getSpeechRecognizer`）、TTS（`getSpeechSynthesizer`）都做成可直接调用的 `wx` 能力，省掉了自己接云端协议（protobuf / 鉴权）的大量工作。
- 真机与仿真差异很大，**手势、录音这类能力一定要在真机上早验**，别等到最后。

[待补充：运行截图、代码仓库链接]

---

**声明**：本文为原创实践记录，代码为个人项目实现。
