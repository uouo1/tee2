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
# Double newline after these so the next text starts a fresh paragraph rather
# than gluing onto a table cell.
PARAGRAPH_TAGS = {"p", "div", "tr", "table", "h1", "h2", "h3"}
SKIP_TAGS = {"script", "style", "noscript", "head", "title"}
VOID_TAGS = {"br", "img", "hr", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr"}
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
        # Open elements as (tag, hidden), outermost first, plus a count of the
        # hidden ones so the common path is a single comparison. An earlier
        # version kept one counter and decremented it on any </div>, so a hidden
        # <td> or <span> swallowed the rest of a 10-Q (10 of 14 real filings kept
        # under 10% of their text). Un-hiding only when the tag that opened the
        # hidden block closes keeps the paragraph after it.
        self._stack: list[tuple[str, bool]] = []
        self._hidden = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in SKIP_TAGS:
            self._skip_depth += 1
            return
        # Markup inside <head> or <noscript> is not content either, and a hidden
        # block opened there must not leak past the skipped element's close.
        if self._skip_depth:
            return
        # Inline XBRL hides a parallel copy of every fact; keep it out of the text.
        attributes = dict(attrs)
        style = (attributes.get("style") or "").replace(" ", "").lower()
        hidden = tag == "ix:header" or "display:none" in style
        # Void tags never close, so they never open a block (hidden or not).
        if tag not in VOID_TAGS:
            self._stack.append((tag, hidden))
            if hidden:
                self._hidden += 1
        if self._hidden:
            return
        if tag in BLOCK_TAGS:
            self.parts.append("\n")
        if tag in PARAGRAPH_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in SKIP_TAGS:
            if self._skip_depth:
                self._skip_depth -= 1
            return
        if self._skip_depth:
            return
        index = next((i for i in range(len(self._stack) - 1, -1, -1) if self._stack[i][0] == tag), None)
        if index is None:
            # A stray close tag with nothing to close still ends a block in a
            # browser's rendering ("Alpha</p>Beta" shows two paragraphs), so it
            # still earns its newline; otherwise two words glue together.
            if not self._hidden and (tag in BLOCK_TAGS or tag in PARAGRAPH_TAGS):
                self.parts.append("\n")
            return
        # Closing an element closes whatever is still open inside it, as a
        # browser would: an unclosed hidden <span> ends with its table cell
        # rather than hiding every page that follows. Any block closed that way
        # still ends with a newline.
        closed = self._stack[index:]
        del self._stack[index:]
        for _name, hidden in closed:
            if hidden:
                self._hidden -= 1
        if self._hidden:
            return
        if any(name in BLOCK_TAGS or name in PARAGRAPH_TAGS for name, _hidden in closed):
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self._skip_depth or self._hidden:
            return
        if not data.strip():
            # A whitespace-only text node is still a separator: filings wrap
            # "<span>the</span><span> </span><span>FASB</span>", and dropping the
            # middle span glued the words ("theFASB"), which no search can find.
            if data and self.parts and not self.parts[-1].endswith((" ", "\n")):
                self.parts.append(" ")
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
