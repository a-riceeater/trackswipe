#!/usr/bin/env python3
"""Adds (or replaces) one release in appcast.xml, Sparkle's update feed.

Usage: scripts/update_appcast.py <archive.zip> <shortVersion> <buildVersion> <download-url> <edSignature> <length> [notes.md]

Run by scripts/package.sh. The appcast must only be pushed AFTER the archive is uploaded to the GitHub
release at <download-url>, otherwise users would be offered an update that 404s.
"""
import html, os, re, sys
from email.utils import formatdate

_, archive, short, build, url, signature, length, *rest = sys.argv
notes_path = rest[0] if rest else None
APPCAST = os.path.join(os.path.dirname(__file__), "..", "appcast.xml")
MIN_OS = "13.0"

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>TrackEdge</title>
    <link>https://github.com/a-riceeater/trackswipe</link>
    <description>TrackEdge updates</description>
    <language>en</language>
  </channel>
</rss>
"""

def notes_html(path):
    """Tiny markdown subset → HTML: headings, bullet lists, paragraphs, **bold**, `code`."""
    if not path:
        return ""
    out, in_list = [], False
    def inline(t):
        t = html.escape(t)
        t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
        return re.sub(r"`(.+?)`", r"<code>\1</code>", t)
    for line in open(path, encoding="utf-8").read().splitlines():
        s = line.strip()
        if s.startswith(("- ", "* ")):
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append(f"<li>{inline(s[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>"); in_list = False
        if s.startswith("#"):
            level = min(len(s) - len(s.lstrip("#")) + 1, 4)
            out.append(f"<h{level}>{inline(s.lstrip('#').strip())}</h{level}>")
        elif s:
            out.append(f"<p>{inline(s)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)

doc = open(APPCAST, encoding="utf-8").read() if os.path.exists(APPCAST) else HEADER
# Re-running for the same build replaces its entry instead of duplicating it.
doc = re.sub(r"\s*<item>(?:(?!</item>).)*?<sparkle:version>" + re.escape(build) + r"</sparkle:version>.*?</item>",
             "", doc, flags=re.S)

body = notes_html(notes_path)
description = f"\n      <description><![CDATA[\n{body}\n      ]]></description>" if body else ""
item = f"""
    <item>
      <title>Version {html.escape(short)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(short)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MIN_OS}</sparkle:minimumSystemVersion>{description}
      <enclosure url="{html.escape(url)}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>"""

# Newest first: insert before the first existing item, or before </channel>.
anchor = doc.find("<item>")
if anchor == -1:
    anchor = doc.find("</channel>")
    doc = doc[:anchor].rstrip() + item + "\n  " + doc[anchor:]
else:
    line_start = doc.rfind("\n", 0, anchor)
    doc = doc[:line_start] + item + doc[line_start:]

open(APPCAST, "w", encoding="utf-8").write(doc)
print(f"appcast.xml: added {short} ({build}) → {url}")
