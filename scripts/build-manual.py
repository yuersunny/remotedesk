#!/usr/bin/env python3
"""把 docs/使用说明书.md 排成一册可打印的 A4 手册（HTML），再用 Chrome 转 PDF。

只支持这份说明书里实际用到的 Markdown 子集：标题、段落、列表、表格、
围栏代码块、引用块（按首词认成 提示/注意/警告 三种提示框）、分隔线、
行内 **粗体** 与 `代码`。

用法：
    python3 scripts/build-manual.py                 # 出 HTML + PDF
    python3 scripts/build-manual.py --html-only     # 只出 HTML
"""

from __future__ import annotations

import html
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "使用说明书.md"
OUT_HTML = ROOT / "dist" / "RemoteDesk-1.0.7-使用说明书.html"
OUT_PDF = ROOT / "dist" / "RemoteDesk-1.0.7-使用说明书.pdf"

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
]


# --------------------------------------------------------------------- inline
def inline(text: str) -> str:
    """行内标记。先转义，再放回我们自己的标签，避免 HTML 被吃掉。"""
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    return out


def slug(text: str) -> str:
    s = re.sub(r"[^\w\u4e00-\u9fa5]+", "-", text).strip("-")
    return s or "sec"


# ---------------------------------------------------------------------- block
def parse(md: str) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """返回 (章节标题列表, HTML 片段列表)。"""
    lines = md.splitlines()
    body: list[str] = []
    toc: list[tuple[str, str]] = []

    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        stripped = line.strip()

        # 空行
        if not stripped:
            i += 1
            continue

        # 分隔线
        if re.fullmatch(r"-{3,}", stripped):
            body.append('<div class="rule"></div>')
            i += 1
            continue

        # 围栏代码
        if stripped.startswith("```"):
            i += 1
            buf: list[str] = []
            while i < n and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            body.append("<pre><code>" + html.escape("\n".join(buf)) + "</code></pre>")
            continue

        # 标题
        m = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if m:
            level = len(m.group(1))
            text = m.group(2).strip()
            if level == 1:
                # 封面已有主标题，正文里不再重复
                i += 1
                continue
            anchor = slug(text)
            if level == 2:
                toc.append((anchor, text))
                body.append(f'<h2 id="{anchor}">{inline(text)}</h2>')
            elif level == 3:
                body.append(f'<h3 id="{anchor}">{inline(text)}</h3>')
            else:
                body.append(f"<h4>{inline(text)}</h4>")
            i += 1
            continue

        # 表格
        if stripped.startswith("|") and i + 1 < n and re.match(
            r"^\|[\s:\-|]+\|$", lines[i + 1].strip()
        ):
            header = [c.strip() for c in stripped.strip("|").split("|")]
            i += 2
            rows: list[list[str]] = []
            while i < n and lines[i].strip().startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            th = "".join(f"<th>{inline(c)}</th>" for c in header)
            trs = []
            for row in rows:
                tds = "".join(f"<td>{inline(c)}</td>" for c in row)
                trs.append(f"<tr>{tds}</tr>")
            body.append(
                '<div class="table-wrap"><table><thead><tr>'
                + th
                + "</tr></thead><tbody>"
                + "".join(trs)
                + "</tbody></table></div>"
            )
            continue

        # 引用块 → 提示框
        if stripped.startswith(">"):
            buf = []
            while i < n and lines[i].strip().startswith(">"):
                buf.append(lines[i].strip()[1:].strip())
                i += 1
            text = " ".join(x for x in buf if x)
            kind, label = "note", "提示"
            for word, cls, lab in (
                ("警告", "danger", "警告"),
                ("注意", "warn", "注意"),
                ("提示", "note", "提示"),
            ):
                if f"**{word}**" in text:
                    kind, label = cls, lab
                    text = text.replace(f"**{word}**", "", 1).lstrip("：: ")
                    break
            body.append(
                f'<div class="callout {kind}"><span class="tag">{label}</span>'
                f'<p>{inline(text)}</p></div>'
            )
            continue

        # 列表
        if re.match(r"^(\-|\d+\.)\s+", stripped):
            ordered = bool(re.match(r"^\d+\.\s+", stripped))
            items: list[dict] = []
            while i < n:
                raw = lines[i]
                s = raw.strip()
                indent = len(raw) - len(raw.lstrip())
                m2 = re.match(r"^(\-|\d+\.)\s+(.*)$", s)
                if m2:
                    # 缩进的列表项是上一项的子项，不能并成同级——否则
                    # "3. 删这两处：- A - B" 会变成 "3. 4. A 5. B"。
                    if indent >= 2 and items:
                        items[-1]["kids"].append(m2.group(2))
                    else:
                        items.append({"text": m2.group(2), "kids": []})
                    i += 1
                    continue
                # 缩进续行属于上一个列表项。
                if items and indent >= 2 and s:
                    items[-1]["text"] += s
                    i += 1
                    continue
                break
            tag = "ol" if ordered else "ul"
            rendered = []
            for it in items:
                kids = "".join(f"<li>{inline(k)}</li>" for k in it["kids"])
                sub = f"<ul class=\"sub\">{kids}</ul>" if kids else ""
                rendered.append(f"<li>{inline(it['text'])}{sub}</li>")
            body.append(f"<{tag}>" + "".join(rendered) + f"</{tag}>")
            continue

        # 段落（连续非空行合并）
        buf = [stripped]
        i += 1
        while i < n:
            s = lines[i].strip()
            if (
                not s
                or s.startswith(("#", ">", "|", "```"))
                or re.match(r"^(\-|\d+\.)\s+", s)
                or re.fullmatch(r"-{3,}", s)
            ):
                break
            buf.append(s)
            i += 1
        body.append(f"<p>{inline(' '.join(buf))}</p>")

    return toc, body


