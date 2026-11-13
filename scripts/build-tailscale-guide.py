#!/usr/bin/env python3
"""把 docs/手机端Tailscale设置.md 排成一份可打印的 A4 说明（HTML + PDF）。

版式复用 build-manual.py 的 Markdown 解析器和 CSS，避免两套样式各改各的。
只有封面做了覆盖：现场是要打印或微信转发的，单独占一整页太浪费。

用法：python3 scripts/build-tailscale-guide.py
产物：dist/手机端Tailscale设置.html / dist/手机端Tailscale设置.pdf
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

# 文件名带连字符（build-manual.py），不能 import build_manual，按路径加载。
# 复用它的 parse / CSS / to_pdf，避免两套排版样式各改各的。
_spec = importlib.util.spec_from_file_location(
    "build_manual", Path(__file__).with_name("build-manual.py")
)
bm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bm)

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "手机端Tailscale设置.md"
OUT_HTML = ROOT / "dist" / "手机端Tailscale设置.html"
OUT_PDF = ROOT / "dist" / "手机端Tailscale设置.pdf"

# 这份指南不带软件版本号：Tailscale 的界面会变，说明按核对日期为准。
COVER = """
<section class="cover">
  <div class="cover-top">
    <div class="brand">REMOTE<span>DESK</span></div>
    <div class="version">跨网连接配套 · 2026-11-13</div>
  </div>
  <h1>手机端 Tailscale 设置说明</h1>
  <p class="lede">人在外面用手机连电脑之前，先把这一页做完。<br>
  安卓手机 · 装包 → 登录 → 打开开关 → 用配对码连</p>
  <dl class="cover-meta">
    <div><dt>适用</dt><dd>Android 8.0+，手机用 4G/5G 或不在同一个 Wi-Fi 时</dd></div>
    <div><dt>配套</dt><dd>《RemoteDesk 使用说明书》4.4 状态条 / 4.8 跨网络 / 6.2 手机当主控</dd></div>
  </dl>
</section>
"""

# build-manual.py 的封面是整页（min-height: 232mm + page-break-after: always），
# 那是给 19 页手册用的。这里压成顶部横幅，整份说明两页纸能印完。
COVER_CSS = """
.cover { min-height: 0; page-break-after: auto; margin-bottom: 22px;
         padding: 26px 30px 24px; }
.cover h1 { font-size: 24pt; margin: 18px 0 0; letter-spacing: 1pt; }
.cover .lede { font-size: 10pt; margin: 10px 0 0; line-height: 1.7; }
.cover-meta { margin: 20px 0 0; padding-top: 12px; }
"""


def build_html(body: list[str]) -> str:
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>手机端 Tailscale 设置说明</title>
<style>{bm.CSS}
{COVER_CSS}</style>
</head>
<body>
<div class="page">
{COVER}
{chr(10).join(body)}
</div>
</body>
</html>
"""


def main() -> int:
    md = SRC.read_text(encoding="utf-8")
    # parse 会跳过一级标题（封面已有），并把 --- 变成一条分隔线；这里都不要。
    _, body = bm.parse(md)
    body = [
        frag for frag in body
        if frag != '<div class="rule"></div>'
        and not (frag.startswith("<p>") and "最后核对" in frag)
    ]

    OUT_HTML.parent.mkdir(parents=True, exist_ok=True)
    OUT_HTML.write_text(build_html(body), encoding="utf-8")
    print(f"[+] HTML  {OUT_HTML.relative_to(ROOT)}  ({OUT_HTML.stat().st_size / 1024:.0f} KB)")

    if not bm.to_pdf(OUT_HTML, OUT_PDF):
        print("[!] PDF 生成失败，HTML 仍可在浏览器里 ⌘P 打印", file=sys.stderr)
        return 1
    print(f"[+] PDF   {OUT_PDF.relative_to(ROOT)}  ({OUT_PDF.stat().st_size / 1024:.0f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
