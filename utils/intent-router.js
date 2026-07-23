/**
 * 语音直呼 · 意图路由器（原始 query 文本 → {mode, page, params, confidence}）
 *
 * 背景（详见 docs/架构-语音直呼集成.md §2、§3）：
 *   - Rokid 不开放自定义热词，唤醒词固定为「Hi Rokid」；用户在同一句/下一句里说出
 *     含「听障助手」及具体诉求的话，由 AIUI OS 依据 AGENTS.md 做语义匹配唤起本 Agent；
 *   - OS 能否把「模式」结构化传参进来是未决项（见文档 §8），因此不依赖 OS 精确传参，
 *     应用内必须能从原始 query 文本自行解析出目标模式。
 *
 * 两级路由：
 *   1) 一级：关键词/正则路由表，命中即返回，0 成本、离线可用（本模块主路径）；
 *   2) 二级：端上 LLM 兜底（Rokid 官方 LanguageModel.create() → s.prompt()，按需创建、非全局单例），
 *      只在一级置信度低（说法太怪的长尾）时才调用；能力不可用/创建或推理失败/超时一律静默落回一级结果。
 *
 * 路由表与 AGENTS.md 的技能触发说法清单必须同步维护，否则会出现
 * 「OS 路由进来了、应用内认不出」的割裂。
 */

// 模式 → 目标页面路径
export const MODE_PAGE = {
  caption: '/pages/conversation/conversation',
  shape: '/pages/media/media',
  genimg: '/pages/genimg/genimg',
  home: '/pages/index/index'
};

// 一级：关键词/正则路由表。顺序即优先级，更具体的规则排在前面，避免被宽泛规则截胡。
const RULES = [
  // 技能3：拍照生成相似图并发到手机——「生成/画 + 相似/类似/模型/一张图」或「发到/发给 + 手机/电话」
  { mode: 'genimg', re: /(生成|画).{0,8}(相似|类似|模型|一张图)|发(到|给).{0,4}(手机|电话)/ },
  // 技能2：拍照识别图形——放宽到最常见口语：裸「拍照/拍张照」、拍照分析/识别/描述、
  // 「分析/识别/描述/讲讲」、「这/那是什么」、「看看这…」。
  // 注意用「看看这」而非裸「看看」，避免误吞技能1「帮我看看别人在说什么」（那句无「这」，落 caption）。
  { mode: 'shape', re: /拍(照|一?张|个照片?)|识别|分析|描述|讲讲|讲解|图形|形状|图案|认一?下|(这|那)个?是?(什么|啥)|看看这/ },
  // 技能1：实时对话字幕——字幕/转写/说什么/对话/听不清/实时
  { mode: 'caption', re: /(字幕|转写|说什么|对话|听不清|实时)/ },
  // 只说了「打开/启动/进入 听障助手」，没有附带具体诉求——落主页
  { mode: 'home', re: /(打开|启动|进入)?听障助手$/ }
];

/**
 * 一级路由：原始文本 → {mode, page, params, confidence}
 * @param {string} raw 原始 query 文本（可能来自 asr/query/text/utterance 等字段）
 * @returns {{mode:string, page:string, params:object, confidence:number}}
 *   confidence: 1 = 空文本兜底主页；0.9 = 正则命中；0.3 = 正则未命中的保底主页
 */
export function routeIntent(raw) {
  const text = (raw || '').trim();
  if (!text) {
    return { mode: 'home', page: MODE_PAGE.home, params: {}, confidence: 1 };
  }

  for (let i = 0; i < RULES.length; i++) {
    if (RULES[i].re.test(text)) {
      const mode = RULES[i].mode;
      return { mode: mode, page: MODE_PAGE[mode], params: { q: text }, confidence: 0.9 };
    }
  }
  // 一级规则全部未命中：保底回主页，置信度低，供二级兜底判断是否值得再问一次 LLM
  return { mode: 'home', page: MODE_PAGE.home, params: { q: text }, confidence: 0.3 };
}

/**
 * 二级兜底：一级置信度不足时，尝试用 Rokid 端上 LLM（LanguageModel.create() → prompt）分类。
 * 能力不可用 / 创建或推理失败 / 超时一律静默走一级结果（此时一级结果必为 home，不会抛错到调用方）。
 * @param {string} raw 原始 query 文本
 * @param {(route: {mode:string, page:string, params:object, confidence:number}) => void} cb
 */
export function routeIntentSmart(raw, cb) {
  const quick = routeIntent(raw);

  // 能力探测：Rokid 端上 LLM 是 LanguageModel.create() 工厂（官方明确「按需创建、非全局单例」，
  // 无全局单例入口）。typeof 检查放最前短路，避免引用未声明标识符触发 ReferenceError。
  if (quick.confidence >= 0.9 ||
      typeof LanguageModel === 'undefined' || !LanguageModel ||
      typeof LanguageModel.create !== 'function') {
    cb(quick);
    return;
  }

  // 防重复回调 + 超时兜底：LLM 创建/推理挂起时不能卡住启动分发，3s 未回落一级结果。
  let done = false;
  const finish = (r) => { if (!done) { done = true; cb(r); } };
  const timer = setTimeout(() => finish(quick), 3000);

  const prompt = '将指令分类为其中一个词并只输出该词：caption/shape/genimg/home。指令：' + raw;
  let sess = null;
  try {
    LanguageModel.create({})
      .then((s) => { sess = s; return s.prompt(prompt); })
      .then((out) => {
        clearTimeout(timer);
        const m = String(out || '').trim().toLowerCase();
        if (MODE_PAGE[m]) finish({ mode: m, page: MODE_PAGE[m], params: { q: raw }, confidence: 0.7 });
        else finish(quick); // 输出不在词表内，落回一级结果（home）
      })
      .catch(() => { clearTimeout(timer); finish(quick); }) // 创建/推理失败，静默落回一级
      .then(() => { // 无论成败，会话有 destroy 能力就释放（按需创建、不留单例）
        try { if (sess && typeof sess.destroy === 'function') sess.destroy(); } catch (e) {}
      });
  } catch (e) {
    // LanguageModel.create 同步抛错（而非返回 rejected Promise）也要兜住，绝不污染启动分发栈
    clearTimeout(timer);
    finish(quick);
  }
}
