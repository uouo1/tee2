# frozen_string_literal: true

require "pathname"
require "zip"

module Exporters
  # PowerPoint export.
  #
  # Charts are native PowerPoint charts, not pictures, so a banker can
  # double-click a comps bar and retype a number at 11pm without coming back to
  # the application. The football field uses the stacked-bar trick (an invisible
  # base series carrying the low value, a visible series carrying the span),
  # which is how the chart is built by hand anyway.
  #
  # There is no PPTX gem: the deck is written as OOXML parts (Package, SlideXml,
  # ChartXml, Xml) and zipped with rubyzip, reproducing the structure python-pptx
  # emits — text boxes, table and chart graphic frames, chart parts with string
  # and number caches, and a minimal embedded workbook behind each chart.
  #
  # `write(deck, path)` takes anything that responds to #title and #slides,
  # where each slide responds to #kind, #title, #subtitle and #payload_hash
  # (symbol keys, the Python payload shapes from Pitchbooks' slide builders).
  module Pptx
    LIGHT = Charts::PALETTE.fetch(:light)

    # python-pptx's RGBColor.from_string(hex.lstrip("#").upper()).
    def self.rgb(hex_colour) = hex_colour.to_s.delete_prefix("#").upcase

    SERIES_1 = rgb(LIGHT[:series_1])
    INK = rgb(LIGHT[:text])
    INK_SECONDARY = rgb(LIGHT[:text_secondary])
    MUTED = rgb(LIGHT[:muted])
    AXIS = rgb(LIGHT[:axis])
    GRID = rgb(LIGHT[:grid])
    SEQ = LIGHT[:seq].map { |step| rgb(step) }.freeze
    WHITE = "FFFFFF"
    W = Wording

    # Scheme colours for the theme part, so built-in styles stay on palette.
    THEME_COLORS = {
      dk1: INK, lt1: WHITE, dk2: INK_SECONDARY, lt2: rgb(LIGHT[:plane]),
      accent1: SERIES_1, accent2: rgb(LIGHT[:series_2]), accent3: rgb(LIGHT[:series_3]),
      accent4: rgb(LIGHT[:series_4]), accent5: rgb(LIGHT[:series_5]), accent6: rgb(LIGHT[:series_6]),
      hlink: SERIES_1, folHlink: MUTED
    }.freeze

    EMU_PER_INCH = 914_400
    # python-pptx's Inches() truncates, so 13.333in is 12191695 EMU, not ...696.
    def self.inches(value) = (value * EMU_PER_INCH).to_i

    SLIDE_W = inches(13.333)
    SLIDE_H = inches(7.5)
    MARGIN = inches(0.62)
    CONTENT_TOP = inches(1.45)
    CONTENT_W = SLIDE_W - MARGIN * 2
    CONTENT_H = SLIDE_H - CONTENT_TOP - inches(0.5)

    CURRENCY_SYMBOLS = { "USD" => "$", "EUR" => "€", "GBP" => "£" }.freeze

    # Python format specs used by the column definitions, kept verbatim so the
    # tables below read like the reference: "{:,.0f}", "{:.1%}", "{:,.1f}x".
    FORMAT_SPEC = /\A\{:(?<comma>,)?(?:\.(?<decimals>\d+))?(?<kind>[f%])\}(?<suffix>.*)\z/

    WRITERS = {
      "cover" => :slide_cover,
      "disclaimer" => :slide_text,
      "executive_summary" => :slide_executive_summary,
      "company_overview" => :slide_company_overview,
      "market_overview" => :slide_market_overview,
      "financial_performance" => :slide_financials,
      "valuation_summary" => :slide_valuation_summary,
      "trading_comps" => :slide_trading_comps,
      "precedent_transactions" => :slide_precedents,
      "dcf" => :slide_dcf,
      "dcf_sensitivity" => :slide_sensitivity,
      "buyers" => :slide_buyers,
      "process" => :slide_text,
      "evidence_appendix" => :slide_evidence
    }.freeze

    module_function

    # Write `deck` to `path` and return it as a Pathname.
    def write(deck, path)
      path = Pathname(path)
      path.dirname.mkpath
      build(deck).save(path)
      path
    end

    # Assemble the package without writing it (tests inspect the parts).
    def build(deck)
      package = Package.new(title: deck.title, theme_colors: THEME_COLORS)
      deck.slides.each do |slide|
        send(WRITERS.fetch(slide.kind.to_s, :slide_text), package, slide)
      end
      package
    end

    # ---------------------------------------------------------------- helpers

    def symbol_for(currency) = CURRENCY_SYMBOLS.fetch((currency.presence || "USD").to_s.upcase, "")

    # Python's `_fmt`: nil -> "n/a", non-numeric -> as given, otherwise the
    # format spec applied. Thousands grouping follows the comma flag and "%"
    # multiplies by 100 exactly as str.format does.
    def fmt(value, pattern = "{:,.0f}")
      return "n/a" if value.nil?

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

    def payload_of(slide) = (slide.payload_hash || {}).deep_symbolize_keys

    # Python truthiness for a numeric payload value: None and 0 are both "no price".
    def truthy_number?(value) = !value.nil? && value.to_f != 0

    # ------------------------------------------------------ shape primitives

    def heading(page, title, subtitle = nil)
      paragraphs = [{ text: title, size: 26, bold: true, color: INK }]
      paragraphs << { text: subtitle, size: 12.5, color: INK_SECONDARY } if subtitle.present?
      page.text_box(MARGIN, inches(0.42), CONTENT_W, inches(0.9), paragraphs, wrap: true)
      page.rectangle(MARGIN, inches(1.33), CONTENT_W, 9525, fill: AXIS)
    end

    # Bullets are plain strings or {text:, source:} hashes; a source becomes a
    # small muted citation line under its bullet.
    def bullets(page, items, top: CONTENT_TOP, height: CONTENT_H, width: CONTENT_W)
      paragraphs = []
      items.each do |bullet|
        text = bullet.is_a?(Hash) ? bullet[:text].to_s : bullet.to_s
        source = bullet.is_a?(Hash) ? bullet[:source] : nil
        paragraphs << { text: "•  #{text}", size: 14, color: INK, space_after: 7 }
        next if source.blank?

        paragraphs << {
          text: "     Source: #{source[:title]} · #{source[:doc_type]} · #{source[:published_at]} [doc #{source[:document_id]}]",
          size: 9.5, color: MUTED, space_after: 8
        }
      end
      page.text_box(MARGIN, top, width, height, paragraphs, wrap: true)
    end

    # columns: [{key:, label:, numeric:, format:}]; the header is bold and
    # secondary, numeric columns right-aligned, and a row whose highlight_key
    # is truthy (the target in a comps table) is set in bold. `weights` gives
    # relative column widths (a company name needs more room than a multiple);
    # without it the columns split the width equally, as in the Python.
    def table(page, columns, rows, top: CONTENT_TOP, height: nil, width: CONTENT_W, left: MARGIN,
              highlight_key: nil, font_size: 9.5, row_height: inches(0.3), weights: nil)
      row_count = rows.size + 1
      height ||= [CONTENT_H, row_height * row_count].min
      header = columns.map do |column|
        { text: column[:label].to_s, size: font_size, bold: true, color: INK_SECONDARY,
          align: column[:numeric] ? "r" : nil }
      end
      body = rows.map do |row|
        highlighted = highlight_key ? row[highlight_key].present? : false
        columns.map do |column|
          value = row[column[:key]]
          text = column[:format] ? fmt(value, column[:format]) : (python_falsy?(value) ? "" : value.to_s)
          { text: text, size: font_size, bold: highlighted, color: INK, align: column[:numeric] ? "r" : nil }
        end
      end
      page.table(left, top, width, height, [header, *body], col_widths: column_widths(width, weights))
      height # so the caller can place what follows
    end

    def column_widths(width, weights)
      return nil if weights.blank?

      total = weights.sum.to_f
      weights.map { |weight| (width * weight / total).to_i }
    end

    # A label/value table without a header (the DCF bridge, the WACC build).
    def pairs_table(page, rows, left:, top:, width:, row_height:, size: 11, header: nil)
      cells = rows.map do |label, value|
        [{ text: label.to_s, size: size, bold: false, color: INK_SECONDARY },
         { text: value.to_s, size: size, bold: true, color: INK, align: "r" }]
      end
      if header
        cells.unshift([{ text: header, size: size, bold: true, color: INK_SECONDARY },
                       { text: "", size: size }])
      end
      return 0 if cells.empty?

      page.table(left, top, width, row_height * cells.size, cells)
      row_height * cells.size
    end

    # Small muted lines (footnotes, sources) in one text box.
    def footnotes(page, lines, top:, left: MARGIN, width: CONTENT_W, size: 9)
      lines = Array(lines).map(&:to_s).reject(&:blank?)
      return if lines.empty?

      page.text_box(left, top, width, inches(0.3) * lines.size,
                    lines.map { |line| { text: line, size: size, color: MUTED, space_after: 2 } }, wrap: true)
    end

    # An unformatted cell is `str(row.get(key, "") or "")` in the Python, so
    # anything falsy there — None, False, 0, "", an empty list or dict — prints
    # as an empty cell rather than "0" or "false". Formatted cells go through
    # `fmt`, where only nil is special.
    def python_falsy?(value)
      value.nil? || value == false || value == 0 || (value.respond_to?(:empty?) && value.empty?)
    end

    def note(page, text, top:)
      return if text.blank?

      page.text_box(MARGIN, top, CONTENT_W, inches(0.8), [{ text: text, size: 11, color: INK_SECONDARY }], wrap: true)
    end

    def chart_options = { axis_color: AXIS, label_color: MUTED, grid_color: GRID }

    def add_column_chart(page, categories, values, left: MARGIN, top: CONTENT_TOP, width: CONTENT_W,
                         height: inches(3.1), series_name: "Value", number_format: "#,##0")
      chart = ChartXml.new(
        kind: :column, categories: categories, gap_width: 60, **chart_options,
        # A missing value is a gap in the chart, not a zero-height bar (a nil
        # never renders as 0).
        series: [{ name: series_name, values: values.map { |v| v.nil? ? nil : v.to_f }, number_format: number_format, fill: SERIES_1 }]
      )
      page.chart(left, top, width, height, chart)
    end

    def add_line_chart(page, categories, values, left: MARGIN, top: CONTENT_TOP, width: CONTENT_W,
                       height: inches(3.0), series_name: "Value", number_format: "0.0%")
      chart = ChartXml.new(
        kind: :line, categories: categories, **chart_options,
        series: [{ name: series_name, values: values, number_format: number_format, fill: SERIES_1 }]
      )
      page.chart(left, top, width, height, chart)
    end

    # Floating bars via a transparent base series plus a visible span series.
    # Categories are reversed because a horizontal bar chart draws the first
    # category at the bottom, and the deck lists methods top-down.
    #
    # A range that does not set the conclusion (the 52-week range, shown for
    # reference only, or a revenue multiple excluded on a margin outlier) keeps
    # its place in the span series but is recoloured muted with a data-point
    # override, so the chart stays the two-series construction a banker edits.
    # A range without both ends cannot float and is left off the chart.
    # `extra` lines (the conclusion, bases, notes) follow the detail line.
    def add_football_field(page, ranges, reference_price:, currency:, top: CONTENT_TOP, height: inches(3.5),
                           price_date: nil, extra: [])
      drawable = W.drawable_ranges(ranges)
      ordered = drawable.reverse
      muted = ordered.each_index.select { |index| W.muted_range?(ordered[index]) }.to_h { |index| [index, MUTED] }
      chart = ChartXml.new(
        kind: :bar_stacked, categories: ordered.map { |r| r[:method].to_s }, overlap: 100, **chart_options,
        series: [
          { name: "Base", values: ordered.map { |r| r[:low].to_f }, number_format: "#,##0.00", fill: :none },
          { name: "Range", values: ordered.map { |r| r[:high].to_f - r[:low].to_f }, number_format: "#,##0.00", fill: SERIES_1,
            point_fills: muted }
        ]
      )
      page.chart(MARGIN, top, CONTENT_W, height, chart)
      symbol = symbol_for(currency)
      detail = ranges.map do |r|
        span = W.number?(r[:low]) && W.number?(r[:high]) ? "#{symbol}#{number(r[:low], 2)}–#{symbol}#{number(r[:high], 2)}" : "n/a"
        status = W.range_status(r)
        "#{r[:method]}: #{span}#{status ? " (#{status})" : ''}"
      end.join("; ")
      reference = ""
      if truthy_number?(reference_price)
        reference = "Current share price: #{symbol}#{number(reference_price, 2)}#{price_date.present? ? " as of #{W.date(price_date)}" : ''}. "
      end
      paragraphs = [{ text: "#{reference}#{detail}", size: 11, color: INK_SECONDARY }]
      Array(extra).each do |line|
        paragraphs << (line.is_a?(Hash) ? line : { text: line.to_s, size: 11, color: INK_SECONDARY })
      end
      page.text_box(MARGIN, top + height, CONTENT_W, inches(0.8), paragraphs, wrap: true)
    end

    # The sensitivity grid as a table whose cells are shaded on the sequential
    # ramp: seven steps from the minimum to the maximum value, white text once
    # the fill is dark enough (step 3 and up) to keep the numbers legible.
    def add_heatmap_table(page, payload)
      grid = payload[:grid] || []
      wacc_axis = payload[:wacc_axis] || []
      terminal_axis = payload[:terminal_axis] || []
      flat = grid.flatten.compact.map(&:to_f)
      low, high = flat.empty? ? [0.0, 1.0] : [flat.min, flat.max]
      span = (high - low).zero? ? 1.0 : high - low
      header = [{ text: "Terminal growth \\ WACC", size: 9, color: INK_SECONDARY }]
      wacc_axis.each do |wacc|
        header << { text: "#{fixed(wacc.to_f * 100, 2)}%", size: 10, bold: true, color: INK_SECONDARY, align: "ctr" }
      end
      cells = [header]
      terminal_axis.zip(grid).each do |growth, row|
        break if row.nil? # zip() in the Python stops at the shorter axis

        line = [{ text: "#{fixed(growth.to_f * 100, 2)}%", size: 10, color: INK_SECONDARY }]
        row.each do |value|
          if value.nil?
            line << { text: "n/a", size: 10, align: "ctr" }
          else
            step = [[((value.to_f - low) / span * 6).to_i, 0].max, 6].min
            line << { text: number(value, 2), size: 10, align: "ctr", fill: SEQ[step], color: step >= 3 ? WHITE : INK }
          end
        end
        cells << line
      end
      page.table(MARGIN, CONTENT_TOP, CONTENT_W, inches(0.36) * (grid.size + 1), cells)
    end

    # ---------------------------------------------------------- slide writers

    def slide_cover(package, slide)
      page = package.add_slide
      payload = payload_of(slide)
      paragraphs = [
        { text: "CONFIDENTIAL — DISCUSSION MATERIALS", size: 11, color: MUTED },
        { text: slide.title.to_s, size: 40, bold: true, color: INK }
      ]
      paragraphs << { text: slide.subtitle, size: 16, color: INK_SECONDARY } if slide.subtitle.present?
      meta = [
        payload[:client_name].present? ? "Prepared for #{payload[:client_name]}" : nil,
        payload[:target], payload[:ticker], payload[:banker], payload[:date]
      ].select(&:present?).map(&:to_s).join(" · ")
      paragraphs << { text: meta, size: 12, color: MUTED }
      page.text_box(MARGIN, inches(2.2), CONTENT_W, inches(3.0), paragraphs, wrap: true)
      # Item 22: the stamp as a footer line, so a deck mailed around for a week
      # still says which data and which code produced it.
      stamp = W.stamp_line(payload[:stamp])
      page.text_box(MARGIN, inches(6.75), CONTENT_W, inches(0.4), [{ text: stamp, size: 10, color: MUTED }], wrap: true) if stamp
    end

    # Disclaimer, process and any unknown kind: bullets when present, else body.
    def slide_text(package, slide)
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      payload = payload_of(slide)
      if payload[:bullets].present?
        bullets(page, payload[:bullets])
      else
        bullets(page, [payload[:body].to_s])
      end
    end

    def slide_executive_summary(package, slide)
      page = package.add_slide
      payload = payload_of(slide)
      heading(page, slide.title.to_s, slide.subtitle)
      reference = payload[:reference_range].presence || {}
      if reference.present?
        # Item 16: implied value, not "upside" or a "reference range"; a range
        # that could not be bridged says so instead of printing $0.00.
        page.text_box(MARGIN, inches(1.4), CONTENT_W, inches(0.5),
                      [{ text: W.implied_value_line(payload), size: 13, bold: true, color: SERIES_1 }], wrap: false)
      end
      bullets(page, payload[:bullets] || [], top: inches(2.0), height: inches(4.9))
    end

    def slide_company_overview(package, slide)
      page = package.add_slide
      payload = payload_of(slide)
      heading(page, slide.title.to_s, slide.subtitle)
      paragraphs = [{ text: payload[:description].to_s, size: 12.5, color: INK }]
      extracted = payload[:extracted_kpis] || []
      if extracted.present?
        paragraphs << { text: "\nMetrics extracted from the corpus", size: 11, bold: true, color: INK_SECONDARY }
        extracted.each do |kpi|
          latest = kpi[:period].present? ? ", latest #{W.date(kpi[:period])}" : ""
          paragraphs << { text: "•  #{kpi[:label]}: #{kpi[:value]} (#{kpi[:observations]} observations#{latest})", size: 11, color: INK }
        end
      end
      page.text_box(MARGIN, CONTENT_TOP, inches(6.4), inches(4.4), paragraphs, wrap: true)
      footnotes(page, [W.overview_footnote(payload)], top: inches(6.55))
      rows = (payload[:kpis] || []).map { |kpi| [kpi[:label].to_s, kpi[:value].to_s] }
      return if rows.empty? # a zero-row table is not valid DrawingML

      cells = rows.map do |label, value|
        [{ text: label, size: 10.5, color: INK_SECONDARY, bold: false },
         { text: value, size: 10.5, color: INK, bold: true, align: "r" }]
      end
      page.table(inches(7.3), CONTENT_TOP, inches(5.4), inches(0.33) * rows.size, cells)
    end

    def slide_market_overview(package, slide)
      payload = payload_of(slide)
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      page.text_box(MARGIN, inches(1.4), CONTENT_W, inches(0.9), [{ text: payload[:narrative].to_s, size: 12, color: INK }], wrap: true)
      timeline = payload[:sentiment_timeline] || []
      if timeline.present?
        # A month without a scored document is a gap in the line, not a
        # neutral 0 (the Python's `or 0`): nil never renders as zero.
        add_line_chart(
          page, timeline.map { |row| row[:month] }, timeline.map { |row| row[:sentiment].nil? ? nil : row[:sentiment].to_f },
          left: MARGIN, top: inches(2.35), width: inches(6.0), height: inches(2.9),
          series_name: "Mean tone", number_format: "0.00"
        )
      end
      themes = payload[:themes] || []
      return if themes.blank?

      table(
        page,
        [
          { key: :theme, label: "Emerging theme" },
          { key: :mentions, label: "Recent", numeric: true, format: "{:,.0f}" },
          { key: :prior_mentions, label: "Prior", numeric: true, format: "{:,.0f}" },
          { key: :lift, label: "Lift", numeric: true, format: "{:,.2f}x" }
        ],
        themes.first(8), top: inches(2.35), width: inches(5.7), left: inches(7.0)
      )
    end

    def slide_financials(package, slide)
      payload = payload_of(slide)
      rows = payload[:rows] || []
      currency = payload[:currency] || "USD"
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      categories = rows.map { |r| "FY#{r[:fiscal_year]}" }
      # The LTM row travels apart from the fiscal years (it would print twice on
      # the axis) and joins the table only, labelled with its basis.
      ltm = payload[:ltm].presence
      table_rows = ltm ? rows + [ltm.merge(fiscal_year: ltm[:basis].presence || "LTM")] : rows
      add_column_chart(
        page, categories, rows.map { |r| r[:revenue] },
        left: MARGIN, top: CONTENT_TOP, width: inches(6.0), height: inches(2.9),
        series_name: "Revenue (#{currency}m)"
      )
      add_line_chart(
        page, categories, rows.map { |r| r[:ebitda_margin] },
        left: inches(7.0), top: CONTENT_TOP, width: inches(5.7), height: inches(2.9),
        series_name: "EBITDA margin"
      )
      table(
        page,
        [
          # Years are not money: no thousands separator (the Python's "{:,.0f}" printed "2,020").
          { key: :fiscal_year, label: "FY", format: "{:.0f}" },
          { key: :revenue, label: "Revenue", numeric: true, format: "{:,.0f}" },
          { key: :ebitda, label: "EBITDA", numeric: true, format: "{:,.0f}" },
          { key: :ebitda_margin, label: "Margin", numeric: true, format: "{:.1%}" },
          { key: :ebit, label: "EBIT", numeric: true, format: "{:,.0f}" },
          { key: :net_income, label: "Net income", numeric: true, format: "{:,.0f}" },
          { key: :eps, label: "EPS", numeric: true, format: "{:,.2f}" },
          { key: :capex, label: "Capex", numeric: true, format: "{:,.0f}" }
        ],
        table_rows, top: inches(4.6), row_height: ltm ? inches(0.27) : inches(0.3)
      )
      note(page, payload[:note].to_s, top: inches(6.9))
    end

    def slide_valuation_summary(package, slide)
      payload = payload_of(slide)
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      ranges = payload[:ranges] || []
      extra = []
      # The conclusion and the methods that set it (item 16), the basis of each
      # range (item 17) and why a range is excluded (item 14) follow the detail
      # line. A payload without a concluded range (a deck built before the
      # audit) keeps the Python note only.
      if payload.key?(:concluded_range) || payload.key?(:methods)
        extra << { text: W.conclusion_sentence(payload), size: 11, bold: true, color: INK }
      end
      bases = ranges.select { |r| r[:basis].present? }.map { |r| "#{r[:method]}: #{r[:basis]}" }
      if bases.any? && W.flagged_ranges?(ranges)
        label = payload[:basis_label].present? ? "Bases (multiples on #{payload[:basis_label]}) — " : "Bases — "
        extra << { text: "#{label}#{bases.join('; ')}", size: 9, color: MUTED }
      end
      W.range_notes(ranges).each { |line| extra << { text: line, size: 9, color: MUTED } }
      add_football_field(
        page, ranges,
        reference_price: payload[:reference_price],
        currency: payload[:currency] || "USD",
        top: CONTENT_TOP, height: inches(3.9),
        price_date: payload[:price_date], extra: extra
      )
    end

    def slide_trading_comps(package, slide)
      payload = payload_of(slide)
      currency = payload[:currency] || "USD"
      rows = W.comps_rows(payload)
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      columns = [
        { key: :ticker, label: "Ticker" },
        { key: :name, label: "Company" }
      ]
      # Item 17: every row names the period its multiples are on.
      columns << { key: :basis, label: "Basis" } if W.comps_basis?(payload)
      columns += [
        { key: :share_price, label: "Price", numeric: true, format: "{:,.2f}" },
        { key: :market_cap, label: "Mkt cap (#{currency}m)", numeric: true, format: "{:,.0f}" },
        { key: :enterprise_value, label: "EV (#{currency}m)", numeric: true, format: "{:,.0f}" },
        { key: :revenue, label: "Revenue", numeric: true, format: "{:,.0f}" },
        { key: :ebitda_margin, label: "EBITDA margin", numeric: true, format: "{:.1%}" },
        { key: :ev_revenue, label: "EV/Rev", numeric: true, format: "{:,.1f}x" },
        { key: :ev_ebitda, label: "EV/EBITDA", numeric: true, format: "{:,.1f}x" }
      ]
      # Item 12: the NTM multiples sit beside the trailing ones they lead.
      columns << { key: :ev_ebitda_ntm_text, label: "EV/NTM EBITDA", numeric: true, format: "{:,.1f}x" } if payload[:has_ntm]
      columns << { key: :pe, label: "P/E", numeric: true, format: "{:,.1f}x" }
      columns << { key: :pe_ntm, label: "NTM P/E", numeric: true, format: "{:,.1f}x" } if payload[:has_ntm]
      columns << { key: :share_basis, label: "Shares" } if W.comps_share_basis?(payload)
      rows = rows.map { |row| row.merge(ev_ebitda_ntm_text: W.ntm_cell(row, :ev_ebitda_ntm)) } if payload[:has_ntm]
      extended = columns.size > 10
      weights = columns.map { |c| { name: 2.2, basis: 1.2, share_basis: 1.3, market_cap: 1.2, enterprise_value: 1.1 }.fetch(c[:key], 1.0) }
      comps_height = table(
        page, columns, rows, top: CONTENT_TOP, highlight_key: :is_target,
        font_size: extended ? 8.0 : 9.5, row_height: extended ? inches(0.27) : inches(0.3),
        weights: extended ? weights : nil
      )

      stats = payload[:stats] || {}
      labels = payload[:labels] || {}
      metrics = [[:ev_revenue, "EV / Revenue"], [:ev_ebitda, "EV / EBITDA"], [:pe, "P / E"]]
      metrics += [[:ev_ebitda_ntm, "EV / NTM EBITDA"], [:pe_ntm, "NTM P / E"]] if payload[:has_ntm]
      stat_rows = metrics.map do |metric, label|
        distribution = stats[metric] || {}
        { multiple: labels[metric].presence || label, **distribution.slice(:min, :p25, :median, :p75, :max) }
      end
      notes = W.comps_footnotes(payload)
      # The Python placed the distribution at 5.35in; with the item-17
      # footnotes to fit as well, it follows the comps table instead.
      distribution_top = notes.empty? ? inches(5.35) : CONTENT_TOP + comps_height + inches(0.12)
      distribution_height = table(
        page,
        [
          { key: :multiple, label: "Peer distribution" },
          { key: :min, label: "Min", numeric: true, format: "{:,.1f}x" },
          { key: :p25, label: "25th", numeric: true, format: "{:,.1f}x" },
          { key: :median, label: "Median", numeric: true, format: "{:,.1f}x" },
          { key: :p75, label: "75th", numeric: true, format: "{:,.1f}x" },
          { key: :max, label: "Max", numeric: true, format: "{:,.1f}x" }
        ],
        stat_rows, top: distribution_top, font_size: extended ? 8.5 : 9.5, row_height: extended ? inches(0.25) : inches(0.3)
      )
      footnotes(page, notes, top: distribution_top + distribution_height + inches(0.08), size: 8.5)
    end

    def slide_precedents(package, slide)
      payload = payload_of(slide)
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      table(
        page,
        [
          { key: :announced_on, label: "Announced" },
          { key: :target, label: "Target" },
          { key: :acquirer, label: "Acquirer" },
          { key: :ev, label: "EV (USDm)", numeric: true, format: "{:,.0f}" },
          { key: :ev_revenue, label: "EV/Rev", numeric: true, format: "{:,.1f}x" },
          { key: :ev_ebitda, label: "EV/EBITDA", numeric: true, format: "{:,.1f}x" },
          { key: :premium_1day, label: "Premium", numeric: true, format: "{:.0%}" },
          { key: :consideration, label: "Consideration" }
        ],
        payload[:rows] || [], top: CONTENT_TOP
      )
      note(page, payload[:note].to_s, top: inches(5.6))
    end

    def slide_dcf(package, slide)
      payload = payload_of(slide)
      projections = payload[:projections] || []
      currency = payload[:currency] || "USD"
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      build_rows = W.wacc_rows(payload[:wacc_build])
      bridge = W.dcf_bridge_rows(payload)
      columns = W.dcf_columns(payload)
      rows = W.dcf_table_rows(payload)
      unless W.extended_dcf?(payload)
        # The Python layout: chart and bridge side by side, projections below.
        add_column_chart(
          page, projections.map { |p| p[:year].to_s }, projections.map { |p| p[:fcf] },
          left: MARGIN, top: CONTENT_TOP, width: inches(5.9), height: inches(2.8),
          series_name: "Unlevered FCF (#{currency}m)"
        )
        pairs_table(page, bridge, left: inches(7.0), top: CONTENT_TOP, width: inches(5.7), row_height: inches(0.33))
        table(page, columns, rows, top: inches(4.6))
        note(page, payload[:note].to_s, top: inches(6.6))
        return
      end

      # Item 18: chart, bridge with the cross-checks and the WACC build across
      # the top; the projections with D&A, ΔNWC and the terminal year below;
      # the stub, WACC and cross-check notes underneath.
      with_build = build_rows.any?
      chart_w = with_build ? inches(3.9) : inches(5.9)
      add_column_chart(
        page, projections.map { |p| p[:year].to_s }, projections.map { |p| p[:fcf] },
        left: MARGIN, top: CONTENT_TOP, width: chart_w, height: inches(2.45),
        series_name: "Unlevered FCF (#{currency}m)"
      )
      bridge_left = with_build ? inches(4.75) : inches(7.0)
      bridge_w = with_build ? inches(3.95) : inches(5.7)
      heights = [pairs_table(page, bridge, left: bridge_left, top: CONTENT_TOP, width: bridge_w, row_height: inches(0.26), size: 10)]
      if with_build
        heights << pairs_table(page, build_rows, left: inches(8.9), top: CONTENT_TOP, width: SLIDE_W - MARGIN - inches(8.9),
                                                 row_height: inches(0.245), size: 9.5, header: "WACC build")
      end
      table_top = CONTENT_TOP + [inches(2.45), *heights].max + inches(0.15)
      weights = columns.map { |c| c[:key] == :year ? 1.6 : 1.0 }
      table_height = table(page, columns, rows, top: table_top, font_size: 8.5, row_height: inches(0.25),
                                                highlight_key: :is_terminal, weights: weights)
      footnotes(page, W.dcf_notes(payload), top: table_top + table_height + inches(0.08), size: 8.5)
    end

    def slide_sensitivity(package, slide)
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      payload = payload_of(slide)
      add_heatmap_table(page, payload)
      # A missing price says "not loaded" (Python HEAD), never $0.00.
      note(page, W.sensitivity_note(payload), top: inches(5.0))
    end

    def slide_buyers(package, slide)
      payload = payload_of(slide)
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      currency = payload[:currency].presence || "USD"
      table(
        page,
        [
          { key: :name, label: "Counterparty" },
          { key: :type, label: "Type" },
          { key: :enterprise_value, label: "EV (#{currency}m)", numeric: true, format: "{:,.0f}" },
          { key: :relative_size, label: "EV vs target", numeric: true, format: "{:,.2f}x" },
          { key: :rationale, label: "Rationale" }
        ],
        payload[:candidates] || [], top: CONTENT_TOP, font_size: 9.0
      )
      footnotes(page, ["Enterprise values and multiples on #{payload[:basis_label]}."], top: inches(6.75)) if payload[:basis_label].present?
    end

    def slide_evidence(package, slide)
      items = payload_of(slide)[:items] || []
      page = package.add_slide
      heading(page, slide.title.to_s, slide.subtitle)
      if items.empty?
        bullets(page, ["No evidence pinned. Pin passages from the research module to build this appendix."])
        return
      end
      list = items.map do |item|
        source = [item[:ticker], item[:title], item[:published_at]].select(&:present?).map(&:to_s).join(" · ")
        {
          text: "“#{item[:quote]}”",
          source: { title: source, doc_type: item[:doc_type].to_s, published_at: "", document_id: item[:document_id] }
        }
      end
      bullets(page, list)
    end
  end
end
