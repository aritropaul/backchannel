#!/usr/bin/env python3
"""Release notes (the Markdown a release's tag carries) as the little HTML Sparkle's
update window shows: ### headings, - lists, paragraphs, **bold** and `code`.
Reads stdin, writes stdout. Text is escaped, so it can sit in the appcast's CDATA."""
import html
import re
import sys


def inline(text):
    t = html.escape(text, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", t)


out, para, items = [], [], []


def flush():
    if para:
        out.append("<p>" + inline(" ".join(para)) + "</p>")
        para.clear()
    if items:
        out.append("<ul>" + "".join("<li>" + inline(i) + "</li>" for i in items) + "</ul>")
        items.clear()


for raw in sys.stdin.read().splitlines():
    line = raw.strip()
    if not line:
        flush()
    elif line.startswith("#"):
        flush()
        out.append("<h3>" + inline(line.lstrip("#").strip()) + "</h3>")
    elif line.startswith(("- ", "* ")):
        if para:
            flush()
        items.append(line[2:].strip())
    elif items and raw.startswith((" ", "\t")):
        items[-1] += " " + line  # a list item wrapped onto the next line
    else:
        if items:
            flush()
        para.append(line)
flush()
print("\n".join(out))
