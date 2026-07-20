"""
听障助手 · 云端 relay 服务
==========================

职责：眼镜端生成"相似图"后，把图片 URL 短时中转给手机 H5 结果页。
relay 只做**匿名、短时、无身份**的中转，不存储任何用户身份信息。

对齐规格文档：docs/架构-语音直呼集成.md §5.3（接口契约，逐字对齐）。

四个业务端点：
  POST /push        眼镜端推送结果 -> 生成取件码对应的取件链接
  GET  /pull?code=  手机端/眼镜端查询取件码对应的图片地址
  GET  /r/{code}    手机端扫码/输码直达的 H5 结果页（服务端渲染）
  GET  /qr?code=    生成指向 /r/{code} 的二维码 PNG，供眼镜端渲染

附加：
  GET  /health      健康检查

安全底线：
  - 取件码固定 4 位数字，正则强校验，防止任意字符串探测。
  - TTL 默认 30 分钟（1800 秒），到期即焚。
  - 单取件码限拉 MAX_PULL_COUNT 次（默认 20 次），超过视为失效，防遍历爆破。
  - relay 内存字典存储，不落盘、不记录用户身份，进程重启即清空。
"""

import os
import re
import time
from io import BytesIO
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from pydantic import BaseModel, Field

try:
    import qrcode
except ImportError:  # pragma: no cover - 仅在依赖未安装时触发，便于给出清晰报错
    qrcode = None


# ---------------------------------------------------------------------------
# 常量配置（均可用环境变量覆盖）
# ---------------------------------------------------------------------------

# 服务监听端口：默认 8262（避开项目端口分配表已占端口），可用 RELAY_PORT 覆盖
DEFAULT_PORT = int(os.environ.get("RELAY_PORT", "8262"))

# 默认 TTL：30 分钟
DEFAULT_TTL_SEC = int(os.environ.get("RELAY_DEFAULT_TTL_SEC", "1800"))

# 单取件码最大可拉取次数，超过视为失效（防遍历爆破）
MAX_PULL_COUNT = int(os.environ.get("RELAY_MAX_PULL_COUNT", "20"))

# 对外公开的 base URL（部署到 nieao.site 等服务器时通过 env 显式指定，
# 避免 nginx 反代场景下从请求头猜测出内网地址）
RELAY_PUBLIC_BASE = os.environ.get("RELAY_PUBLIC_BASE", "").rstrip("/")

# 取件码格式：严格 4 位数字
CODE_RE = re.compile(r"^\d{4}$")


# ---------------------------------------------------------------------------
# 内存存储（无需 Redis）：code -> {imageUrl, expireAt, pullCount}
# 后台惰性清理：每次访问时检查过期即删除；/push 时顺带做一次全量扫除防止堆积
# ---------------------------------------------------------------------------

STORE: dict[str, dict] = {}


def _now() -> float:
    return time.time()


def _sweep_expired() -> None:
    """全量清理已过期的取件码，避免长期运行内存堆积（惰性触发，不用后台线程）。"""
    now = _now()
    expired_codes = [c for c, e in STORE.items() if e["expireAt"] <= now]
    for c in expired_codes:
        STORE.pop(c, None)


def _get_valid_entry(code: str) -> Optional[dict]:
    """取出未过期的条目；已过期则惰性删除后返回 None。"""
    entry = STORE.get(code)
    if entry is None:
        return None
    if entry["expireAt"] <= _now():
        STORE.pop(code, None)
        return None
    return entry


def _consume_entry(code: str) -> Optional[dict]:
    """取件一次：校验存在/未过期/未超拉取上限，成功则 pullCount+1 并返回条目。"""
    entry = _get_valid_entry(code)
    if entry is None:
        return None
    if entry["pullCount"] >= MAX_PULL_COUNT:
        # 拉取次数耗尽，视为失效，直接销毁防止继续被探测
        STORE.pop(code, None)
        return None
    entry["pullCount"] += 1
    return entry


def _resolve_base_url(request: Request) -> str:
    """确定对外 base URL：优先 env RELAY_PUBLIC_BASE，否则从请求 Host 推断。"""
    if RELAY_PUBLIC_BASE:
        return RELAY_PUBLIC_BASE
    # 反代场景优先信任 X-Forwarded-Proto（nginx 常见配置）
    scheme = request.headers.get("x-forwarded-proto") or request.url.scheme
    host = request.headers.get("host") or request.url.netloc
    return f"{scheme}://{host}"


# ---------------------------------------------------------------------------
# 请求/响应模型
# ---------------------------------------------------------------------------

class PushBody(BaseModel):
    code: str = Field(..., description="4 位数字取件码")
    imageUrl: str = Field(..., description="生成好的相似图 URL")
    ttlSec: Optional[int] = Field(None, description="有效期（秒），默认 1800")


# ---------------------------------------------------------------------------
# FastAPI 应用
# ---------------------------------------------------------------------------

