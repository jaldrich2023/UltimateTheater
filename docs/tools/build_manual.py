#!/usr/bin/env python3
"""Converts docs/USER_MANUAL.md into the styled HTML manual (docs/manual/...).

Handles the Markdown subset the manual uses: headings, paragraphs, nested lists,
tables, images, horizontal rules, fenced code, and inline bold/italic/code/links.
"""
import html
import re
import sys

SRC, OUT = sys.argv[1], sys.argv[2]

def slug(text):
    text = re.sub(r"<[^>]+>", "", text)
    text = text.lower().strip()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")

def fix_link(url):
    if url.startswith(("http://", "https://", "#", "mailto:")):
        return url
    if url.startswith("images/"):
        return "../" + url
    # Other repository files link to GitHub, so the PDF never carries local file paths.
    repo = "https://github.com/jaldrich2023/UltimateTheater/blob/main/"
    if url.startswith("../"):
        return repo + url[3:]
    return repo + "docs/" + url

def inline(text):
    # Protect code spans first.
    codes = []
    def keep_code(m):
        codes.append("<code>" + html.escape(m.group(1)) + "</code>")
        return f"\x00{len(codes) - 1}\x00"
    text = re.sub(r"`([^`]+)`", keep_code, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", lambda m: f'<img src="{fix_link(m.group(2))}" alt="{m.group(1)}">', text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", lambda m: f'<a href="{fix_link(m.group(2))}">{m.group(1)}</a>', text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], text)
    return text

KEY_HEADERS = {"Key", "Shortcut"}

def render_table(rows):
    def cells(line):
        return [c.strip() for c in line.strip().strip("|").split("|")]
    header = cells(rows[0])
    body = [cells(r) for r in rows[2:]]
    is_keys = header[0] in KEY_HEADERS
    out = ['<table class="keys">' if is_keys else "<table>", "<thead><tr>"]
    out += [f"<th>{inline(h)}</th>" for h in header]
    out.append("</tr></thead><tbody>")
    for row in body:
        out.append("<tr>")
        for i, c in enumerate(row):
            if is_keys and i == 0:
                parts = [p.strip() for p in re.split(r"( / |, )", c)]
                rendered = "".join(
                    f'<span class="sep">{html.escape(p.strip())}</span>' if p.strip() in ("/", ",") else f"<kbd>{html.escape(p)}</kbd>"
                    for p in parts if p.strip())
                out.append(f"<td>{rendered}</td>")
            else:
                out.append(f"<td>{inline(c)}</td>")
        out.append("</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)

def figure(alt, src):
    name = src.rsplit("/", 1)[-1]
    size = "wide"
    if name.startswith(("14-", "19-")):
        size = "narrow"
    elif name.startswith(("15-", "16-", "17-", "18-")):
        size = "medium"
    return (f'<figure class="shot {size}"><img src="{fix_link(src)}" alt="{html.escape(alt)}">'
            f"<figcaption>{html.escape(alt)}</figcaption></figure>")

def render_list(lines):
    """lines: list of (indent, raw) for a contiguous list block."""
    out = []
    stack = []  # (indent, tag)
    item_open = []
    for indent, raw in lines:
        m = re.match(r"(\s*)([-*]|\d+\.)\s+(.*)", raw)
        if not m:
            # continuation of previous item
            out.append(" " + inline(raw.strip()))
            continue
        tag = "ol" if m.group(2)[0].isdigit() else "ul"
        while stack and indent < stack[-1][0]:
            out.append("</li>")
            out.append(f"</{stack[-1][1]}>")
            stack.pop()
        if not stack or indent > stack[-1][0]:
            out.append(f"<{tag}>")
            stack.append((indent, tag))
        else:
            out.append("</li>")
        out.append("<li>" + inline(m.group(3)))
    while stack:
        out.append("</li>")
        out.append(f"</{stack[-1][1]}>")
        stack.pop()
    return "".join(out)

def convert(md):
    lines = md.split("\n")
    blocks = []
    i = 0
    para = []

    def flush_para():
        nonlocal para
        if para:
            text = " ".join(p.strip() for p in para)
            blocks.append(("p", text))
            para = []

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped:
            flush_para(); i += 1; continue
        if stripped.startswith("```"):
            flush_para()
            code = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i]); i += 1
            i += 1
            blocks.append(("code", "\n".join(code)))
            continue
        m = re.match(r"(#{1,4})\s+(.*)", line)
        if m:
            flush_para()
            blocks.append((f"h{len(m.group(1))}", m.group(2)))
            i += 1; continue
        if stripped == "---":
            flush_para(); blocks.append(("hr", "")); i += 1; continue
        if stripped.startswith("|"):
            flush_para()
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(lines[i]); i += 1
            blocks.append(("table", rows))
            continue
        img = re.fullmatch(r"!\[([^\]]*)\]\(([^)]+)\)", stripped)
        if img:
            flush_para(); blocks.append(("img", (img.group(1), img.group(2)))); i += 1; continue
        if re.match(r"\s*([-*]|\d+\.)\s+", line):
            flush_para()
            items = []
            while i < len(lines):
                l = lines[i]
                if not l.strip():
                    # a blank line ends the list unless the next line continues it
                    if i + 1 < len(lines) and re.match(r"\s*([-*]|\d+\.)\s+", lines[i + 1]):
                        i += 1; continue
                    break
                if re.match(r"\s*([-*]|\d+\.)\s+", l) or l.startswith("  "):
                    items.append((len(l) - len(l.lstrip()), l)); i += 1
                else:
                    break
            blocks.append(("list", items))
            continue
        para.append(line)
        i += 1
    flush_para()
    return blocks

