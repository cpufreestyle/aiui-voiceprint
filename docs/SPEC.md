# 项目 Spec — 听障助手 (aiui-voiceprint)

> 单一事实来源：产品定位 / 功能边界 / 页面清单 / 数据契约 / 交互规范 / 审核基线。
> 任何 pages/ 或 utils/ 改动后，先更新本文件，再提交代码。配套自检：node scripts/verify.js

## 1. 产品定位

面向听障人群的 Rokid AIUI 智能体：在眼镜屏幕上实时显示「是谁在说话 · 说了什么」。
说话人识别基于声纹（生物特征模板存设备本地），文字转写由 Rokid ASR 提供。

## 2. 功能清单与页面映射

| 功能 | 页面 | 状态 | 要点 |
| --- | --- | --- | --- |
| 主页（声纹库管理） | pages/index | 已实现 | 用户列表 / 改名 / 清空 / 导入导出（剪贴板 JSON，单次 ≤ 200 条） |
| 录入声纹 | pages/enroll | 已实现 | 向导式，3 句样本；核心链路约束见 §7 |
| 验证身份 | pages/verify | 已实现 | 约 3 秒录音，输出匹配人名 |
| 对话字幕（核心） | pages/conversation | 已实现 | 实时字幕 + 说话人标注；陌生人可现场起名；历史回看 50 条 |
| 拍摄解说 | pages/media | 已实现 | 拍照 / 录像 → 视觉解说 → TTS 播报；需 vision API Key，缺省演示模式 |

已丢弃的实验功能（仅存在于 origin/feat/glasses-media-caption 远端分支，未并入 main，
作为历史参照保留在该分支，不在本仓库维护范围）：生图页 genimg、语音直呼 phone-bridge、
relay 中继服务 server/relay。

## 3. 非目标（本期不做）

- 说话人分离 (diarization)：按「一段一句」串行；重叠语音不拆分。
- 离线 ASR：依赖 Rokid 云 / 设备 ASR。
- 字幕云端持久化：仅设备本地 storage。
- 跨语言翻译。

## 4. 数据契约（本地 storage，不上传服务器）

| 键 | 内容 | 管理入口 |
| --- | --- | --- |
| voiceprint_db | users[]: {id, name, enrolledAt, template} | 主页改名 / 删除 / 导入导出 |
| conversation_history | 最近 50 条 {speaker, text, isKnown, ts} | 对话页回看 / 清空 |
| vision_config | {baseUrl, apiKey, model} | 拍摄解说页配置 / 清除 |

约束：

- 导入去重按 id 合并，同 id 覆盖为新数据；单次导入上限 200 条。
- template 为生物特征；导出 JSON 仅经剪贴板中转，页面必须提示保密。
- 无网络 / 无剪贴板能力时必须给出明确提示，不得中断流程。

## 5. 交互契约（全应用统一）

物理交互：滑动 = 选择功能 / 短按（镜腿·点击）= 进入·执行 / 双击（镜腿，长按 ≥400ms）= 退出。

Web 预览与官方审核（鼠标 / 触屏）：点按 = 短按、拖拽 = 滑动、长按 ≥400ms = 双击。

技术判定（utils/tap-classify.js）：

- 位移 < 24px → tap（短按）；≥ 24px → swipe（滑动）。
- swipe 结束后 500ms 内的合成 click 一律拦截，防止「想切换功能却误触进入页面」。

键盘兜底（utils/gesture.js installKeyboardFallback）：onShow 安装 / onHide 卸载，
无实体键盘环境也能路由方向键与空格。

页面接入统一走 utils/page-shell.js：gestureKeyDown / gestureKeyUp /
gestureVoiceWakeup / shellInstallKeyboard / shellRemoveKeyboard。

## 6. 各页面手势速查

| 页面 | 短按 | 双击 / 退出 | 滑动 |
| --- | --- | --- | --- |
| index | 进入高亮功能 | 退出应用 | 上下 / 左右切换高亮 |
| enroll | 开始向导 → 确认启用 → 推进流程 | 向导中仅暂停回起点（防误触闪退）；启用询问选「不启用」；否则退出 | 向导中不跳页；外层左跳验证 / 右取消 |
| verify | 开始验证 / 重试 | 返回主页 | 左跳注册，右返主页 |
| conversation | 给最近陌生人起名 | 停止聆听并退出 | 左清空字幕，右开始 / 暂停聆听 |
| media | 开始拍摄 → 拍照 / 录像 | 解说足 3 项则解说，否则退出 | 拍摄中切拍照 ↔ 录像 |

## 7. 关键技术约束（录音链路，曾两次被审核驳回）

1. `wx.media.getRecorderManager().start()` 只接受 4 个参数
   （sampleRate / numberOfChannels / format / frameSize）。
   多传 duration / encodeBitRate 会抛错且不易捕获 → 录音从未开始 → 录入功能不可用。
2. `onFrameRecorded` 回调里的 frameBuffer 一出回调即失效，必须 .slice(0) 复制。
3. `onStop` 才是可靠完成信号；onError / onInterruptionBegin|End 都要有兜底提示。
4. 按键去抖：TAP_DEBOUNCE_MS=150，DOUBLE_TAP_MS=300（utils/gesture.js / tap-classify.js）。
5. 页面模板指令统一 wx: 前缀（不用 ink:）。
6. 主题色统一走主题 token，不在页面里散落硬编码十六进制。

## 8. 验收基线（提交审核前必须全绿）

运行 `node scripts/verify.js`，并人工确认：

- [ ] 录入功能可用：enroll 页 3 句样本能完成录音并保存（见 §7 约束 1–3）。
- [ ] 滑动与点击严格区分：预览里拖拽不触发进入页面。
- [ ] 5 个页面均能从主页到达，且能返回 / 退出。
- [ ] 字幕历史回看、声纹库导入导出路径可达。
- [ ] 交互文案与 README「各页面手势的具体含义」表格一致。
- [ ] app.json 的 pages 声明与实际目录一一对应。

## 9. 审核记录

| 轮次 | 结果 | 要点 |
| --- | --- | --- |
| 2026-09-03 | 驳回已修 | 功能介绍 / 用户引导 / Studio 预览图不规范 |
| 2026-09-26 | 驳回已修 | ① 录入功能不可用（recorder 4 参签名）② 滑动点击未区分（tap-classify） |
| 2026-10-03 | 已重新提审 v1.1.0 | 产物 aiui-voiceprint.aix；预计 5 个工作日出结果；结果出来后更新本表 |

## 10. 关联文档

- README.md — 用户向导 / 手势速查 / 交互导航图 / 数据存储
- docs/PRD-对话字幕.md — 对话字幕需求（P0/P1/P2 + 成功指标）
- docs/开发记录-审核整改-手势与录音.md — 第 3 轮驳回修复过程与官方文档依据
- AGENTS.md — 仓库约定与 MemOS 工作流