app = FastAPI(title="听障助手 relay 服务", description="拍照生成相似图 -> 手机取件 的匿名短时中转服务")


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/push")
def push(body: PushBody, request: Request):
    code = (body.code or "").strip()
    if not CODE_RE.match(code):
        raise HTTPException(status_code=400, detail={"ok": False, "msg": "取件码必须是 4 位数字"})

    image_url = (body.imageUrl or "").strip()
    if not image_url:
        raise HTTPException(status_code=400, detail={"ok": False, "msg": "imageUrl 不能为空"})

    ttl_sec = body.ttlSec if (body.ttlSec and body.ttlSec > 0) else DEFAULT_TTL_SEC

    # 顺带做一次全量惰性清理，避免长期运行的内存堆积
    _sweep_expired()

    STORE[code] = {
        "imageUrl": image_url,
        "expireAt": _now() + ttl_sec,
        "pullCount": 0,
    }

    base = _resolve_base_url(request)
    pull_url = f"{base}/r/{code}"
    return {"ok": True, "pullUrl": pull_url}


@app.get("/pull")
def pull(code: str = ""):
    code = (code or "").strip()
    if not CODE_RE.match(code):
        return JSONResponse({"ok": False, "msg": "取件码格式不正确"})

    entry = _consume_entry(code)
    if entry is None:
        return JSONResponse({"ok": False, "msg": "取件码不存在或已过期"})

    return {"ok": True, "imageUrl": entry["imageUrl"]}


def _render_result_page(code: str, image_url: Optional[str], error_msg: Optional[str]) -> str:
    """服务端渲染手机结果页：完整独立文档，charset 为 head 第一标签，UTF-8 无 BOM。"""
    if error_msg:
        body_html = f"""
    <div class="card error-card">
      <div class="icon">⚠️</div>
      <h1>无法查看结果</h1>
      <p class="msg">{error_msg}</p>
      <p class="code-hint">取件码：{code}</p>
    </div>
"""
        title = "取件失败 - 听障助手"
    else:
        body_html = f"""
    <div class="card">
      <h1>拍照生成结果</h1>
      <p class="code-hint">取件码：<span class="code">{code}</span></p>
      <div class="img-wrap">
        <img src="{image_url}" alt="生成的相似图" />
      </div>
      <p class="tip">长按图片保存到手机相册</p>
    </div>
"""
        title = "取件成功 - 听障助手"

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>{title}</title>
<style>
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding: 24px 16px 48px;
    background: #f5f6f8;
    color: #1f2329;
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", sans-serif;
    display: flex;
    justify-content: center;
  }}
  .card {{
    width: 100%;
    max-width: 420px;
    background: #ffffff;
    border-radius: 12px;
    box-shadow: 0 2px 12px rgba(0,0,0,0.08);
    padding: 24px 20px;
    text-align: center;
  }}
  h1 {{
    font-size: 20px;
    margin: 0 0 12px;
  }}
  .code-hint {{
    color: #6b7280;
    font-size: 14px;
    margin: 4px 0 16px;
  }}
  .code {{
    font-weight: 600;
    letter-spacing: 2px;
    color: #1f2329;
  }}
  .img-wrap {{
    margin: 12px 0;
    border-radius: 8px;
    overflow: hidden;
    background: #f0f1f3;
  }}
  img {{
    max-width: 100%;
    display: block;
    margin: 0 auto;
  }}
  .tip {{
    color: #9096a2;
    font-size: 13px;
    margin-top: 8px;
  }}
  .error-card .icon {{
    font-size: 40px;
    margin-bottom: 8px;
  }}
  .error-card .msg {{
    font-size: 15px;
    color: #444;
    margin: 8px 0 4px;
  }}
</style>
</head>
<body>
{body_html}
</body>
</html>"""


@app.get("/r/{code}", response_class=HTMLResponse)
def result_page(code: str):
    code = (code or "").strip()
    if not CODE_RE.match(code):
        html = _render_result_page(code, None, "取件码格式不正确")
        return HTMLResponse(content=html, status_code=400)

    entry = _consume_entry(code)
    if entry is None:
        html = _render_result_page(code, None, "取件码不存在或已过期")
        return HTMLResponse(content=html, status_code=404)

    html = _render_result_page(code, entry["imageUrl"], None)
    return HTMLResponse(content=html, status_code=200)


@app.get("/qr")
def qr_code(code: str = "", request: Request = None):
    code = (code or "").strip()
    if not CODE_RE.match(code):
        raise HTTPException(status_code=400, detail={"ok": False, "msg": "取件码必须是 4 位数字"})

    if qrcode is None:
        raise HTTPException(
            status_code=503,
            detail={"ok": False, "msg": "服务端未安装二维码依赖 qrcode，请先 pip install -r requirements.txt"},
        )

    base = _resolve_base_url(request)
    pull_url = f"{base}/r/{code}"

    img = qrcode.make(pull_url)
    buf = BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return Response(content=buf.getvalue(), media_type="image/png")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=DEFAULT_PORT)
