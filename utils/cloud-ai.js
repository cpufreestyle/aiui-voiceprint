/**
 * 云端 AI 统一配置（Agnes AI · 统一多模态网关）
 *
 * 目的（用户指定，测试版）：
 *   所有接云的模型——视觉解说 / 图形识别 / 图像生成——统一走同一个 Agnes AI Key，
 *   Key 内置在本文件，眼镜端一律「开箱即用」，不需要在设备上填任何 API Key。
 *
 * 用法：其它模块（vision.js / imagegen.js）的 DEFAULT_CONFIG 直接读这里的常量。
 *   - AGNES_API_KEY 非空时，isVisionConfigured()/isImagegenConfigured() 自动为真 → live 模式；
 *   - 用户仍可在设置面板临时覆盖（storage 优先级高于本内置默认），但测试版不需要。
 *
 * ⚠️ 安全提示：这是「内置明文 Key」的测试版做法，Key 会随源码分发。
 *   正式版应改回「空默认 + 用户填入」或走服务端代理（server/relay 加鉴权转发），
 *   不要把带真实 Key 的本文件公开提交到公共仓库。
 */

// ★★★ 内置 Agnes AI Key（测试版；与主持人V2/AIGC-workflow 同一个 Key） ★★★
export const AGNES_API_KEY = 'sk-6hxz2lj1egE5aBh1GvB6k5aKF6ugO9jalhaCeP27NLpZYW0A';

// 视觉理解网关（OpenAI 兼容 /chat/completions）——describeImage/describeShape/视频帧解说走这里。
export const AGNES_BASE_URL = 'https://apihub.agnes-ai.com/v1/chat/completions';

// 图像生成端点（★与视觉不同★）：图像模型不吃 /chat/completions（会 404），走 /images/generations，
// 返回形态 { data:[{ url }] }。已实测 agnes-image-2.1-flash 出图成功（上游偶发 503 需重试）。
// 注意：这是「文生图」端点；「参照拍的照片生成相似图」(图生图) 标准要 /images/edits + multipart 上传文件，
//       而端上 wx.request 无 uploadFile 能力 —— 图生图链路尚未打通（见 docs 架构 §5.1 未决项）。
export const AGNES_IMAGE_URL = 'https://apihub.agnes-ai.com/v1/images/generations';

// 默认模型：视觉理解 / 图像生成分别用不同模型名，但共用同一个 Key。
export const AGNES_VISION_MODEL = 'agnes-2.0-flash';       // 多模态理解（图片/关键帧解说、图形识别）——实测可用
export const AGNES_IMAGE_MODEL = 'agnes-image-2.1-flash';  // 图像生成；实测存在，另有 agnes-image-2.0-flash

/** 是否已内置可用的云端 Key（供 UI 提示「测试版已内置」用）。 */
export function hasBuiltinKey() {
  return !!AGNES_API_KEY;
}
