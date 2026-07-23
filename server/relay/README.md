# 听障助手 · 云端 relay 服务

眼镜端拍照生成"相似图"后，通过本服务把结果**短时、匿名**中转给用户手机，
手机扫码或输入 4 位取件码即可零安装查看结果。对应规格文档
`docs/架构-语音直呼集成.md` §5.3（接口契约）、§5（时序图）、§7/§8（合规与降级）。

## 启动方式

```bash
cd server/relay
pip install -r requirements.txt
python -m uvicorn app:app --host 0.0.0.0 --port 8262
```

Windows 下也可直接双击 `start.bat`（自带端口清理 + 依赖检查 + 防闪退守护壳）。

默认端口 **8262**（已避开项目端口分配表已占端口，见 `~/.claude/rules/ports.md`），
可用环境变量 `RELAY_PORT` 覆盖。

## 四个端点

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/push` | 眼镜端推送结果：body `{code, imageUrl, ttlSec?}` → `{ok:true, pullUrl}` |
| GET | `/pull?code=1234` | 查询取件码对应图片：`{ok:true, imageUrl}` 或 `{ok:false, msg:"取件码不存在或已过期"}` |
| GET | `/r/{code}` | 手机侧 H5 结果页（服务端渲染），扫码/输码直达，零安装 |
| GET | `/qr?code=1234` | 生成指向 `/r/{code}` 的二维码 PNG，供眼镜端渲染 |
| GET | `/health` | 健康检查 `{ok:true}` |

### 请求/响应示例

```bash
# 眼镜端推送
curl -X POST http://localhost:8262/push \
  -H "Content-Type: application/json" \
  -d '{"code":"1234","imageUrl":"https://example.com/result.png"}'
# -> {"ok":true,"pullUrl":"http://localhost:8262/r/1234"}

# 手机端查询
curl http://localhost:8262/pull?code=1234
# -> {"ok":true,"imageUrl":"https://example.com/result.png"}

# 手机浏览器直接打开 http://localhost:8262/r/1234 即看到结果页
```

## 部署到 nieao.site（或任意服务器）

1. 服务器上装依赖并常驻运行（推荐 systemd / pm2 / supervisor 管理
   `uvicorn app:app --host 127.0.0.1 --port 8262`，不直接对公网开放该端口）。
2. nginx 加一段反代（示例，按实际域名/路径调整）：

   ```nginx
   location /relay/ {
       proxy_pass http://127.0.0.1:8262/;
       proxy_set_header Host $host;
       proxy_set_header X-Forwarded-Proto $scheme;
       proxy_set_header X-Real-IP $remote_addr;
   }
   ```

3. **务必设置环境变量 `RELAY_PUBLIC_BASE`**，否则 `/push` 返回的 `pullUrl`
   会退化为从请求 Host/反代头猜测，nginx 反代场景下容易猜错（比如少了
   `/relay` 前缀）。显式指定最可靠：

   ```bash
   export RELAY_PUBLIC_BASE=https://nieao.site/relay
   ```

4. 确认 HTTPS 证书覆盖该域名（手机扫码走公网，必须 HTTPS，微信/系统相机
   扫码器对 http 链接可能拦截或降级体验）。

## 与眼镜端 `utils/phone-bridge.js` 的对应关系

规格文档 §5.2 定义的眼镜端 relay 客户端 `utils/phone-bridge.js` 已实现（`pushResult`
上报取件码、`qrImageUrl` 取二维码地址、`getRelayBase`/`setRelayBase` 读写服务地址），
由 `pages/genimg` 在生成图片后调用。其中 RELAY_BASE 默认值与「设置面板」覆盖方式：

```javascript
var RELAY_BASE = 'https://nieao.site/relay'   // 与本服务部署地址一致，存 storage 可配置
```

眼镜端调用顺序（对应 §5 时序图）：

1. `pushResult(code, imageUrl)` → `POST {RELAY_BASE}/push`，拿到 `pullUrl`。
2. 字幕显示取件码 + 调用 `{RELAY_BASE}/qr?code=xxxx` 渲染二维码（若端上
   `<image>` 支持加载网络图；否则退化为大号数字取件码 + TTS 播报）。
3. 手机端扫码直达 `{RELAY_BASE}/r/xxxx`，或用户手动在浏览器输入该地址查看。

## 安全说明（§7/§8 合规要点）

- **取件码固定 4 位数字**，`POST /push` 与所有取件路径均做正则强校验
  （`^\d{4}$`），拒绝任意字符串，降低暴力枚举空间。
- **TTL 默认 30 分钟**（1800 秒），可在 `/push` 时用 `ttlSec` 覆盖；到期
  条目在下次被访问时惰性删除，`/push` 时额外做一次全量惰性清理防止内存
  堆积（无需 Redis / 定时任务）。
- **单取件码限拉 20 次**（`RELAY_MAX_PULL_COUNT` 环境变量可调），`/pull`
  与 `/r/{code}` 共享同一次数计数，超限视为失效并立即销毁该条目，防止
  取件码被暴力遍历持续拉取。
- **relay 不存储任何用户身份信息**：内存字典只存 `code -> {imageUrl,
  expireAt, pullCount}`，进程重启即清空，不落盘、不记日志用户内容。
- 图片本身托管在图像生成服务（如 Agnes）返回的 URL 上，relay 只中转
  URL 字符串，不落地存储图片文件（除非未来按 §5.1 备注把生成服务的
  base64 落地成 URL，那是另一个功能开关，本版本未实现）。
- 部署时建议：仅监听 `127.0.0.1`，经 nginx 反代对外；反代层可按需加
  限流（如按 IP 限 `/push` 频率）防刷；HTTPS 必开。

## 环境变量一览

| 变量 | 默认值 | 说明 |
|---|---|---|
| `RELAY_PORT` | `8262` | 监听端口（仅 `python app.py` 直启时生效；uvicorn CLI 启动请用 `--port`） |
| `RELAY_DEFAULT_TTL_SEC` | `1800` | 默认 TTL（秒） |
| `RELAY_MAX_PULL_COUNT` | `20` | 单取件码最大可拉取次数 |
| `RELAY_PUBLIC_BASE` | 空（从请求 Host 推断） | 对外公开 base URL，部署到反代后必须显式设置 |
