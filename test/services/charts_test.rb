# frozen_string_literal: true

require "test_helper"

# Port of tests/test_charts.py (AxisTests, RenderTests, PaletteTests) plus the
# rules the contract spells out: tokens not hex, 2px gaps, rounded data ends,
# selective labels, legends for two or more series, the heatmap classes, the
# table alignment/highlight markup, Proc value formats and css_tokens.
class ChartsTest < ActiveSupport::TestCase
  RANGES = [
    { method: "Trading comps", low: 30.0, high: 45.0, mid: 37.5, basis: "12x–18x" },
    { method: "DCF", low: 28.0, high: 50.0, mid: 39.0, basis: "WACC 9.9%" }
  ].freeze

  HEX = /#[0-9a-f]{6}/i

  # ---------------------------------------------------------------- axis

  test "ticks stay readable on narrow ranges" do
    # The axis of a chart spanning three percentage points must not produce
    # dozens of gridlines (a real bug this guards against).
    ticks = Charts.nice_ticks(20.3, 23.3, 4)
    assert_operator ticks.size, :<=, 6
    assert_operator ticks.size, :>=, 3
    assert_equal ticks.sort, ticks
    assert_operator ticks.first, :<=, 20.3
    # Gridlines need not reach the very top of the data, but they must span
    # most of it rather than clustering at the bottom.
    assert_operator ticks.last - ticks.first, :>, (23.3 - 20.3) * 0.6
  end

  test "ticks on small counts" do
    assert_operator Charts.nice_ticks(0, 2.2, 4).size, :<=, 5
  end

  test "degenerate range" do
    assert_equal [5], Charts.nice_ticks(5, 5)
    assert_equal [5], Charts.nice_ticks(5, 4)
    # The caller's own value comes back untouched, Integer or Float.
    assert_kind_of Integer, Charts.nice_ticks(5, 5).first
    assert_kind_of Float, Charts.nice_ticks(5.5, 5.5).first
  end

  test "tick count is bounded" do
    assert_operator Charts.nice_ticks(0, 10**9, 5).size, :<=, 24
  end

  test "tick step is a nice multiple of the log10 magnitude" do
    # raw step 112.5 -> magnitude 100 -> first factor at or above it is 2.
    assert_equal [0, 200, 400], Charts.nice_ticks(0, 450, 5)
    # raw step 0.25 -> magnitude 0.1 -> factor 2.5.
    assert_equal [0.0, 0.25, 0.5, 0.75, 1.0], Charts.nice_ticks(0, 1, 5)
    # Negative lows start on a rounded-down tick.
    assert_equal [-0.5, 0.0, 0.5], Charts.nice_ticks(-0.36, 0.52, 4)
    # Ticks are rounded to six places so accumulated float error never shows.
    Charts.nice_ticks(0.1, 0.9, 9).each { |tick| assert_equal tick, tick.round(6) }
    # Whole-number steps yield Integers, as the reference's int arithmetic did,
    # so a format that prints the raw tick shows "200" rather than "200.0";
    # a fractional step (or the 2.5 factor) yields Floats.
    assert Charts.nice_ticks(0, 450, 5).all?(Integer)
    assert Charts.nice_ticks(20.3, 23.3, 4).all?(Integer)
    assert Charts.nice_ticks(-50, 50, 3).all?(Integer)
    assert Charts.nice_ticks(0, 1, 5).all?(Float)
    assert Charts.nice_ticks(0, 10**9, 5).all?(Float)
    assert_equal [0, 250_000_000.0, 500_000_000.0, 750_000_000.0, 1_000_000_000.0], Charts.nice_ticks(0, 10**9, 5)
    # Integer bounds never fall into integer division when computing the step.
    assert_equal [0, 100, 200, 300, 400, 500], Charts.nice_ticks(0, 450, 6)
    # A raw-tick format sees the same text the Python format string produced.
    raw = ->(v) { "#{v}x" }
    assert_includes Charts.column_chart_svg(%w[a b], [100, 400], value_format: raw), ">200x</text>"
  end

  # -------------------------------------------------------------- rendering

  test "football field structure" do
    svg = Charts.football_field_svg(RANGES, reference_price: 44.1, concluded: { low: 30, high: 46 })
    assert svg.start_with?("<svg")
    assert_includes svg, "</svg>"
    assert_includes svg, 'role="img"'
    # One bar per methodology, each with a tooltip, plus the reference rule.
    assert_equal RANGES.size, svg.scan("<title>").size - 1
    assert_includes svg, "Current"
  end

  test "football field details" do
    svg = Charts.football_field_svg(RANGES, reference_price: 44.1, concluded: { low: 30, high: 46 })
    # Accessible name and description, then the concluded band as a faint wash.
    assert_includes svg, 'aria-label="Valuation summary — implied value per share"'
    assert_includes svg, "<desc>Range of implied value per share by valuation methodology.</desc>"
    assert_includes svg, 'opacity="0.07"'
    # Direct labels at both ends of every bar and a tooltip with the basis.
    assert_includes svg, ">$30</text>"
    assert_includes svg, ">$45</text>"
    assert_includes svg, "<title>Trading comps: $30.00 – $45.00 · 12x–18x</title>"
    assert_includes svg, "Current $44.10"
    # Rounded data ends.
    assert_includes svg, %(rx="#{Charts::BAR_RADIUS}")

    plain = Charts.football_field_svg(RANGES, currency_symbol: "€")
    refute_includes plain, "Current"
    refute_includes plain, 'opacity="0.07"'
    assert_includes plain, ">€30</text>"
    # A zero reference price is "absent", as in the reference implementation.
    refute_includes Charts.football_field_svg(RANGES, reference_price: 0), "Current"
  end

  test "football field bars keep the gap between adjacent fills" do
    svg = Charts.football_field_svg([{ method: "DCF", low: 10.0, high: 20.0 }])
    rect = svg[/<rect[^>]*rx=/]
    x1 = rect[/x="([\d.]+)"/, 1].to_f
    width = rect[/width="([\d.]+)"/, 1].to_f
    # 20 is itself an axis tick, so its gridline marks exactly where the high
    # value lands; the bar stops GAP short of it.
    tick_x = svg[/<text x="([\d.]+)"[^>]*>\$20<\/text>/, 1].to_f
    assert_in_delta tick_x - Charts::GAP, x1 + width, 0.11
    # The high-value label is anchored 8px past the bar's actual end.
    label_x = svg[/<text x="([\d.]+)" y="[\d.]+" font-size="11" fill="var\(--text-secondary\)"/, 1].to_f
    assert_in_delta x1 + width + 8, label_x, 0.11
    assert_equal 2, Charts::GAP
  end

  test "charts use tokens not literal hex" do
    svg = Charts.football_field_svg(RANGES, reference_price: 44.1)
    assert_includes svg, "var(--series-1)"
    refute_includes svg, "#2a78d6"
  end

  test "no chart emits a literal colour" do
    outputs = [
      Charts.football_field_svg(RANGES, reference_price: 44.1, concluded: { low: 30, high: 46 }),
      Charts.column_chart_svg(%w[a b c], [1, 2, 3], title: "t", estimate_from: 2),
      Charts.line_chart_svg(%w[a b c], [1.0, 2.0, 3.0], title: "t"),
      Charts.diverging_bar_svg(%w[a b], [0.4, -0.3], title: "t"),
      Charts.stacked_bar_svg(%w[a b], [{ name: "x", values: [1, 2] }, { name: "y", values: [2, 1] }], title: "t"),
      Charts.heatmap_html([[1.0, 2.0]], row_labels: %w[r], column_labels: %w[c d]),
      Charts.table_html([{ key: :a, label: "A" }], [{ a: 1 }])
    ]
    outputs.each do |markup|
      refute_match HEX, markup
      refute_includes markup, "rgba("
    end
    # Colour, gridline, axis and text roles are all custom properties.
    svg = outputs[1]
    %w[--series-1 --grid --axis --muted --text-secondary].each { |token| assert_includes svg, "var(#{token})" }
    assert_includes outputs[2], "var(--surface-1)"
  end

  test "empty inputs degrade gracefully" do
    assert_includes Charts.football_field_svg([]), "viz-empty"
    assert_includes Charts.column_chart_svg([], []), "viz-empty"
    assert_includes Charts.line_chart_svg(["a"], [1]), "viz-empty"
    assert_includes Charts.stacked_bar_svg([], []), "viz-empty"
    assert_includes Charts.diverging_bar_svg([], []), "viz-empty"
    assert_includes Charts.heatmap_html([[nil, nil]], row_labels: ["a"], column_labels: %w[x y]), "viz-empty"
    # One real point is not a trend.
    assert_includes Charts.line_chart_svg(%w[a b c], [nil, 2.0, nil]), "viz-empty"
    # Series without labels, or labels without series, are no data.
    assert_includes Charts.stacked_bar_svg([], [{ name: "x", values: [] }]), "viz-empty"
  end

  test "labels are escaped" do
    svg = Charts.column_chart_svg(["<script>"], [1.0])
    refute_includes svg, "<script>"
    assert_includes svg, "&lt;script&gt;"
  end

  test "every label position is escaped in every chart" do
    hostile = %(<img src=x onerror="alert('x')">)
    safe = "&lt;img src=x onerror=&quot;alert(&#39;x&#39;)&quot;&gt;"
    outputs = [
      Charts.football_field_svg([{ method: hostile, low: 1.0, high: 2.0, basis: hostile }]),
      Charts.column_chart_svg([hostile], [1.0], title: hostile),
      Charts.line_chart_svg([hostile, hostile], [1.0, 2.0], title: hostile),
      Charts.diverging_bar_svg([hostile], [0.2], title: hostile),
      Charts.stacked_bar_svg([hostile], [{ name: hostile, values: [1] }], title: hostile),
      Charts.heatmap_html([[1.0]], row_labels: [hostile], column_labels: [hostile], row_title: hostile, column_title: hostile),
      Charts.table_html([{ key: :a, label: hostile }], [{ a: hostile }], caption: hostile)
    ]
    outputs.each do |markup|
      refute_includes markup, hostile
      assert_includes markup, safe
    end
    # An html_safe string is still escaped: this module is the last stop before markup.
    assert_includes Charts.column_chart_svg([hostile.html_safe], [1.0]), safe
  end

  test "stacked series never cycle colours" do
    series = (0...9).map { |i| { name: "s#{i}", values: [1, 2] } }
    svg = Charts.stacked_bar_svg(%w[a b], series)
    used = svg.scan(/var\(--series-(\d)\)/).flatten.uniq
    assert_operator used.size, :<=, Charts::MAX_SERIES
    # Fixed slot order: the first series is always slot 1, and extras are
    # dropped rather than wrapped back to slot 1.
    assert_equal 6, Charts::MAX_SERIES
    assert_equal %w[1 2 3 4 5 6], used.sort
    refute_includes svg, ">s6</text>"
  end

  test "stacked bars keep the gap between segments and always carry a legend" do
    series = [{ name: "filing", values: [10] }, { name: "news", values: [10] }]
    svg = Charts.stacked_bar_svg(["24-01"], series)
    # Totals 20 -> headroom 22 -> ticks [0, 10, 20] -> axis top stays 22;
    # plot height without a title is 230 - 12 - 52 = 166.
    expected = format("%.1f", 10.0 / 22 * 166 - Charts::GAP)
    assert_equal 2, svg.scan(%(height="#{expected}")).size
    assert_includes svg, "var(--series-1)"
    assert_includes svg, "var(--series-2)"
    # Legend entries for every series, in slot order.
    assert_operator svg.index(">filing</text>"), :<, svg.index(">news</text>")
    assert_includes svg, "<title>24-01 · filing: 10</title>"
    # Zero or missing values draw no segment.
    sparse = Charts.stacked_bar_svg(%w[a b], [{ name: "x", values: [0, nil] }])
    assert_equal 0, sparse.scan(/<rect[^>]*opacity="0.9"/).size
  end

  test "diverging bars use both poles" do
    svg = Charts.diverging_bar_svg(%w[a b], [0.4, -0.3])
    assert_includes svg, "var(--diverging-pos)"
    assert_includes svg, "var(--diverging-neg)"
  end

  test "diverging bars have a neutral midline, signed labels and a two-entry legend" do
    svg = Charts.diverging_bar_svg(%w[a b c], [0.4, -0.3, 0.0], title: "Tone")
    assert_includes svg, 'stroke="var(--axis)"'
    assert_includes svg, ">+0.00</text>"
    assert_includes svg, "<title>a: +0.40</title>"
    assert_includes svg, "<title>b: -0.30</title>"
    assert_includes svg, "Positive tone"
    assert_includes svg, "Negative tone"
    # Zero sits on the positive side (non-negative) with a hairline bar.
    assert_includes svg, %(height="1.0" rx="2" fill="var(--diverging-pos)")
    # The axis never collapses below ±0.05, so a tiny series still reads.
    tiny = Charts.diverging_bar_svg(%w[a], [0.01])
    assert_includes tiny, ">+0.03</text>"
  end

  test "column chart marks estimates and shows a legend only when they exist" do
    labels = %w[FY2021 FY2022 FY2023 FY2024E]
    svg = Charts.column_chart_svg(labels, [100, 120, 130, 150], title: "Revenue", estimate_from: 3)
    assert_includes svg, "<title>FY2024E: 150 (estimate)</title>"
    assert_includes svg, 'opacity="0.55"'
    assert_includes svg, ">Actual</text>"
    assert_includes svg, ">Estimate</text>"
    assert_equal 4, svg.scan(%(rx="#{Charts::BAR_RADIUS}")).size
    plain = Charts.column_chart_svg(labels, [100, 120, 130, 150])
    refute_includes plain, ">Estimate</text>"
    refute_includes plain, "(estimate)"
    # estimate_from past the end marks nothing and draws no legend.
    refute_includes Charts.column_chart_svg(labels, [1, 2, 3, 4], estimate_from: 9), ">Estimate</text>"
  end

  test "column chart labels selectively" do
    value_label = /text-anchor="middle" fill="var\(--text-secondary\)"/
    # label_every: every third bar plus the last one -> indices 0, 3, 5.
    svg = Charts.column_chart_svg((0...6).map(&:to_s), [1, 2, 3, 4, 5, 6], label_every: 3)
    assert_equal 3, svg.scan(value_label).size
    # Default labels every bar.
    assert_equal 6, Charts.column_chart_svg((0...6).map(&:to_s), [1, 2, 3, 4, 5, 6]).scan(value_label).size
    # A highlight labels the highlighted bar and the last bar only, and dims the rest.
    highlighted = Charts.column_chart_svg(%w[NVG HLDX ACME], [17.5, 12.1, 9.0], highlight_index: 0)
    assert_equal 2, highlighted.scan(value_label).size
    assert_equal 2, highlighted.scan('opacity="0.42"').size
    assert_equal 1, highlighted.scan('opacity="0.9"').size
    # Category labels always, under every bar.
    assert_equal 3, highlighted.scan(/fill="var\(--muted\)">(NVG|HLDX|ACME)</).size
  end

  test "column chart handles an all-zero series" do
    svg = Charts.column_chart_svg(%w[a b], [0, 0])
    assert_includes svg, "<svg"
    assert_includes svg, ">1</text>"       # axis falls back to a unit scale
    assert_equal 2, svg.scan(%(height="1.0" rx)).size   # hairline bars, never zero height
  end

  test "line chart skips gaps and labels the endpoint" do
    svg = Charts.line_chart_svg(%w[FY2021 FY2022 FY2023 FY2024], [20.3, nil, 22.1, 23.3], title: "EBITDA margin (%)")
    assert_equal 3, svg.scan("<circle").size
    assert_equal 1, svg.scan(/\bM[\d.]+,[\d.]+/).size
    assert_equal 2, svg.scan(/\bL[\d.]+,[\d.]+/).size
    assert_includes svg, 'stroke-width="2" stroke-linejoin="round"'
    assert_includes svg, "<title>FY2024: 23.3%</title>"
    assert_includes svg, 'fill="var(--text-primary)" style="font-variant-numeric:tabular-nums">23.3%</text>'
    # Narrow range: a handful of gridlines, not dozens.
    assert_operator svg.scan('stroke="var(--grid)"').size, :<=, 6
    # Flat series still renders (span falls back to |high|, then 1).
    assert_includes Charts.line_chart_svg(%w[a b c], [5, 5, 5]), "<path"
    assert_includes Charts.line_chart_svg(%w[a b], [0, 0]), "<path"
    # Many labels are thinned to about seven.
    many = Charts.line_chart_svg((0...20).map { |i| "m#{i}" }, (0...20).map { |i| (i % 7).to_f })
    assert_equal 10, many.scan(/>m\d+</).size
  end

  test "value formats are procs with the python defaults" do
    assert_equal "1,235", Charts::INTEGER_FORMAT.call(1234.6)
    assert_equal "-1,234.50", Charts::DECIMAL_FORMAT.call(-1234.5)
    assert_equal "12.3%", Charts::PERCENT_FORMAT.call(12.345)
    assert_equal "+0.40", Charts::SIGNED_FORMAT.call(0.4)
    assert_equal "-0.30", Charts::SIGNED_FORMAT.call(-0.3)
    assert_equal "1,234,568", Charts.number(1234567.891)
    assert_equal "0", Charts.number(0)
    assert_equal "17.5x", "#{Charts.number(17.5, decimals: 1)}x"
    # Rounding matches printf/Python: exact ties to even, near-ties by the true binary value.
    assert_equal "1,234", Charts.number(1234.5)
    assert_equal "0.12", Charts.fixed(0.125, decimals: 2)
    assert_equal "0.03", Charts.fixed(0.025, decimals: 2)
    assert_equal "44.13", Charts.fixed(44.135, decimals: 2)
    assert_equal "-0.00", Charts.fixed(-0.004, decimals: 2)
    assert_equal "+5", Charts.fixed(5, sign: true)
    assert_raises(TypeError) { Charts.number(nil) }

    custom = ->(v) { "~#{v}" }
    assert_includes Charts.column_chart_svg(%w[a], [7], value_format: custom), "<title>a: ~7</title>"
    assert_includes Charts.line_chart_svg(%w[a b], [1, 2], value_format: custom), "<title>b: ~2</title>"
    assert_includes Charts.diverging_bar_svg(%w[a], [0.5], value_format: custom), "<title>a: ~0.5</title>"
    assert_includes Charts.heatmap_html([[3.0]], row_labels: %w[r], column_labels: %w[c], value_format: custom), ">~3.0</td>"
  end

  test "heatmap marks reference and handles gaps" do
    html = Charts.heatmap_html(
      [[10.0, nil], [12.0, 14.0]],
      row_labels: %w[a b], column_labels: %w[x y], reference: 12.0
    )
    assert_includes html, "heat-na"
    assert_includes html, "heat-ref"
  end

  test "heatmap ramps from heat-1 to heat-7 with labelled axes" do
    html = Charts.heatmap_html([[10, 20, 30]], row_labels: ["2.00%"], column_labels: ["8%", "9%", "10%"],
                                                row_title: "Terminal growth", column_title: "WACC")
    assert_includes html, '<td class="heat heat-1">10.00</td>'
    assert_includes html, '<td class="heat heat-4">20.00</td>'
    assert_includes html, '<td class="heat heat-7">30.00</td>'
    assert_includes html, "Terminal growth (rows) × WACC (columns)"
    assert_includes html, "<th scope='row'>2.00%</th>"
    assert_includes html, "<th scope='col'>9%</th>"
    refute_includes html, "heat-ref"
    # Within 2% of the reference counts; exactly 2% does not.
    marked = Charts.heatmap_html([[100.0, 101.9, 102.0]], row_labels: %w[r], column_labels: %w[a b c], reference: 100.0)
    assert_equal 2, marked.scan("heat-ref").size
    # Flat grids are all heat-1 rather than dividing by zero.
    assert_includes Charts.heatmap_html([[5.0, 5.0]], row_labels: %w[r], column_labels: %w[a b]), "heat-1"
  end

  test "table renders formats and highlight" do
    html = Charts.table_html(
      [{ key: :t, label: "Ticker" }, { key: :v, label: "EV", numeric: true, format: ->(v) { "#{Charts.number(v, decimals: 1)}x" } }],
      [{ t: "NVG", v: 17.5, is_target: true }, { t: "HLDX", v: nil }],
      highlight_key: :is_target
    )
    assert_includes html, "17.5x"
    assert_includes html, "is-highlight"
    assert_includes html, "n/a"
  end

  test "table aligns numeric columns and falls back when a format fails" do
    html = Charts.table_html(
      [
        { key: :t, label: "Ticker" },
        { key: :v, label: "EV", numeric: true, format: ->(v) { format("%.1f", v) } },
        { key: :y, label: "FY", format: ->(v) { "FY#{v}" } }
      ],
      [{ t: "NVG", v: 17.5, is_target: true, y: 2024 }, { t: "HLDX", v: "pending", y: nil }],
      highlight_key: :is_target, caption: "Target shown in the first row"
    )
    assert_includes html, "<caption class='viz-caption'>Target shown in the first row</caption>"
    assert_includes html, "<th scope='col' class=''>Ticker</th>"
    assert_includes html, "<th scope='col' class='num'>EV</th>"
    assert_includes html, "<tr class='is-highlight'><td class=''>NVG</td><td class='num'>17.5</td><td class=''>FY2024</td></tr>"
    # The unformattable string is shown as-is rather than failing the table; nil is n/a.
    assert_includes html, "<tr class=''><td class=''>HLDX</td><td class='num'>pending</td><td class=''>n/a</td></tr>"
    # No caption element without a caption; no highlight without a key.
    bare = Charts.table_html([{ key: :t, label: "T" }], [{ t: "x", is_target: true }])
    refute_includes bare, "<caption"
    refute_includes bare, "is-highlight"
    assert_includes bare, "<table class='data-table'>"
  end

  # ---------------------------------------------------------------- palette

  test "both modes define every role" do
    %w[light dark].each do |mode|
      css = Charts.css_tokens(mode)
      %w[--surface-1 --text-primary --grid --series-1 --seq-7 --diverging-neg].each do |token|
        assert_includes css, token, "#{mode} is missing #{token}"
      end
    end
  end

  test "css tokens emit the same custom properties for both modes under the given selector" do
    light = Charts.css_tokens("light")
    dark = Charts.css_tokens("dark", selector: ":root")
    assert light.start_with?(".viz {\n")
    assert dark.start_with?(":root {\n")
    assert light.end_with?("\n}")
    names = ->(css) { css.scan(/^  (--[\w-]+): /).flatten }
    assert_equal names.(light), names.(dark)
    assert_equal 14 + Charts::MAX_SERIES + 7, names.(light).size
    assert_includes light, "  --series-1: #2a78d6;"
    assert_includes dark, "  --series-1: #3987e5;"
    assert_includes light, "  --seq-1: #cde2fb;"
    assert_includes dark, "  --border: rgba(255,255,255,0.10);"
    assert_equal light, Charts.css_tokens(:light)
    assert_raises(KeyError) { Charts.css_tokens("sepia") }
  end

  test "palette values are the reference hex values" do
    light = Charts::PALETTE[:light]
    dark = Charts::PALETTE[:dark]
    assert_equal "#fcfcfb", light[:surface]
    assert_equal "#1a1a19", dark[:surface]
    assert_equal "#e34948", light[:diverging_neg]
    assert_equal "#e66767", dark[:diverging_neg]
    assert_equal light[:seq], dark[:seq]
    assert_equal light.keys, dark.keys
    assert_equal %w[--series-1 --series-2 --series-3 --series-4 --series-5 --series-6], Charts::SERIES_SLOTS
    assert Charts::PALETTE.frozen?
  end

  test "sequential ramp is single hue and ordered" do
    ramp = Charts::PALETTE[:light][:seq]
    assert_equal 7, ramp.size
    # Light to dark: the summed channel value must decrease monotonically.
    brightness = ramp.map { |step| [1, 3, 5].sum { |i| step[i, 2].to_i(16) } }
    assert_equal brightness.sort.reverse, brightness
  end

  test "status colours are not series colours" do
    tokens = Charts::PALETTE[:dark]
    series = (0...Charts::MAX_SERIES).map { |i| tokens[:"series_#{i + 1}"] }.to_set
    %i[good warning critical].each do |status|
      refute_includes series, tokens[status]
    end
  end
end
