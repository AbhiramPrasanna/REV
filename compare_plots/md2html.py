#!/usr/bin/env python3
"""Convert QUESTIONS.md -> a single self-contained HTML with all graphs embedded
as base64. Handles the markdown subset used in that file: #/##/### headings,
**bold**, `code`, pipe tables, ---, - lists, ![img](png), [text](link), and
"**Proof:**" paragraphs (rendered as an embedded figure gallery)."""
import base64
import html
import os
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "QUESTIONS.md"
OUT = sys.argv[2] if len(sys.argv) > 2 else "QUESTIONS.html"
BASE = os.path.dirname(os.path.abspath(SRC))

_img_cache = {}


def data_uri(fname):
    if fname in _img_cache:
        return _img_cache[fname]
    path = os.path.join(BASE, fname)
    with open(path, "rb") as fh:
        b64 = base64.b64encode(fh.read()).decode("ascii")
    uri = f"data:image/png;base64,{b64}"
    _img_cache[fname] = uri
    return uri


def inline(text):
    """Inline markdown -> HTML on already-text content."""
    text = html.escape(text)
    # images (shouldn't appear here after proof handling, but be safe)
    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)",
                  lambda m: f'<img class="inl" src="{data_uri(m.group(2))}" alt="{m.group(1)}">',
                  text)
    # links
    def _link(m):
        txt, href = m.group(1), m.group(2)
        if href.lower().endswith(".png"):
            return f'<span class="fn">{txt}</span>'  # filename, not a live link
        return f'<a href="{href}">{txt}</a>'
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", _link, text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return text


def pngs_in(text):
    """All .png paths referenced in a block, deduped, order preserved."""
    out, seen = [], set()
    for m in re.finditer(r"\(([^)]+\.png)\)", text):
        p = m.group(1)
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def render_proof(block_text):
    figs = pngs_in(block_text)
    cards = "\n".join(
        f'<figure><img src="{data_uri(p)}" alt="{p}">'
        f'<figcaption>{html.escape(p)}</figcaption></figure>'
        for p in figs)
    return f'<div class="proof"><div class="proof-label">Proof</div>' \
           f'<div class="gallery">{cards}</div></div>'


def render_table(rows):
    # rows: list of raw "| a | b |" lines; row[1] is the |---| separator
    def cells(line):
        line = line.strip().strip("|")
        return [c.strip() for c in line.split("|")]
    header = cells(rows[0])
    body = [cells(r) for r in rows[2:]]
    th = "".join(f"<th>{inline(c)}</th>" for c in header)
    trs = ""
    for r in body:
        tds = "".join(f"<td>{inline(c)}</td>" for c in r)
        trs += f"<tr>{tds}</tr>"
    return f"<table><thead><tr>{th}</tr></thead><tbody>{trs}</tbody></table>"


def main():
    with open(SRC, encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    out = []
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        s = line.strip()
        if not s:
            i += 1
            continue
        # horizontal rule (a line of only dashes)
        if re.fullmatch(r"-{3,}", s):
            out.append("<hr>")
            i += 1
            continue
        # heading
        m = re.match(r"(#{1,6})\s+(.*)", s)
        if m:
            lvl = len(m.group(1))
            out.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>")
            i += 1
            continue
        # table
        if s.startswith("|"):
            tbl = []
            while i < n and lines[i].strip().startswith("|"):
                tbl.append(lines[i])
                i += 1
            if len(tbl) >= 2:
                out.append(render_table(tbl))
            continue
        # list
        if s.startswith("- "):
            items = []
            while i < n and lines[i].strip().startswith("- "):
                items.append(lines[i].strip()[2:])
                i += 1
            lis = "".join(f"<li>{inline(it)}</li>" for it in items)
            out.append(f"<ul>{lis}</ul>")
            continue
        # paragraph (gather until blank / next block)
        para = []
        while i < n and lines[i].strip() and not re.match(r"(#{1,6}\s|\||- )", lines[i].strip()) \
                and not re.fullmatch(r"-{3,}", lines[i].strip()):
            para.append(lines[i])
            i += 1
        ptext = "\n".join(para).strip()
        if (ptext.startswith("**Proof:**") or ptext.startswith("Proof:")) and pngs_in(ptext):
            out.append(render_proof(ptext))
        else:
            out.append(f"<p>{inline(ptext)}</p>")

    body = "\n".join(out)
    doc = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>DEX offload, cache and memory threads: questions and answers</title>
<style>
  :root {{ --ink:#1a1a1a; --muted:#666; --line:#ddd; --accent:#b30000; --bg:#fafafa; }}
  * {{ box-sizing: border-box; }}
  body {{ font: 16px/1.55 -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
         color: var(--ink); max-width: 980px; margin: 0 auto; padding: 40px 28px 80px; background:#fff; }}
  h1 {{ font-size: 1.8rem; border-bottom: 3px solid var(--accent); padding-bottom: .3em; }}
  h2 {{ font-size: 1.35rem; margin-top: 2.2em; border-bottom: 1px solid var(--line); padding-bottom: .2em; }}
  h3 {{ font-size: 1.08rem; margin-top: 1.6em; color:#000; }}
  hr {{ border: 0; border-top: 1px solid var(--line); margin: 2.2em 0; }}
  code {{ background:#f2f2f2; padding: .1em .35em; border-radius: 4px; font-size: .9em; }}
  table {{ border-collapse: collapse; margin: 1em 0; font-size: .92rem; width: auto; }}
  th, td {{ border: 1px solid var(--line); padding: 5px 12px; text-align: right; }}
  th:first-child, td:first-child {{ text-align: left; }}
  thead th {{ background: var(--bg); }}
  .proof {{ background: var(--bg); border: 1px solid var(--line); border-left: 4px solid var(--accent);
            border-radius: 6px; padding: 12px 14px; margin: 1em 0 1.4em; }}
  .proof-label {{ font-weight: 700; font-size: .78rem; letter-spacing:.08em; text-transform: uppercase;
                  color: var(--accent); margin-bottom: 8px; }}
  .gallery {{ display: flex; flex-wrap: wrap; gap: 14px; }}
  figure {{ margin: 0; flex: 1 1 440px; max-width: 100%; background:#fff; border:1px solid var(--line);
            border-radius:6px; padding:6px; }}
  figure img {{ width: 100%; height: auto; display:block; }}
  figcaption {{ font-size: .72rem; color: var(--muted); margin-top: 4px; word-break: break-all; }}
  img.inl {{ max-width: 100%; }}
  .fn {{ font-size:.8rem; color: var(--muted); }}
  a {{ color: var(--accent); }}
  @media print {{
     body {{ max-width: none; padding: 0 8px; }}
     h2 {{ page-break-before: auto; }}
     .proof, figure, table {{ page-break-inside: avoid; }}
  }}
</style></head>
<body>
{body}
</body></html>"""
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(doc)
    size = os.path.getsize(OUT) / 1024
    print(f"wrote {OUT}  ({size:.0f} KB, {len(_img_cache)} unique graphs embedded)")


if __name__ == "__main__":
    main()