COVER = """
<section class="cover">
  <div class="cover-top">
    <div class="brand">REMOTE<span>DESK</span></div>
    <div class="version">v1.0.7</div>
  </div>

  <h1>使用说明书</h1>
  <p class="lede">从装好到连上，再到出事怎么查。<br>不需要账号，不需要服务器，不需要懂网络。</p>

  <svg class="cover-art" viewBox="0 0 520 150" fill="none" xmlns="http://www.w3.org/2000/svg">
    <g>
      <rect x="16" y="30" width="170" height="106" rx="7" fill="#0A2E4C" stroke="#5E93BF" stroke-width="1.4"/>
      <path d="M16 37a7 7 0 0 1 7-7h156a7 7 0 0 1 7 7v11H16z" fill="#1D527E"/>
      <circle cx="27" cy="39" r="2.6" fill="#8FBBDA"/>
      <circle cx="37" cy="39" r="2.6" fill="#4E7EA6"/>
      <circle cx="47" cy="39" r="2.6" fill="#4E7EA6"/>
      <rect x="30" y="60" width="120" height="5" rx="2.5" fill="#3B6C93"/>
      <rect x="30" y="74" width="142" height="5" rx="2.5" fill="#2C5473"/>
      <rect x="30" y="88" width="96" height="5" rx="2.5" fill="#2C5473"/>
      <rect x="30" y="102" width="60" height="14" rx="3" fill="#2F6389"/>
    </g>
    <g>
      <rect x="334" y="30" width="170" height="106" rx="7" fill="#0A2E4C" stroke="#5E93BF" stroke-width="1.4"/>
      <path d="M334 37a7 7 0 0 1 7-7h156a7 7 0 0 1 7 7v11H334z" fill="#1D527E"/>
      <circle cx="345" cy="39" r="2.6" fill="#8FBBDA"/>
      <circle cx="355" cy="39" r="2.6" fill="#4E7EA6"/>
      <circle cx="365" cy="39" r="2.6" fill="#4E7EA6"/>
      <rect x="348" y="60" width="120" height="5" rx="2.5" fill="#3B6C93"/>
      <rect x="348" y="74" width="142" height="5" rx="2.5" fill="#2C5473"/>
      <rect x="348" y="88" width="96" height="5" rx="2.5" fill="#2C5473"/>
      <rect x="348" y="102" width="60" height="14" rx="3" fill="#2F6389"/>
    </g>
    <line x1="196" y1="83" x2="316" y2="83" stroke="#5E93BF" stroke-width="1.4" stroke-dasharray="5 5"/>
    <circle cx="256" cy="83" r="17" fill="#0E3A5F" stroke="#8FBBDA" stroke-width="1.4"/>
    <path d="M248.5 78.5v-3.2a7.5 7.5 0 0 1 15 0v3.2" stroke="#BFE0F7" stroke-width="1.6"/>
    <rect x="245.5" y="78.5" width="21" height="14.5" rx="2.6" stroke="#BFE0F7" stroke-width="1.6"/>
    <circle cx="256" cy="85" r="1.7" fill="#BFE0F7"/>
    <text x="256" y="22" fill="#9CC4E4" font-size="8.5" text-anchor="middle" font-family="monospace">100.x / 192.168.x</text>
    <text x="256" y="150" fill="#9CC4E4" font-size="8.5" text-anchor="middle" font-family="monospace">DTLS-SRTP</text>
  </svg>

  <dl class="cover-meta">
    <div><dt>适用</dt><dd>macOS 13+ · Windows 10 1809+ · Android 7.0+</dd></div>
    <div><dt>端口</dt><dd>8787 / TCP（握手）· 8789 / UDP（发现）</dd></div>
    <div><dt>日期</dt><dd>2026 年 11 月</dd></div>
  </dl>
</section>
"""

