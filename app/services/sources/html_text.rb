# frozen_string_literal: true

require "cgi"
require "set"
require "strscan"

module Sources
  # HTML to readable text.
  #
  # Filing documents are inline-XBRL HTML: tables, hidden tag soup and footnotes.
  # This turns one into paragraphs the ingest pipeline can chunk, without pulling
  # in a parsing dependency: a hand-written tag scanner on `strscan` replays the
  # event stream Python's html.parser produced (start tag, end tag, text), so the
  # same skip / hidden / block rules apply. REXML is too strict for filings and
  # Nokogiri is not available.
  module HtmlText
    BLOCK_TAGS = %w[
      p div br tr li h1 h2 h3 h4 h5 h6
      table section article blockquote td th
    ].to_set.freeze
    # Tags whose text is never content. Double newline after these so the next
    # text starts a fresh paragraph rather than gluing onto a table cell.
    PARAGRAPH_TAGS = %w[p div tr table h1 h2 h3].to_set.freeze
    SKIP_TAGS = %w[script style noscript head title].to_set.freeze
    VOID_TAGS = %w[br img hr input meta link area base col embed source track wbr].to_set.freeze
    # Elements whose content is raw text (a "<" inside a script is not a tag).
    RAW_TEXT_TAGS = %w[script style].to_set.freeze

    # Space, tab, NBSP, figure space and narrow NBSP — the padding filings use.
    WHITESPACE_RE = /[ \t   ]+/
    ZERO_WIDTH_RE = /[​‌‍⁠﻿]/
    BLANK_LINES_RE = /\n{3,}/
    # Python's \d and \s are Unicode-wide; POSIX classes keep that here.
    PAGE_NUMBER_RE = /\A[[:space:]]*(?:page[[:space:]]+)?[[:digit:]]{1,3}[[:space:]]*\z/i
    # Running page headers and table-of-contents rows: "Table of Contents",
    # "Item 1A. Risk Factors 12", "PART II", "Signatures 48".
    TOC_LINE_RE = Regexp.new(
      "\\A(?:table of contents|part[[:space:]]+[ivx]+|signatures?|exhibit index" \
      "|item[[:space:]]+[[:digit:]]+[a-c]?\\.?[[:space:]]+[A-Za-z ,'&/-]{2,80}?[[:space:]]*[[:digit:]]{0,3})[[:space:]]*\\z",
      Regexp::IGNORECASE
    )
    # Python's str.strip(): any Unicode whitespace at either edge.
    EDGE_WS_RE = /\A[[:space:]]+|[[:space:]]+\z/
    TOC_PREFIX = "table of contents "
    SENTENCE_ENDINGS = [".", ":", ";", "?", "!", '"'].freeze

    # html.parser's tolerant tag name: a letter, then anything up to whitespace,
    # "/" or ">" — so "ix:header" keeps its prefix.
    TAG_NAME_RE = %r{[A-Za-z][^\t\n\r\f />\x00]*}
    ATTR_NAME_RE = %r{[^\s/>][^\s/=>]*}
    ENTITY_RE = /&([A-Za-z][A-Za-z0-9]*);/
    NUMERIC_ENTITY_RE = /&#(?:([0-9]+)|[xX]([0-9a-fA-F]+));/

    # HTML5 — and Python's html.unescape — read numeric references in the C1
    # control range as Windows-1252, which is what Word-authored press releases
    # mean by &#146; and &#151;. CGI.unescapeHTML would emit the bare control
    # character, so these are resolved first.
    CP1252_CHARREFS = {
      128 => "€", 129 => "\u0081", 130 => "‚", 131 => "ƒ", 132 => "„", 133 => "…", 134 => "†", 135 => "‡",
      136 => "ˆ", 137 => "‰", 138 => "Š", 139 => "‹", 140 => "Œ", 141 => "\u008d", 142 => "Ž", 143 => "\u008f",
      144 => "\u0090", 145 => "‘", 146 => "’", 147 => "“", 148 => "”", 149 => "•", 150 => "–", 151 => "—",
      152 => "˜", 153 => "™", 154 => "š", 155 => "›", 156 => "œ", 157 => "\u009d", 158 => "ž", 159 => "Ÿ"
    }.freeze
    SURROGATES = (0xD800..0xDFFF)
    # html.unescape's _invalid_codepoints: C0/C1 controls (bar tab, LF, FF, CR)
    # and the noncharacters vanish rather than reaching the text. Presentation
    # decks exported to HTML are full of &#11; line breaks, for one.
    INVALID_CODEPOINTS = [0x1..0x8, 0xB..0xB, 0xE..0x1F, 0x7F..0x9F, 0xFDD0..0xFDEF].freeze

    # CGI.unescapeHTML knows only the XML five plus numeric references; filings
    # lean on the Latin-1 and typographic names too. Unknown names are left as
    # written, as html.unescape leaves anything it cannot resolve.
    NAMED_ENTITIES = {
      "nbsp" => " ", "iexcl" => "¡", "cent" => "¢", "pound" => "£", "curren" => "¤", "yen" => "¥",
      "brvbar" => "¦", "sect" => "§", "uml" => "¨", "copy" => "©", "ordf" => "ª", "laquo" => "«",
      "not" => "¬", "shy" => "­", "reg" => "®", "macr" => "¯", "deg" => "°", "plusmn" => "±",
      "sup2" => "²", "sup3" => "³", "acute" => "´", "micro" => "µ", "para" => "¶", "middot" => "·",
      "cedil" => "¸", "sup1" => "¹", "ordm" => "º", "raquo" => "»", "frac14" => "¼", "frac12" => "½",
      "frac34" => "¾", "iquest" => "¿", "times" => "×", "divide" => "÷",
      "Agrave" => "À", "Aacute" => "Á", "Acirc" => "Â", "Atilde" => "Ã", "Auml" => "Ä", "Aring" => "Å",
      "AElig" => "Æ", "Ccedil" => "Ç", "Egrave" => "È", "Eacute" => "É", "Ecirc" => "Ê", "Euml" => "Ë",
      "Igrave" => "Ì", "Iacute" => "Í", "Icirc" => "Î", "Iuml" => "Ï", "ETH" => "Ð", "Ntilde" => "Ñ",
      "Ograve" => "Ò", "Oacute" => "Ó", "Ocirc" => "Ô", "Otilde" => "Õ", "Ouml" => "Ö", "Oslash" => "Ø",
      "Ugrave" => "Ù", "Uacute" => "Ú", "Ucirc" => "Û", "Uuml" => "Ü", "Yacute" => "Ý", "THORN" => "Þ",
      "szlig" => "ß", "agrave" => "à", "aacute" => "á", "acirc" => "â", "atilde" => "ã", "auml" => "ä",
      "aring" => "å", "aelig" => "æ", "ccedil" => "ç", "egrave" => "è", "eacute" => "é", "ecirc" => "ê",
      "euml" => "ë", "igrave" => "ì", "iacute" => "í", "icirc" => "î", "iuml" => "ï", "eth" => "ð",
      "ntilde" => "ñ", "ograve" => "ò", "oacute" => "ó", "ocirc" => "ô", "otilde" => "õ", "ouml" => "ö",
      "oslash" => "ø", "ugrave" => "ù", "uacute" => "ú", "ucirc" => "û", "uuml" => "ü", "yacute" => "ý",
      "thorn" => "þ", "yuml" => "ÿ",
      "ndash" => "–", "mdash" => "—", "lsquo" => "‘", "rsquo" => "’", "sbquo" => "‚", "ldquo" => "“",
      "rdquo" => "”", "bdquo" => "„", "dagger" => "†", "Dagger" => "‡", "bull" => "•", "hellip" => "…",
      "permil" => "‰", "prime" => "′", "Prime" => "″", "lsaquo" => "‹", "rsaquo" => "›", "oline" => "‾",
      "euro" => "€", "trade" => "™", "larr" => "←", "uarr" => "↑", "rarr" => "→", "darr" => "↓",
      "minus" => "−", "lowast" => "∗", "radic" => "√", "infin" => "∞", "ne" => "≠", "le" => "≤",
      "ge" => "≥", "loz" => "◊", "ensp" => " ", "emsp" => " ", "thinsp" => " ",
      "zwnj" => "‌", "zwj" => "‍", "lrm" => "‎", "rlm" => "‏",
      # The rest of the HTML 4 set — Greek letters, mathematical operators,
      # arrows and card suits — which footnotes and formula-heavy filings
      # (variable-rate debt, option-pricing inputs) reach for.
      "fnof" => "ƒ", "circ" => "ˆ", "tilde" => "˜", "OElig" => "Œ", "oelig" => "œ", "Scaron" => "Š",
      "scaron" => "š", "Yuml" => "Ÿ", "frasl" => "⁄", "weierp" => "℘", "image" => "ℑ", "real" => "ℜ",
      "alefsym" => "ℵ", "harr" => "↔", "crarr" => "↵", "lArr" => "⇐", "uArr" => "⇑", "rArr" => "⇒",
      "dArr" => "⇓", "hArr" => "⇔",
      "Alpha" => "Α", "Beta" => "Β", "Gamma" => "Γ", "Delta" => "Δ", "Epsilon" => "Ε", "Zeta" => "Ζ",
      "Eta" => "Η", "Theta" => "Θ", "Iota" => "Ι", "Kappa" => "Κ", "Lambda" => "Λ", "Mu" => "Μ",
      "Nu" => "Ν", "Xi" => "Ξ", "Omicron" => "Ο", "Pi" => "Π", "Rho" => "Ρ", "Sigma" => "Σ",
      "Tau" => "Τ", "Upsilon" => "Υ", "Phi" => "Φ", "Chi" => "Χ", "Psi" => "Ψ", "Omega" => "Ω",
      "alpha" => "α", "beta" => "β", "gamma" => "γ", "delta" => "δ", "epsilon" => "ε", "zeta" => "ζ",
      "eta" => "η", "theta" => "θ", "iota" => "ι", "kappa" => "κ", "lambda" => "λ", "mu" => "μ",
      "nu" => "ν", "xi" => "ξ", "omicron" => "ο", "pi" => "π", "rho" => "ρ", "sigmaf" => "ς",
      "sigma" => "σ", "tau" => "τ", "upsilon" => "υ", "phi" => "φ", "chi" => "χ", "psi" => "ψ",
      "omega" => "ω", "thetasym" => "ϑ", "upsih" => "ϒ", "piv" => "ϖ",
      "forall" => "∀", "part" => "∂", "exist" => "∃", "empty" => "∅", "nabla" => "∇", "isin" => "∈",
      "notin" => "∉", "ni" => "∋", "prod" => "∏", "sum" => "∑", "prop" => "∝", "ang" => "∠",
      "and" => "∧", "or" => "∨", "cap" => "∩", "cup" => "∪", "int" => "∫", "there4" => "∴",
      "sim" => "∼", "cong" => "≅", "asymp" => "≈", "equiv" => "≡", "sub" => "⊂", "sup" => "⊃",
      "nsub" => "⊄", "sube" => "⊆", "supe" => "⊇", "oplus" => "⊕", "otimes" => "⊗", "perp" => "⊥",
      "sdot" => "⋅", "lceil" => "⌈", "rceil" => "⌉", "lfloor" => "⌊", "rfloor" => "⌋",
      "lang" => "〈", "rang" => "〉", "spades" => "♠", "clubs" => "♣", "hearts" => "♥", "diams" => "♦"
    }.freeze

    module_function

    # Extract readable paragraphs from an HTML (or plain text) filing.
    def html_to_text(markup, max_chars: nil)
      text = Extractor.new.run(as_utf8(markup.to_s))
      text = text.gsub(ZERO_WIDTH_RE, "").gsub(WHITESPACE_RE, " ")

      lines = []
      text.split("\n").each do |line|
        line = line.gsub(EDGE_WS_RE, "")
        next if line.empty? || PAGE_NUMBER_RE.match?(line) || TOC_LINE_RE.match?(line)

        # A page header fused to the first words of the next paragraph.
        line = line[TOC_PREFIX.length..].sub(/\A[[:space:]]+/, "") if line.downcase.start_with?(TOC_PREFIX)
        lines << line
      end

      # Re-join wrapped sentence fragments into paragraphs: a line that neither
      # ends a sentence nor starts a new one belongs with its neighbour.
      paragraphs = []
      buffer = nil
      lines.each do |line|
        if buffer && !buffer.end_with?(*SENTENCE_ENDINGS) && line[0].match?(/\A[[:lower:]]\z/)
          buffer = "#{buffer} #{line}"
          next
        end
        paragraphs << buffer if buffer
        buffer = line
      end
      paragraphs << buffer if buffer

      result = paragraphs.join("\n\n").gsub(BLANK_LINES_RE, "\n\n").gsub(EDGE_WS_RE, "")
      if max_chars && result.length > max_chars
        # Cut at the last paragraph break that fits, unless that throws away
        # more than half of the budget; then cut mid-paragraph.
        cut = (max_chars >= 2 && result.rindex("\n\n", max_chars - 2)) || -1
        result = result[0, cut > max_chars / 2 ? cut : max_chars]
      end
      result
    end

    # Bytes (a fetched body) are decoded as UTF-8 with replacement, like
    # `bytes.decode("utf-8", errors="replace")`; other encodings are transcoded.
    def as_utf8(markup)
      if markup.encoding == Encoding::BINARY || markup.encoding == Encoding::US_ASCII
        markup.dup.force_encoding(Encoding::UTF_8).scrub("�")
      elsif markup.encoding == Encoding::UTF_8
        markup.valid_encoding? ? markup : markup.scrub("�")
      else
        markup.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
      end
    end

    # Numeric references html.unescape treats specially, then named entities
    # (only exact `&name;`), then CGI.unescapeHTML for the rest. The order
    # matters: unescaping `&amp;nbsp;` must yield the literal text "&nbsp;",
    # not a space.
    def unescape(text)
      return text unless text.include?("&")

      text = text.gsub(NUMERIC_ENTITY_RE) do |match|
        code = Regexp.last_match(1) ? Regexp.last_match(1).to_i : Regexp.last_match(2).to_i(16)
        if CP1252_CHARREFS.key?(code)
          CP1252_CHARREFS[code]
        elsif code.zero? || code > 0x10FFFF || SURROGATES.cover?(code)
          "�" # CGI would raise on a surrogate and emit NUL for &#0;
        elsif INVALID_CODEPOINTS.any? { |range| range.cover?(code) } || (code & 0xFFFE) == 0xFFFE
          ""
        else
          match
        end
      end
      text = text.gsub(ENTITY_RE) { |match| NAMED_ENTITIES.fetch(Regexp.last_match(1), match) }
      CGI.unescapeHTML(text)
    end

    # Streams the markup once, appending text and newlines to `parts`.
    class Extractor
      def initialize
        @parts = +""
        @skip_depth = 0
        # Open elements as [tag, hidden?], outermost first, plus a count of the
        # hidden ones so the common path is a single comparison. The reference
        # kept one counter and decremented it on any </div>, so a hidden <span>
        # swallowed the rest of a 10-Q (10 of 14 real filings kept under 10% of
        # their text). Un-hiding only when the tag that opened the hidden block
        # closes keeps the paragraph after it.
        @stack = []
        @hidden = 0
      end

      def run(markup)
        scanner = StringScanner.new(markup)
        begin
          scan(scanner)
        rescue StandardError
          # malformed filings are common; keep whatever we parsed
        end
        @parts
      end

      private

      def scan(scanner)
        until scanner.eos?
          text = scanner.scan(/[^<]+/)
          if text
            handle_data(text)
            next
          end
          scanner.getch # the "<"
          if scanner.skip(/!--/)
            # A comment; an unterminated one swallows the rest, as in html.parser.
            scanner.skip_until(/-->/) || scanner.terminate
          elsif scanner.skip(%r{[!?]})
            # <!DOCTYPE ...>, <?xml ...?> and friends carry no text.
            scanner.skip_until(/>/) || scanner.terminate
          elsif scanner.skip(%r{/})
            name = scanner.scan(TAG_NAME_RE)
            scanner.skip_until(/>/) || scanner.terminate
            handle_endtag(name.downcase) if name
          elsif (name = scanner.scan(TAG_NAME_RE))
            tag = name.downcase
            attributes, self_closing = scan_attributes(scanner)
            handle_starttag(tag, attributes)
            if self_closing
              handle_endtag(tag)
            elsif RAW_TEXT_TAGS.include?(tag)
              # Everything up to the matching close tag is code, not content.
              scanner.skip_until(/<\/#{tag}[[:space:]]*>/i) || scanner.terminate
              handle_endtag(tag)
            end
          else
            handle_data("<") # a stray "<" in text, e.g. "a < b"
          end
        end
      end

      # Attributes up to the closing ">", honouring quotes (a quoted value may
      # contain ">"). Returns [attributes, self_closing?].
      def scan_attributes(scanner)
        attributes = {}
        loop do
          scanner.skip(/[[:space:]]+/)
          return [attributes, false] if scanner.eos? || scanner.skip(/>/)
          return [attributes, true] if scanner.skip(%r{/[[:space:]]*>})
          if scanner.skip(%r{/})
            next
          end

          name = scanner.scan(ATTR_NAME_RE)
          unless name
            scanner.getch
            next
          end
          value = nil
          if scanner.skip(/[[:space:]]*=[[:space:]]*/)
            value =
              if scanner.skip(/"/)
                (scanner.scan_until(/"/) || scanner.rest.tap { scanner.terminate }).chomp('"')
              elsif scanner.skip(/'/)
                (scanner.scan_until(/'/) || scanner.rest.tap { scanner.terminate }).chomp("'")
              else
                scanner.scan(/[^>[:space:]]*/)
              end
          end
          attributes[name.downcase] = value && HtmlText.unescape(value)
        end
      end

      def handle_starttag(tag, attributes)
        if SKIP_TAGS.include?(tag)
          @skip_depth += 1
          return
        end
        # Markup inside <head> or <noscript> is not content either, and a hidden
        # block opened there must not leak past the skipped element's close.
        return if @skip_depth.positive?

        # Inline XBRL hides a parallel copy of every fact; keep it out of the text.
        style = attributes["style"].to_s.delete(" ").downcase
        hidden = tag == "ix:header" || style.include?("display:none")
        # Void tags never close, so they never open a block (hidden or not).
        unless VOID_TAGS.include?(tag)
          @stack << [tag, hidden]
          @hidden += 1 if hidden
        end
        return if @hidden.positive?

        @parts << "\n" if BLOCK_TAGS.include?(tag)
        @parts << "\n" if PARAGRAPH_TAGS.include?(tag)
      end

      def handle_endtag(tag)
        if SKIP_TAGS.include?(tag)
          @skip_depth -= 1 if @skip_depth.positive?
          return
        end
        return if @skip_depth.positive?

        index = @stack.rindex { |(name, _hidden)| name == tag }
        if index.nil?
          # A stray close tag with nothing to close still ends a block in a
          # browser's rendering ("Alpha</p>Beta" shows two paragraphs), so it
          # still earns its newline; otherwise two words glue together.
          @parts << "\n" if @hidden.zero? && (BLOCK_TAGS.include?(tag) || PARAGRAPH_TAGS.include?(tag))
          return
        end

        # Closing an element closes whatever is still open inside it, as a
        # browser would: an unclosed hidden <span> ends with its table cell
        # rather than hiding every page that follows. Any block closed that way
        # still ends with a newline.
        closed = @stack.pop(@stack.length - index)
        closed.each { |(_name, hidden)| @hidden -= 1 if hidden }
        return if @hidden.positive?

        @parts << "\n" if closed.any? { |(name, _hidden)| BLOCK_TAGS.include?(name) || PARAGRAPH_TAGS.include?(name) }
      end

      def handle_data(data)
        return if @skip_depth.positive? || @hidden.positive?

        data = HtmlText.unescape(data)
        if data.match?(/\A[[:space:]]*\z/)
          # A whitespace-only text node is still a separator: filings wrap
          # "<span>the</span><span> </span><span>FASB</span>", and dropping the
          # middle span glued the words ("theFASB"), which no search can find.
          @parts << " " unless data.empty? || @parts.empty? || @parts.last.end_with?(" ", "\n")
          return
        end

        @parts << data
      end
    end
  end
end
