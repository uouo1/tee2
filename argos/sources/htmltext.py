"""HTML to readable text.

Filing documents are inline-XBRL HTML: tables, hidden tag soup and footnotes.
This turns one into paragraphs the ingest pipeline can chunk, without pulling in
a parsing dependency.
"""

from __future__ import annotations

import re
from html.parser import HTMLParser

BLOCK_TAGS = {
    "p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6",
    "table", "section", "article", "blockquote", "td", "th",
}
SKIP_TAGS = {"script", "style", "noscript", "head", "title"}
WHITESPACE_RE = re.compile(r"[ \t   ]+")
ZERO_WIDTH_RE = re.compile("[\u200b\u200c\u200d\u2060\ufeff]")
BLANK_LINES_RE = re.compile(r"\n{3,}")
PAGE_NUMBER_RE = re.compile(r"^\s*(?:page\s+)?\d{1,3}\s*$", re.I)
# Running page headers and table-of-contents rows: "Table of Contents",
# "Item 1A. Risk Factors 12", "PART II", "Signatures 48".
TOC_LINE_RE = re.compile(
    r"^(?:table of contents|part\s+[ivx]+|signatures?|exhibit index"
    r"|item\s+\d+[a-c]?\.?\s+[A-Za-z ,'&/-]{2,80}?\s*\d{0,3})\s*$",
    re.I,
)


class _Extractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._skip_depth = 0
        self._hidden_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in SKIP_TAGS:
            self._skip_depth += 1
            return
        # Inline XBRL hides a parallel copy of every fact; keep it out of the text.
        attributes = dict(attrs)
        style = (attributes.get("style") or "").replace(" ", "").lower()
        if tag == "ix:header" or "display:none" in style:
            self._hidden_depth += 1
            return
        if tag in BLOCK_TAGS:
            self.parts.append("\n")
        if tag in ("p", "div", "tr", "table", "h1", "h2", "h3"):
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in SKIP_TAGS and self._skip_depth:
            self._skip_depth -= 1
            return
        if (tag == "ix:header" or tag == "div") and self._hidden_depth:
            self._hidden_depth -= 1
            return
        if tag in BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self._skip_depth or self._hidden_depth or not data.strip():
            return
        self.parts.append(data)


def html_to_text(markup: str | bytes, *, max_chars: int | None = None) -> str:
    """Extract readable paragraphs from an HTML (or plain text) filing."""
    if isinstance(markup, bytes):
        markup = markup.decode("utf-8", errors="replace")
    parser = _Extractor()
    try:
        parser.feed(markup)
        parser.close()
    except Exception:  # malformed filings are common; keep whatever we parsed
        pass
    text = "".join(parser.parts)
    text = ZERO_WIDTH_RE.sub("", text)
    text = WHITESPACE_RE.sub(" ", text)
    lines = []
    for line in text.split("\n"):
        line = line.strip()
        if not line or PAGE_NUMBER_RE.match(line) or TOC_LINE_RE.match(line):
            continue
        # A page header fused to the first words of the next paragraph.
        if line.lower().startswith("table of contents "):
            line = line[len("table of contents "):].lstrip()
        lines.append(line)

    # Re-join wrapped sentence fragments into paragraphs: a line that neither
    # ends a sentence nor starts a new one belongs with its neighbour.
    paragraphs: list[str] = []
    buffer = ""
    for line in lines:
        if buffer and not buffer.endswith((".", ":", ";", "?", "!", '"')) and line[:1].islower():
            buffer = f"{buffer} {line}"
            continue
        if buffer:
            paragraphs.append(buffer)
        buffer = line
    if buffer:
        paragraphs.append(buffer)

    result = BLANK_LINES_RE.sub("\n\n", "\n\n".join(paragraphs)).strip()
    if max_chars and len(result) > max_chars:
        cut = result.rfind("\n\n", 0, max_chars)
        result = result[: cut if cut > max_chars // 2 else max_chars]
    return result