CSS = """
@page { size: A4; margin: 17mm 15mm 16mm; }
* { box-sizing: border-box; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body {
  margin: 0; background: #fff; color: #1C2733;
  font-family: "Helvetica Neue", Helvetica, Arial, "PingFang SC",
    "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  font-size: 10.4pt; line-height: 1.72; letter-spacing: .1pt;
}
.page { max-width: 760px; margin: 0 auto; padding: 28px 30px 60px; }

/* ---------- 封面 ---------- */
.cover {
  background: #0E3A5F; color: #fff; padding: 46px 44px 40px;
  margin-bottom: 34px; border-radius: 3px; position: relative; overflow: hidden;
  page-break-after: always; min-height: 232mm;
  display: flex; flex-direction: column;
}
.cover::before {
  content: ""; position: absolute; inset: 0;
  background-image: linear-gradient(rgba(255,255,255,.045) 1px, transparent 1px),
                    linear-gradient(90deg, rgba(255,255,255,.045) 1px, transparent 1px);
  background-size: 26px 26px; pointer-events: none;
}
.cover-top { display: flex; justify-content: space-between; align-items: baseline;
  border-bottom: 1px solid rgba(255,255,255,.22); padding-bottom: 12px; position: relative; }
.brand { font: 600 12pt/1 "Helvetica Neue", Arial, sans-serif; letter-spacing: 3.4pt; }
.brand span { color: #7FB2DC; }
.version { font: 400 9pt/1 monospace; color: #9CC4E4; letter-spacing: 1pt; }
.cover h1 { font-size: 34pt; line-height: 1.15; margin: 84px 0 0; font-weight: 600; letter-spacing: 2pt; }
.cover .lede { margin: 20px 0 0; color: #C6DCEE; font-size: 11.6pt; line-height: 1.95; }
.cover-art { width: 100%; height: auto; margin: 46px 0 0; }
.cover-meta { margin: auto 0 0; padding-top: 26px; border-top: 1px solid rgba(255,255,255,.18);
  display: grid; gap: 9px; font-size: 9.2pt; position: relative; }
.cover-meta div { display: flex; gap: 14px; }
.cover-meta dt { color: #7FB2DC; min-width: 34px; letter-spacing: 1pt; }
.cover-meta dd { margin: 0; color: #DCE9F4; }

/* ---------- 标题 ---------- */
h2 {
  font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial,
    "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  font-size: 15.4pt; font-weight: 600; color: #0E3A5F; margin: 30px 0 14px;
  padding-bottom: 8px; border-bottom: 2px solid #0E3A5F; letter-spacing: .6pt;
  break-after: avoid; break-inside: avoid;
}
h2 + p, h2 + .table-wrap, h2 + ul, h2 + ol { margin-top: 0; }
h3 {
  font-size: 11.6pt; font-weight: 600; color: #14486F; margin: 22px 0 8px;
  padding-left: 9px; border-left: 3px solid #1B6CA8; letter-spacing: .3pt;
  break-after: avoid;
}
h4 { font-size: 10.6pt; font-weight: 600; color: #14486F; margin: 16px 0 6px; break-after: avoid; }
p { margin: 9px 0; text-align: justify; }
strong { font-weight: 600; color: #0B2B46; }

/* ---------- 导语 ---------- */
.preface { margin: 26px 0 22px; }
.preface p:first-child { font-size: 8.8pt; letter-spacing: 1.4pt; color: #6B8497; margin: 0 0 10px; }
.preface p { font-size: 11pt; line-height: 1.9; color: #2C4256; margin: 0; }
.preface .rule { display: none; }

/* ---------- 目录 ---------- */
.toc { background: #F5F8FB; border: 1px solid #DCE6EF; border-radius: 4px;
  padding: 16px 20px; margin: 20px 0 28px; }
.toc-title { font: 600 9pt/1 "PingFang SC", sans-serif; letter-spacing: 2pt;
  color: #6B8497; margin-bottom: 10px; text-transform: uppercase; }
.toc ol { margin: 0; padding-left: 0; list-style: none;
  display: grid; grid-template-columns: 1fr 1fr; gap: 3px 22px; }
.toc li { font-size: 9.6pt; color: #2C4256; }
.toc a { color: inherit; text-decoration: none; }
.toc a::before { content: "—"; color: #9FB4C6; margin-right: 7px; }

/* ---------- 表格 ---------- */
.table-wrap { margin: 12px 0 16px; border: 1px solid #DCE6EF; border-radius: 4px; overflow: hidden;
  break-inside: avoid; }
table { width: 100%; border-collapse: collapse; font-size: 9.3pt; }
th { background: #0E3A5F; color: #fff; text-align: left; font-weight: 500;
  padding: 7px 10px; letter-spacing: .4pt; font-size: 8.9pt; }
td { padding: 7px 10px; vertical-align: top; border-top: 1px solid #E6EDF3; line-height: 1.6; }
tbody tr:nth-child(even) { background: #F8FAFC; }
tbody tr { break-inside: avoid; }
td code, p code, li code { font-size: 8.8pt; }

/* ---------- 列表 ---------- */
ul, ol { margin: 8px 0 12px; padding-left: 20px; }
li { margin: 4px 0; line-height: 1.68; }
ul li::marker { color: #1B6CA8; }
ol li::marker { color: #1B6CA8; font-weight: 600; }
ul.sub { margin: 3px 0 3px; padding-left: 16px; list-style: none; }
ul.sub li { margin: 2px 0; font-size: 9.9pt; color: #2C4256; }
ul.sub li::before { content: "·"; color: #1B6CA8; font-weight: 600; margin-right: 7px; }

/* ---------- 代码 ---------- */
pre { background: #0F2233; color: #D7E6F2; border-radius: 4px; padding: 13px 15px;
  overflow-x: auto; margin: 12px 0 16px; break-inside: avoid; }
pre code { font: 8.4pt/1.6 "SF Mono", Menlo, Consolas, monospace; white-space: pre; color: inherit; }
p code, td code, li code { background: #EEF3F8; color: #14486F; border-radius: 2px;
  padding: 1px 4px; font-family: "SF Mono", Menlo, Consolas, monospace; }

/* ---------- 提示框 ---------- */
.callout { display: flex; gap: 11px; align-items: flex-start; margin: 13px 0 16px;
  padding: 11px 14px; border-radius: 3px; border-left: 3px solid #1B6CA8;
  background: #F2F7FC; break-inside: avoid; }
.callout p { margin: 0; font-size: 9.6pt; line-height: 1.7; }
.callout .tag { flex: none; font-size: 8.2pt; font-weight: 600; letter-spacing: 1pt;
  padding: 2px 7px; border-radius: 2px; background: #1B6CA8; color: #fff; margin-top: 1px; }
.callout.warn { background: #FDF7EC; border-left-color: #B26A00; }
.callout.warn .tag { background: #B26A00; }
.callout.danger { background: #FCF1F0; border-left-color: #B3261E; }
.callout.danger .tag { background: #B3261E; }

.rule { height: 1px; background: #E3EAF1; margin: 26px 0; }

/* ---------- 速查卡 ---------- */
.cheatsheet { border: 1.4px solid #0E3A5F; border-radius: 4px; background: #FAFCFE;
  padding: 34px 36px 36px; margin: 8px 0 0; }
.cheatsheet h3 { border-left: none; padding-left: 0; margin-top: 0;
  font-size: 15.6pt; letter-spacing: 1.2pt; color: #0E3A5F;
  padding-bottom: 14px; border-bottom: 1px solid #C9D8E6; }
.cheatsheet p { margin: 17px 0; font-size: 11.6pt; line-height: 1.85;
  padding-left: 20px; position: relative; text-align: left; }
.cheatsheet p::before { content: "▸"; position: absolute; left: 0; top: 0; color: #1B6CA8; }
.cheatsheet p:last-child { margin-top: 26px; padding: 16px 18px; font-size: 10pt;
  color: #4A6274; background: #F1F6FA; border-radius: 3px; }
.cheatsheet p:last-child::before { content: ""; }

/* ---------- 打印 ---------- */
@media print {
  .page { padding: 0; max-width: none; }
  .cover { margin: 0; border-radius: 0; min-height: 0; height: 258mm; }
  /* 不强制每章另起一页：章节长短不一，硬分会拖出大片空白。连续排更紧凑。 */
  h2 { margin-top: 26px; }
  .cheatsheet { break-before: page; margin-top: 18mm; }
  a { color: inherit; text-decoration: none; }
}
"""


