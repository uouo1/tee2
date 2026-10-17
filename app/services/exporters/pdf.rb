# frozen_string_literal: true

require "pathname"
require "prawn"
require "prawn/table"

module Exporters
  # PDF export via Prawn (port of argos/exporters/pdf_export.py, reportlab).
  #
  # A print deliverable: one page per slide, landscape A4, with the football
  # field and the column charts drawn as vectors and every table rendered as a
  # real table. The flow per slide kind mirrors the reportlab story one flowable
  # at a time: paragraphs become `text`, spacers `move_down`, drawings a fixed
  # bounding box of primitives, tables prawn-table.
  #
  # `write(deck, path)` takes anything that responds to #title and #slides,
  # where each slide responds to #kind, #title, #subtitle and #payload_hash
  # (symbol keys, the Python payload shapes from Pitchbooks' slide builders).
  module Pdf
    # DejaVu Sans (a TrueType face with wide Unicode coverage) when the system
    # has it, so filing quotes keep their true minus signs, deltas and bullets;
    # otherwise Prawn's built-in Helvetica, whose Windows-1252 repertoire is
    # reached by transliteration (see `clean`). An audit found the appendix
    # quoting a filing with "?" where the filing had Δ and ◾.
    FONT_DIR = ENV.fetch("ARGOS_PDF_FONT_DIR", "/usr/share/fonts/truetype/dejavu")
    UNICODE_FONT = {
      normal: File.join(FONT_DIR, "DejaVuSans.ttf"),
      bold: File.join(FONT_DIR, "DejaVuSans-Bold.ttf"),
      italic: File.join(FONT_DIR, "DejaVuSans.ttf"),
      bold_italic: File.join(FONT_DIR, "DejaVuSans-Bold.ttf")
    }.freeze
    Prawn::Fonts::AFM.hide_m17n_warning = true

    LIGHT = Charts::PALETTE.fetch(:light)

    # Prawn takes colours as "RRGGBB" without the hash.
    def self.rgb(hex_colour) = hex_colour.to_s.delete_prefix("#").upcase

    SERIES_1 = rgb(LIGHT[:series_1])
    INK = rgb(LIGHT[:text])
    INK_SECONDARY = rgb(LIGHT[:text_secondary])
    MUTED = rgb(LIGHT[:muted])
    GRID = rgb(LIGHT[:grid])
    AXIS = rgb(LIGHT[:axis])
    SEQ = LIGHT[:seq].map { |step| rgb(step) }.freeze
    HIGHLIGHT = "EAF1FC"   # the target row in the comps table
    WHITE = "FFFFFF"
    # Shared with the PPTX writer so both files print the same sentences for
    # the audit's payload keys (stamp, implied value, comps footnotes, DCF build).
    W = Exporters::Pptx::Wording

    MM = 72.0 / 25.4
    # Prawn's "A4" is portrait [595.28, 841.89]; landscape swaps the pair.
    PAGE = [841.89, 595.28].freeze
    MARGIN_X = 15 * MM
    MARGIN_Y = 12 * MM
    CONTENT_WIDTH = PAGE[0] - 30 * MM
    CURRENCY_SYMBOLS = { "USD" => "$", "EUR" => "€", "GBP" => "£" }.freeze

    # reportlab paragraph styles as (fontSize, leading) where leading is the
    # baseline-to-baseline distance. Prawn's `leading` is the *extra* space
    # between lines on top of the font's own height, so `leading_for` converts
    # at draw time using the real metrics of the current font.
    STYLES = {
      title: { size: 26, line: 30, color: INK, space_after: 4 },
      heading: { size: 17, line: 21, color: INK, space_after: 2 },
      sub: { size: 9.5, line: 13, color: INK_SECONDARY, space_after: 10 },
      body: { size: 10, line: 14, color: INK },
      bullet: { size: 10, line: 14, color: INK, indent: 10, space_after: 5 },
      cite: { size: 7.5, line: 10, color: MUTED, indent: 10, space_after: 7 },
      footnote: { size: 7, line: 9, color: MUTED, space_after: 2 },
      note: { size: 8.5, line: 12, color: INK_SECONDARY, space_before: 6 },
      cell: { size: 7.5, line: 9.5, color: INK }
    }.freeze

    # Python format specs used by the column definitions, kept verbatim so the
    # tables below read like the reference: "{:,.0f}", "{:.1%}", "{:,.1f}x".
    FORMAT_SPEC = /\A\{:(?<comma>,)?(?:\.(?<decimals>\d+))?(?<kind>[f%])\}(?<suffix>.*)\z/

    # The built-in Helvetica face covers Windows-1252 only, and Prawn raises on
    # anything outside it. Payload text comes from filings and the research
    # corpus, which use a handful of characters beyond that set (the true minus
    # sign in "−1 to +1", non-breaking hyphens, thin spaces, arrows). Map the
    # common ones to their nearest glyph and replace the rest with "?" rather
    # than abort the export half way through a deck. Dashes, bullets, curly
    # quotes, the middle dot, € and £ are all in 1252 and pass through.
    TRANSLITERATIONS = {
      "−" => "-", "‐" => "-", "‑" => "-", " " => " ", " " => " ",
      "→" => "->", "≤" => "<=", "≥" => ">=", "≈" => "~", "­" => ""
    }.freeze
    TRANSLITERATION_RE = Regexp.union(TRANSLITERATIONS.keys)

    module_function

    # Write `deck` to `path` and return it as a Pathname.
    def write(deck, path)
      path = Pathname(path)
      path.dirname.mkpath
      build(deck).render_file(path.to_s)
      path
    end

    # Assemble the document without writing it (tests inspect page_count and
    # the rendered bytes).
    def build(deck)
      banker = deck.respond_to?(:banker) ? deck.banker : nil
      pdf = Prawn::Document.new(
        page_size: "A4", page_layout: :landscape,
        margin: [MARGIN_Y, MARGIN_X, MARGIN_Y, MARGIN_X],
        info: { Title: clean(deck.title.presence || "Pitch book"), Author: clean(banker.presence || "Argos"),
                Creator: "Argos" }
      )
      use_unicode_font(pdf)
      pdf.fill_color INK
      slides = deck.slides.to_a
      slides.each_with_index do |slide, index|
        slide_flow(pdf, slide)
        pdf.start_new_page if index < slides.size - 1
      end
      pdf
    end

    # ---------------------------------------------------------------- helpers

    def symbol_for(currency) = CURRENCY_SYMBOLS.fetch((currency.presence || "USD").to_s.upcase, "")

    # Python's `_fmt`: nil -> "n/a", no pattern -> as given, non-numeric -> as
    # given, otherwise the format spec applied. Thousands grouping follows the
    # comma flag and "%" multiplies by 100 exactly as str.format does.
    def fmt(value, pattern)
      return "n/a" if value.nil?
      return value.to_s if pattern.blank?

      number = begin
        Float(value)
      rescue ArgumentError, TypeError
        return value.to_s
      end
      spec = FORMAT_SPEC.match(pattern) or raise ArgumentError, "unsupported format #{pattern.inspect}"
      decimals = (spec[:decimals] || 6).to_i
      text = fixed(spec[:kind] == "%" ? number * 100 : number, decimals, grouping: !spec[:comma].nil?)
      text += "%" if spec[:kind] == "%"
      text + spec[:suffix]
    end

    # f"{value:,.{decimals}f}"
    def number(value, decimals) = fixed(value, decimals, grouping: true)

    # f"{value:.{decimals}f}", optionally with thousands separators.
    # Kernel#format rounds the shortest decimal rendering half-up (29.95 ->
    # "30.0"); Python's f-string rounds the exact binary value (-> "29.9"), as
    # Charts.fixed does, so the deck prints the same figure in every format.
    def fixed(value, decimals, grouping: false)
      text = Charts.fixed(value.to_f, decimals: decimals)
      return text unless grouping

      integer, fraction = text.split(".", 2)
      integer = integer.gsub(/(\d)(?=(\d{3})+\z)/, '\1,')
      fraction ? "#{integer}.#{fraction}" : integer
    end

    def unicode_font? = File.exist?(UNICODE_FONT[:normal]) && File.exist?(UNICODE_FONT[:bold])

    def use_unicode_font(pdf)
      return unless unicode_font?

      pdf.font_families.update("DejaVu" => UNICODE_FONT)
      pdf.font("DejaVu")
    end

    # Text the current font can draw. With the Unicode font, only characters
    # the face lacks become "?" (CJK, for one); soft hyphens are dropped. With
    # Helvetica, the Windows-1252 transliteration applies.
    def clean(text)
      return transliterate(text) unless unicode_font?

      text.to_s.delete("\u00AD").each_char.map { |ch| glyph?(ch) ? ch : "?" }.join
    end

    # Text that the built-in Helvetica face can encode (see TRANSLITERATIONS).
    def transliterate(text)
      text = text.to_s.gsub(TRANSLITERATION_RE, TRANSLITERATIONS)
      text.encode("Windows-1252", invalid: :replace, undef: :replace, replace: "?").encode("UTF-8")
    end

    # Glyph coverage of the Unicode font, probed once and memoised per character.
    def glyph?(char)
      return true if char.ord < 0x80

      @glyphs ||= {}
      @glyphs.fetch(char) do
        @probe ||= Prawn::Document.new.tap { |d| d.font_families.update("DejaVu" => UNICODE_FONT); d.font("DejaVu") }.font
        @glyphs[char] = @probe.respond_to?(:glyph_present?) ? @probe.glyph_present?(char) : true
      end
    end

    # Every paragraph is drawn with inline_format on so the few <b> runs below
    # work, which means payload text has to be escaped first: a title such as
    # "<script>alert(1)</script>" must print literally, not vanish into the
    # markup parser (the HTML exporter has the same test).
    def esc(text) = clean(text).gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

    def payload_of(slide) = (slide.payload_hash || {}).deep_symbolize_keys

    # Python truthiness for a numeric payload value: None and 0 are both "no price".
    def truthy_number?(value) = !value.nil? && value.to_f != 0

    def leading_for(pdf, style) = [style[:line] - pdf.font.height_at(style[:size]), 0].max

    # One reportlab Paragraph: `markup` is already escaped (may carry <b>).
    def paragraph(pdf, markup, style_name)
      style = STYLES.fetch(style_name)
      pdf.move_down(style[:space_before]) if style[:space_before]
      indent = style[:indent] || 0
      if indent.positive?
        pdf.bounding_box([indent, pdf.cursor], width: pdf.bounds.width - indent) do
          pdf.text(markup, size: style[:size], leading: leading_for(pdf, style), color: style[:color], inline_format: true)
        end
      else
        pdf.text(markup, size: style[:size], leading: leading_for(pdf, style), color: style[:color], inline_format: true)
      end
      pdf.move_down(style[:space_after]) if style[:space_after]
    end

    def spacer(pdf, height) = pdf.move_down(height)

    # Bullets are plain strings or {text:, source:} hashes; a source becomes a
    # small muted citation line under its bullet. The bullet glyph sits at the
    # left edge and the text at the style's indent, as reportlab's bulletText.
    def bullets(pdf, items)
      Array(items).each do |bullet|
        text = bullet.is_a?(Hash) ? bullet[:text].to_s : bullet.to_s
        style = STYLES[:bullet]
        pdf.text_box("•", at: [0, pdf.cursor], width: style[:indent], size: style[:size], color: style[:color])
        paragraph(pdf, esc(text), :bullet)
        source = bullet.is_a?(Hash) ? bullet[:source] : nil
        next if source.blank?

        paragraph(pdf, esc("Source: #{source[:title]} · #{source[:doc_type]} · #{source[:published_at]} " \
                           "[doc #{source[:document_id]}]"), :cite)
      end
    end

    # columns: [{key:, label:, numeric:, format:}]. Header bold with a rule
    # under it, hairlines between body rows, numeric columns right-aligned, and
    # a row whose highlight_key is truthy (the target in a comps table) tinted.
    def table(pdf, columns, rows, highlight_key: nil, col_widths: nil, weights: nil)
      style = STYLES[:cell]
      header = columns.map { |column| "<b>#{esc(column[:label])}</b>" }
      highlight_rows = []
      body = rows.each_with_index.map do |row, index|
        highlight_rows << index + 1 if highlight_key && row[highlight_key].present?
        columns.map do |column|
          value = row[column[:key]]
          esc(column[:format] ? fmt(value, column[:format]) : (value.nil? || value == false ? "" : value.to_s))
        end
      end
      if col_widths.nil? && weights
        total = weights.sum.to_f
        col_widths = weights.map { |weight| pdf.bounds.width * weight / total }
      end
      widths = col_widths || Array.new(columns.size, pdf.bounds.width / columns.size)
      pdf.table([header, *body], column_widths: widths, header: true,
                cell_style: { size: style[:size], leading: leading_for(pdf, style), text_color: style[:color],
                              inline_format: true, borders: [], padding: [3, 2, 3, 2], valign: :center }) do |t|
        t.row(0).borders = [:bottom]
        t.row(0).border_bottom_width = 0.6
        t.row(0).border_bottom_color = AXIS
        if body.size > 1
          t.rows(1..body.size - 1).borders = [:bottom]
          t.rows(1..body.size - 1).border_bottom_width = 0.25
          t.rows(1..body.size - 1).border_bottom_color = GRID
        end
        columns.each_with_index { |column, index| t.column(index).align = :right if column[:numeric] }
        highlight_rows.each { |row_index| t.row(row_index).background_color = HIGHLIGHT }
      end
    end

    # ------------------------------------------------------------- drawings

    # reportlab String with a textAnchor: Prawn's draw_text is start-anchored,
    # so middle/end anchors shift x by the measured width.
    def label(pdf, text, x, y, size:, color:, anchor: :start)
      text = clean(text).tr("\n", " ")
      width = pdf.width_of(text, size: size)
      x -= width / 2 if anchor == :middle
      x -= width if anchor == :end
      pdf.fill_color color
      pdf.draw_text(text, at: [x, y], size: size)
    end

    # reportlab Rect takes its bottom-left corner; Prawn's fill_rectangle the top-left.
    def bar(pdf, x, y, width, height, color: SERIES_1, opacity: 0.88)
      pdf.fill_color color
      pdf.transparent(opacity) { pdf.fill_rectangle([x, y + height], width, height) }
    end

    def hairline(pdf, x1, y1, x2, y2, color:, width:)
      pdf.stroke_color color
      pdf.line_width width
      pdf.stroke_line([x1, y1], [x2, y2])
    end

    # A fixed-height drawing area at the cursor, like a reportlab Drawing
    # flowable: it moves to a fresh page when it does not fit, and the cursor
    # ends up below it.
    def drawing(pdf, width, height)
      pdf.start_new_page if pdf.cursor < height && height <= pdf.bounds.height
      pdf.bounding_box([0, pdf.cursor], width: width, height: height) { yield }
      pdf.fill_color INK
      pdf.stroke_color INK
    end

    # A range that does not set the conclusion (reference only, or excluded on a
    # margin outlier) is drawn in the muted colour; the concluded range is a
    # faint band behind the bars, as in the HTML chart. A range without both
    # ends cannot be drawn and appears in the table only.
    def football_field(pdf, ranges, reference_price, currency, width: pdf.bounds.width, row_height: 20, concluded: nil)
      ranges = W.drawable_ranges(ranges)
      height = row_height * ranges.size + 34
      label_width = 150
      plot_left = label_width
      plot_width = width - label_width - 40
      reference = truthy_number?(reference_price) ? [reference_price.to_f] : []
      lows = ranges.map { |r| r[:low].to_f } + reference
      highs = ranges.map { |r| r[:high].to_f } + reference
      # Nothing to plot (no ranges, no price) still draws an empty axis rather
      # than failing on min([]) as the reference would.
      axis_min = lows.empty? ? 0.0 : lows.min * 0.92
      axis_max = highs.empty? ? 1.0 : highs.max * 1.06
      axis_max = axis_min + 1.0 if axis_max <= axis_min
      symbol = symbol_for(currency)
      x_of = ->(value) { plot_left + (value - axis_min) / (axis_max - axis_min) * plot_width }

      drawing(pdf, width, height) do
        5.times do |step|
          value = axis_min + (axis_max - axis_min) * step / 4
          x = x_of.call(value)
          hairline(pdf, x, 22, x, height - 6, color: GRID, width: 0.4)
          label(pdf, "#{symbol}#{number(value, 0)}", x, 10, size: 6.5, color: MUTED, anchor: :middle)
        end
        concluded ||= {}
        if ranges.any? && W.number?(concluded[:low]) && W.number?(concluded[:high])
          x1 = x_of.call(concluded[:low].to_f)
          x2 = x_of.call(concluded[:high].to_f)
          bar(pdf, x1, 22, [1.0, x2 - x1].max, row_height * ranges.size + 4, opacity: 0.07)
        end
        ranges.reverse.each_with_index do |row, index|
          y = 26 + index * row_height
          x1 = x_of.call(row[:low].to_f)
          x2 = x_of.call(row[:high].to_f)
          bar(pdf, x1, y, [1.5, x2 - x1 - 1.5].max, row_height - 8, color: W.muted_range?(row) ? MUTED : SERIES_1)
          label(pdf, row[:method].to_s[0, 44], label_width - 6, y + 3, size: 7.5, color: INK, anchor: :end)
          label(pdf, "#{symbol}#{number(row[:low], 0)}", x1 - 4, y + 3, size: 6.5, color: INK_SECONDARY, anchor: :end)
          label(pdf, "#{symbol}#{number(row[:high], 0)}", x2 + 3, y + 3, size: 6.5, color: INK_SECONDARY)
        end
        if reference.any?
          x = x_of.call(reference.first)
          hairline(pdf, x, 22, x, height - 2, color: INK, width: 1.2)
          label(pdf, "Current #{symbol}#{number(reference.first, 2)}", x, height - 1, size: 7, color: INK, anchor: :middle)
        end
      end
    end

    def column_drawing(pdf, labels, values, title: "", width: pdf.bounds.width / 2 - 6, height: 120,
                       value_format: "{:,.0f}")
      values = Array(values)
      plot_bottom = 20
      plot_top = height - 22
      plot_height = plot_top - plot_bottom
      top_value = (values.map { |v| (v || 0).to_f } + [1.0]).max * 1.15
      slot = (width - 10) / [1, values.size].max
      bar_w = [4.0, slot - 6].max

      drawing(pdf, width, height) do
        label(pdf, title, 0, height - 8, size: 8, color: INK_SECONDARY) if title.present?
        hairline(pdf, 0, plot_bottom, width, plot_bottom, color: AXIS, width: 0.5)
        values.each_with_index do |value, index|
          x = 5 + index * slot + (slot - bar_w) / 2
          label(pdf, labels[index].to_s, x + bar_w / 2, plot_bottom - 9, size: 6.5, color: MUTED, anchor: :middle)
          # A missing value is a gap labelled n/a, not a zero bar.
          if value.nil?
            label(pdf, "n/a", x + bar_w / 2, plot_bottom + 3, size: 6.5, color: MUTED, anchor: :middle)
            next
          end
          bar_h = [0.8, value.to_f / top_value * plot_height].max
          bar(pdf, x, plot_bottom, bar_w, bar_h)
          # Selective direct labels: first and last bar only.
          next unless index.zero? || index == values.size - 1

          label(pdf, fmt(value.to_f, value_format), x + bar_w / 2, plot_bottom + bar_h + 3,
                size: 6.5, color: INK_SECONDARY, anchor: :middle)
        end
      end
    end

    # The sensitivity grid as a table whose cells are tinted on the sequential
    # ramp (7 steps, light = low); text flips to white on the darker half.
    def heatmap_table(pdf, payload)
      style = STYLES[:cell]
      grid = Array(payload[:grid])
      wacc_axis = Array(payload[:wacc_axis])
      terminal_axis = Array(payload[:terminal_axis])
      flat = grid.flatten.compact.map(&:to_f)
      low, high = flat.empty? ? [0.0, 1.0] : [flat.min, flat.max]
      span = (high - low).zero? ? 1.0 : high - low
      header = ["<b>Terminal growth \\ WACC</b>"] + wacc_axis.map { |w| "<b>#{fixed(w.to_f * 100, 2)}%</b>" }
      shaded = []   # [row, col, step]
      body = terminal_axis.zip(grid).each_with_index.map do |(growth, row), row_index|
        next if row.nil?

        cells = ["<b>#{fixed(growth.to_f * 100, 2)}%</b>"]
        Array(row).each_with_index do |value, col_index|
          cells << (value.nil? ? "n/a" : number(value, 2))
          next if value.nil?

          step = ((value.to_f - low) / span * 6).to_i.clamp(0, 6)
          shaded << [row_index + 1, col_index + 1, step]
        end
        cells
      end.compact
      widths = [pdf.bounds.width * 0.2] + Array.new(wacc_axis.size, pdf.bounds.width * 0.8 / [1, wacc_axis.size].max)
      pdf.table([header, *body], column_widths: widths,
                cell_style: { size: style[:size], leading: leading_for(pdf, style), text_color: style[:color],
                              inline_format: true, borders: [], padding: [4, 2, 4, 2], valign: :center }) do |t|
        t.columns(1..-1).align = :center if wacc_axis.any?
        t.row(0).borders = [:bottom]
        t.row(0).border_bottom_width = 0.6
        t.row(0).border_bottom_color = AXIS
        if body.any? && wacc_axis.any?
          # White 1.2pt grid between the value cells: the gaps between fills.
          value_cells = t.cells.filter { |cell| cell.row >= 1 && cell.column >= 1 }
          value_cells.borders = %i[top bottom left right]
          value_cells.border_width = 1.2
          value_cells.border_color = WHITE
        end
        shaded.each do |row_index, col_index, step|
          cell = t.cells[row_index, col_index]
          next if cell.nil?

          cell.background_color = SEQ[step]
          cell.text_color = WHITE if step >= 3
        end
      end
    end

    # ------------------------------------------------------------ slides

    def heading(pdf, slide)
      paragraph(pdf, esc(slide.title), :heading)
      paragraph(pdf, esc(slide.subtitle), :sub) if slide.subtitle.present?
    end

    def note(pdf, text)
      paragraph(pdf, esc(text), :note) if text.present?
    end

    def footnotes(pdf, lines)
      lines = Array(lines).map(&:to_s).reject(&:blank?)
      return if lines.empty?

      spacer(pdf, 4)
      lines.each { |line| paragraph(pdf, esc(line), :footnote) }
    end

    # Label/value rows as a two-column table (the DCF bridge, the WACC build).
    def pairs(pdf, rows, header: nil)
      return if rows.empty?

      table(pdf, [{ key: :label, label: header || "" }, { key: :value, label: "", numeric: true }],
            rows.map { |label_text, value| { label: label_text, value: value } },
            col_widths: [pdf.bounds.width * 0.62, pdf.bounds.width * 0.38])
    end

    def slide_flow(pdf, slide)
      kind = slide.kind.to_s
      payload = payload_of(slide)
      currency = payload[:currency].presence || "USD"

      if kind == "cover"
        spacer(pdf, 48 * MM)
        paragraph(pdf, "CONFIDENTIAL — DISCUSSION MATERIALS", :sub)
        paragraph(pdf, esc(slide.title), :title)
        paragraph(pdf, esc(slide.subtitle), :sub) if slide.subtitle.present?
        meta = [
          (payload[:client_name].present? ? "Prepared for #{payload[:client_name]}" : nil),
          payload[:target], payload[:ticker], payload[:banker], payload[:date]
        ].select(&:present?).map(&:to_s).join(" · ")
        paragraph(pdf, esc(meta), :sub)
        # Item 22: the stamp as a footer line at the foot of the cover.
        stamp = W.stamp_line(payload[:stamp])
        pdf.text_box(esc(stamp), at: [0, 14], width: pdf.bounds.width, size: 8, color: MUTED, inline_format: true) if stamp
        return
      end

      heading(pdf, slide)

      case kind
      when "disclaimer"
        paragraph(pdf, esc(payload[:body]), :body)
      when "executive_summary", "process"
        reference = payload[:reference_range] || {}
        if reference.present?
          # Item 16 wording; an unbridged range says so instead of $0.00.
          paragraph(pdf, "<b>#{esc(W.implied_value_line(payload))}</b>", :body)
          spacer(pdf, 6)
        end
        bullets(pdf, payload[:bullets])
      when "company_overview"
        paragraph(pdf, esc(payload[:description]), :body)
        spacer(pdf, 8)
        table(pdf, [{ key: :label, label: "Metric" }, { key: :value, label: "Value", numeric: true }],
              Array(payload[:kpis]), col_widths: [pdf.bounds.width * 0.35, pdf.bounds.width * 0.25])
        if payload[:extracted_kpis].present?
          extracted = payload[:extracted_kpis].map do |k|
            "#{k[:label]} #{k[:value]} (#{k[:observations]} obs.#{k[:period].present? ? ", latest #{W.date(k[:period])}" : ''})"
          end
          note(pdf, "Metrics extracted from the corpus: #{extracted.join(', ')}")
        end
        footnotes(pdf, [W.overview_footnote(payload)])
      when "market_overview"
        paragraph(pdf, esc(payload[:narrative]), :body)
        spacer(pdf, 8)
        timeline = Array(payload[:sentiment_timeline])
        if timeline.any?
          # Tone is rebased +1 so a bar chart (which needs a zero baseline) can
          # show a [-1, 1] score. An unscored month is labelled n/a rather than
          # drawn as neutral (the Python's `or 0`).
          column_drawing(pdf, timeline.map { |row| row[:month].to_s[-5..] || row[:month].to_s },
                         timeline.map { |row| row[:sentiment].nil? ? nil : row[:sentiment].to_f + 1 },
                         title: "Mean document tone by month (rebased +1)", width: pdf.bounds.width, height: 110,
                         value_format: "{:,.2f}")
        end
        table(pdf, [
          { key: :theme, label: "Emerging theme" },
          { key: :mentions, label: "Recent", numeric: true, format: "{:,.0f}" },
          { key: :prior_mentions, label: "Prior", numeric: true, format: "{:,.0f}" },
          { key: :lift, label: "Lift", numeric: true, format: "{:,.2f}x" }
        ], Array(payload[:themes]).first(8))
      when "financial_performance"
        rows = Array(payload[:rows])
        column_drawing(pdf, rows.map { |r| "FY#{r[:fiscal_year]}" }, rows.map { |r| r[:revenue] },
                       title: "Revenue (#{currency}m)", width: pdf.bounds.width, height: 120)
        # The LTM row joins the table only (it would print twice on the axis).
        ltm = payload[:ltm].presence
        table_rows = ltm ? rows + [ltm.merge(fiscal_year: ltm[:basis].presence || "LTM")] : rows
        spacer(pdf, 6)
        # The reference formats the year column with "{:,.0f}", which prints
        # "2,020"; years are not amounts, so no grouping here (same on the DCF slide).
        table(pdf, [
          { key: :fiscal_year, label: "FY", format: "{:.0f}" },
          { key: :revenue, label: "Revenue", numeric: true, format: "{:,.0f}" },
          { key: :ebitda, label: "EBITDA", numeric: true, format: "{:,.0f}" },
          { key: :ebitda_margin, label: "Margin", numeric: true, format: "{:.1%}" },
          { key: :ebit, label: "EBIT", numeric: true, format: "{:,.0f}" },
          { key: :net_income, label: "Net income", numeric: true, format: "{:,.0f}" },
          { key: :eps, label: "EPS", numeric: true, format: "{:,.2f}" },
          { key: :capex, label: "Capex", numeric: true, format: "{:,.0f}" }
        ], table_rows)
        note(pdf, payload[:note])
      when "valuation_summary"
        ranges = Array(payload[:ranges])
        football_field(pdf, ranges, payload[:reference_price], currency, concluded: payload[:concluded_range])
        spacer(pdf, 8)
        w = pdf.bounds.width
        columns = [
          { key: :method, label: "Methodology" },
          { key: :low, label: "Low", numeric: true, format: "{:,.2f}" },
          { key: :high, label: "High", numeric: true, format: "{:,.2f}" },
          { key: :mid, label: "Midpoint", numeric: true, format: "{:,.2f}" },
          { key: :basis, label: "Basis" }
        ]
        widths = [w * 0.26, w * 0.1, w * 0.1, w * 0.12, w * 0.42]
        if W.flagged_ranges?(ranges)
          # Which ranges set the conclusion (items 14 and 16).
          columns << { key: :status, label: "In conclusion" }
          ranges = ranges.map { |r| r.merge(status: W.status_label(r)) }
          widths = [w * 0.24, w * 0.08, w * 0.08, w * 0.09, w * 0.39, w * 0.12]
        end
        table(pdf, columns, ranges, col_widths: widths)
        if payload.key?(:concluded_range) || payload.key?(:methods)
          paragraph(pdf, "<b>#{esc(W.conclusion_sentence(payload))}</b>", :note)
        end
        notes = W.range_notes(ranges)
        notes.unshift("Multiples on #{payload[:basis_label]}.") if payload[:basis_label].present?
        footnotes(pdf, notes)
      when "trading_comps"
        rows = W.comps_rows(payload)
        columns = [
          { key: :ticker, label: "Ticker" },
          { key: :name, label: "Company" }
        ]
        # Item 17: each row names its period; item 12: NTM beside trailing.
        columns << { key: :basis, label: "Basis" } if W.comps_basis?(payload)
        columns += [
          { key: :share_price, label: "Price", numeric: true, format: "{:,.2f}" },
          { key: :market_cap, label: "Mkt cap", numeric: true, format: "{:,.0f}" },
          { key: :enterprise_value, label: "EV", numeric: true, format: "{:,.0f}" },
          { key: :revenue, label: "Revenue", numeric: true, format: "{:,.0f}" },
          { key: :ebitda_margin, label: "Margin", numeric: true, format: "{:.1%}" },
          { key: :ev_revenue, label: "EV/Rev", numeric: true, format: "{:,.1f}x" },
          { key: :ev_ebitda, label: "EV/EBITDA", numeric: true, format: "{:,.1f}x" }
        ]
        columns << { key: :ev_ebitda_ntm_text, label: "EV/NTM EBITDA", numeric: true, format: "{:,.1f}x" } if payload[:has_ntm]
        columns << { key: :pe, label: "P/E", numeric: true, format: "{:,.1f}x" }
        columns << { key: :pe_ntm, label: "NTM P/E", numeric: true, format: "{:,.1f}x" } if payload[:has_ntm]
        columns << { key: :share_basis, label: "Shares" } if W.comps_share_basis?(payload)
        rows = rows.map { |row| row.merge(ev_ebitda_ntm_text: W.ntm_cell(row, :ev_ebitda_ntm)) } if payload[:has_ntm]
        weights = columns.size > 10 ? columns.map { |c| { name: 2.2, basis: 1.2, share_basis: 1.3 }.fetch(c[:key], 1.0) } : nil
        table(pdf, columns, rows, highlight_key: :is_target, weights: weights)
        stats = payload[:stats] || {}
        labels = payload[:labels] || {}
        metrics = [[:ev_revenue, "EV / Revenue"], [:ev_ebitda, "EV / EBITDA"], [:pe, "P / E"]]
        metrics += [[:ev_ebitda_ntm, "EV / NTM EBITDA"], [:pe_ntm, "NTM P / E"]] if payload[:has_ntm]
        stat_rows = metrics.map do |metric, label|
          distribution = stats[metric] || {}
          { multiple: labels[metric].presence || label, **%i[min p25 median p75 max].to_h { |key| [key, distribution[key]] } }
        end
        spacer(pdf, 8)
        table(pdf, [
          { key: :multiple, label: "Peer distribution" },
          { key: :min, label: "Min", numeric: true, format: "{:,.1f}x" },
          { key: :p25, label: "25th", numeric: true, format: "{:,.1f}x" },
          { key: :median, label: "Median", numeric: true, format: "{:,.1f}x" },
          { key: :p75, label: "75th", numeric: true, format: "{:,.1f}x" },
          { key: :max, label: "Max", numeric: true, format: "{:,.1f}x" }
        ], stat_rows)
        footnotes(pdf, W.comps_footnotes(payload))
      when "precedent_transactions"
        table(pdf, [
          { key: :announced_on, label: "Announced" },
          { key: :target, label: "Target" },
          { key: :acquirer, label: "Acquirer" },
          { key: :ev, label: "EV", numeric: true, format: "{:,.0f}" },
          { key: :ev_revenue, label: "EV/Rev", numeric: true, format: "{:,.1f}x" },
          { key: :ev_ebitda, label: "EV/EBITDA", numeric: true, format: "{:,.1f}x" },
          { key: :premium_1day, label: "Premium", numeric: true, format: "{:.0%}" },
          { key: :consideration, label: "Consideration" }
        ], Array(payload[:rows]))
        note(pdf, payload[:note])
      when "dcf"
        projections = Array(payload[:projections])
        extended = W.extended_dcf?(payload)
        column_drawing(pdf, projections.map { |p| p[:year].to_s }, projections.map { |p| p[:fcf] },
                       title: "Unlevered free cash flow (#{currency}m)", width: pdf.bounds.width, height: extended ? 92 : 110)
        spacer(pdf, 6)
        columns = W.dcf_columns(payload)
        weights = columns.map { |c| c[:key] == :year ? 1.6 : 1.0 }
        table(pdf, columns, W.dcf_table_rows(payload), highlight_key: :is_terminal, weights: weights)
        if extended
          # Item 18: the bridge with its cross-checks and the WACC build, side by side.
          spacer(pdf, 8)
          bridge = W.dcf_bridge_rows(payload)
          build = W.wacc_rows(payload[:wacc_build])
          half = (pdf.bounds.width - 18) / 2
          needed = [bridge.size, build.size + 1].max * 13 + 10
          pdf.start_new_page if pdf.cursor < needed && needed <= pdf.bounds.height
          top = pdf.cursor
          pdf.bounding_box([0, top], width: half) do
            pairs(pdf, bridge, header: "Value bridge (#{currency})")
          end
          bottom_left = pdf.cursor
          if build.any?
            pdf.bounding_box([half + 18, top], width: half) do
              pairs(pdf, build, header: "WACC build")
            end
          end
          pdf.move_cursor_to([bottom_left, pdf.cursor].min)
          footnotes(pdf, W.dcf_notes(payload))
        else
          note(pdf, payload[:note])
        end
      when "dcf_sensitivity"
        heatmap_table(pdf, payload)
        # A missing price says "not loaded", never $0.00.
        note(pdf, W.sensitivity_note(payload))
      when "buyers"
        w = pdf.bounds.width
        table(pdf, [
          { key: :name, label: "Counterparty" },
          { key: :type, label: "Type" },
          { key: :enterprise_value, label: "EV (#{currency}m)", numeric: true, format: "{:,.0f}" },
          { key: :relative_size, label: "EV vs target", numeric: true, format: "{:,.2f}x" },
          { key: :rationale, label: "Rationale" }
        ], Array(payload[:candidates]), col_widths: [w * 0.2, w * 0.1, w * 0.1, w * 0.12, w * 0.48])
        footnotes(pdf, ["Enterprise values and multiples on #{payload[:basis_label]}."]) if payload[:basis_label].present?
      when "evidence_appendix"
        items = Array(payload[:items])
        paragraph(pdf, "No evidence pinned yet.", :body) if items.empty?
        items.each do |item|
          source = [item[:ticker], item[:title], item[:doc_type], item[:published_at]].select(&:present?).map(&:to_s).join(" · ")
          quote = esc("“#{item[:quote]}”")
          cite = esc("#{source} [doc #{item[:document_id]}]")
          # KeepTogether: a quote and its citation never split across pages.
          needed = pdf.height_of(quote, size: STYLES[:body][:size]) +
                   pdf.height_of(cite, size: STYLES[:cite][:size], width: pdf.bounds.width - STYLES[:cite][:indent]) +
                   STYLES[:cite][:space_after] + 4
          pdf.start_new_page if pdf.cursor < needed && needed <= pdf.bounds.height
          paragraph(pdf, quote, :body)
          paragraph(pdf, cite, :cite)
        end
      else
        bullets(pdf, payload[:bullets])
      end
    end
  end
end