md = open(SRC, encoding="utf-8").read()
blocks = convert(md)

# Split: cover (before "## Contents"), contents list, sections.
cover, toc, body = [], [], []
phase = "cover"
for kind, value in blocks:
    if kind == "h2" and value == "Contents":
        phase = "toc"; continue
    if phase == "toc" and kind == "h2":
        phase = "body"
    {"cover": cover, "toc": toc, "body": body}[phase].append((kind, value))

def render_blocks(items):
    out = []
    section_open = False
    for kind, value in items:
        if kind == "hr":
            continue
        if kind == "h2":
            if section_open:
                out.append("</section>")
            num, _, title = value.partition(". ")
            if not title:
                num, title = "", value
            out.append(f'<section class="chapter" id="{slug(value)}">')
            out.append(f'<div class="chapter-head"><span class="num">{num.zfill(2) if num else ""}</span>'
                       f'<h2>{inline(title)}</h2></div>')
            section_open = True
        elif kind in ("h3", "h4"):
            out.append(f'<{kind} id="{slug(value)}">{inline(value)}</{kind}>')
        elif kind == "p" and value.startswith("<img "):
            out.append('<p class="logo">' + re.sub(r'src="([^"]+)"', lambda m: f'src="{fix_link(m.group(1))}"', value) + "</p>")
        elif kind == "p":
            # A paragraph whose first line is bold and ends with a period/question: FAQ style.
            if re.match(r"\*\*[^*]+[?.\"]\*\*\s", value) and "Troubleshooting" in "".join(out[-200:]):
                q = re.match(r"\*\*([^*]+)\*\*\s*(.*)", value)
                out.append(f'<div class="faq"><p class="q">{inline(q.group(1))}</p><p>{inline(q.group(2))}</p></div>')
            else:
                out.append(f"<p>{inline(value)}</p>")
        elif kind == "table":
            out.append(render_table(value))
        elif kind == "img":
            out.append(figure(*value))
        elif kind == "list":
            out.append(render_list(value))
        elif kind == "code":
            out.append(f"<pre><code>{html.escape(value)}</code></pre>")
    if section_open:
        out.append("</section>")
    return "\n".join(out)

# Contents: the numbered list of chapter links, with each chapter's sub-sections.
chapters = []
current = None
for kind, value in body:
    if kind == "h2":
        current = (value, [])
        chapters.append(current)
    elif kind == "h3" and current:
        current[1].append(value)

toc_html = ['<ol class="toc">']
for title, subs in chapters:
    num, _, name = title.partition(". ")
    toc_html.append(f'<li><a href="#{slug(title)}"><span class="num">{num.zfill(2)}</span>'
                    f'<span class="t">{inline(name)}</span></a>')
    if subs:
        toc_html.append('<span class="subs">' + " · ".join(
            f'<a href="#{slug(s)}">{inline(s)}</a>' for s in subs) + "</span>")
    toc_html.append("</li>")
toc_html.append("</ol>")

hero = next((v for k, v in cover if k == "img"), ("", "images/01-home.jpg"))
intro = [v for k, v in cover if k == "p"]

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ultimate Theater — User Manual</title>
<link rel="stylesheet" href="../brochure/theater.css">
<style>
@page {{ size: Letter; margin: 0 0 0.55in 0; background: #0A0A0F;
  @bottom-left {{ content: "ULTIMATE THEATER  ·  USER MANUAL"; color: rgba(255,255,255,.38); font: 600 7.5pt system-ui, -apple-system, "Helvetica Neue", sans-serif; letter-spacing: .18em; padding-left: 0.8in; vertical-align: top; padding-top: 0.08in; }}
  @bottom-right {{ content: counter(page); color: rgba(255,255,255,.55); font: 700 8pt system-ui, -apple-system, "Helvetica Neue", sans-serif; padding-right: 0.8in; vertical-align: top; padding-top: 0.08in; }}
}}
@page :first {{ margin: 0; @bottom-left {{ content: none; }} @bottom-right {{ content: none; }} }}
</style>
</head>
<body class="manual">
<div class="page-glow" aria-hidden="true"></div>

<section class="cover-page">
  <div class="cover-top">
    <img class="app-icon" src="../images/app-icon.png" alt="">
    <div class="brandmark big"><span class="mark"></span><b>ULTIMATE</b> THEATER</div>
  </div>
  <h1 class="cover-title">User Manual</h1>
  <p class="cover-tag">{inline(intro[0]) if intro else ""}</p>
  <p class="cover-meta">{inline(intro[1]) if len(intro) > 1 else ""}</p>
  <figure class="cover-shot glass-frame"><img src="{fix_link(hero[1])}" alt="{html.escape(hero[0])}"></figure>
  <p class="cover-lede">{inline(intro[2]) if len(intro) > 2 else ""}</p>
  <p class="cover-foot">© 2026 John Aldrich · github.com/jaldrich2023/UltimateTheater</p>
</section>

<div class="flow">
<section class="toc-page">
  <div class="chapter-head"><h2>Contents</h2></div>
  {"".join(toc_html)}
</section>

{render_blocks(body)}
</div>
</body>
</html>
"""
open(OUT, "w", encoding="utf-8").write(page)
print("wrote", OUT, len(page), "bytes;", len(chapters), "chapters")