def build_html(preface, toc, body) -> str:
    toc_html = ""
    if toc:
        items = "".join(f'<li><a href="#{a}">{html.escape(t)}</a></li>' for a, t in toc)
        toc_html = (
            '<div class="toc"><div class="toc-title">目录</div>'
            f"<ol>{items}</ol></div>"
        )
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RemoteDesk 使用说明书 v1.0.7</title>
<style>{CSS}</style>
</head>
<body>
<div class="page">
{COVER}
<div class="preface">
{chr(10).join(preface)}
</div>
{toc_html}
{chr(10).join(body)}
</div>
</body>
</html>
"""


def to_pdf(html_path: Path, pdf_path: Path) -> bool:
    chrome = next((c for c in CHROME_CANDIDATES if Path(c).exists()), None)
    if chrome is None:
        print("[!] 没找到 Chrome/Edge，跳过 PDF", file=sys.stderr)
        return False
    pdf_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        chrome,
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--no-pdf-header-footer",
        "--virtual-time-budget=4000",
        f"--print-to-pdf={pdf_path}",
        html_path.as_uri(),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0 or not pdf_path.exists():
        print(res.stderr[-1200:], file=sys.stderr)
        return False
    return True


def main() -> int:
    md = SRC.read_text(encoding="utf-8")
    # 第一个二级标题之前是导语（版本行 + 一段话）。它要排在目录上面，
    # 否则读起来就成了"目录 → 版本号 → 这本书讲什么"。
    parts = re.split(r"(?m)^(?=##\s)", md, maxsplit=1)
    head = parts[0]
    rest = parts[1] if len(parts) > 1 else ""

    _, preface = parse(head)
    toc, body = parse(rest)

    # 「一页速查」单独成页：它是拿来打印贴墙的，不该跟术语表挤在一起，
    # 更不该只剩三行掉到下一页。
    for i, frag in enumerate(body):
        if frag.startswith("<h3") and "一页速查" in frag:
            body = body[:i] + ['<section class="cheatsheet">'] + body[i:] + ["</section>"]
            break

    OUT_HTML.parent.mkdir(parents=True, exist_ok=True)
    OUT_HTML.write_text(build_html(preface, toc, body), encoding="utf-8")
    print(f"[+] HTML  {OUT_HTML.relative_to(ROOT)}  ({OUT_HTML.stat().st_size / 1024:.0f} KB)")

    if "--html-only" not in sys.argv:
        if to_pdf(OUT_HTML, OUT_PDF):
            print(f"[+] PDF   {OUT_PDF.relative_to(ROOT)}  ({OUT_PDF.stat().st_size / 1024:.0f} KB)")
        else:
            print("[!] PDF 生成失败，HTML 仍可用（浏览器里 ⌘P 也能印）", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
