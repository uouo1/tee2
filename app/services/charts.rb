# frozen_string_literal: true

require "cgi"

# Server-side SVG charts, shared by the web UI and the HTML deck export.
#
# Colour roles are emitted as CSS custom properties (`var(--series-1)`) rather
# than literal hex, so one SVG renders correctly in light and dark mode. The
# token values themselves live in PALETTE and are the validated reference
# palette: categorical slots in fixed order (never cycled), one sequential hue
# for magnitude, and a diverging blue/red pair with a neutral grey midpoint for
# polarity.
#
# Rules applied throughout: one axis per chart (never two y-scales), hairline
# gridlines, 2px gaps between adjacent fills, selective direct labels rather
# than a number on every mark, and a legend whenever two or more series share a
# plot.
#
# Every function returns a plain String of markup that the caller marks
# `html_safe`; every label passes through `esc`, so untrusted text is inert.
module Charts
  PALETTE = {
    light: {
      surface: "#fcfcfb", plane: "#f9f9f7",
      text: "#0b0b0b", text_secondary: "#52514e", muted: "#898781",
      grid: "#e1e0d9", axis: "#c3c2b7", border: "rgba(11,11,11,0.10)",
      series_1: "#2a78d6", series_2: "#eb6834", series_3: "#1baf7a",
      series_4: "#eda100", series_5: "#e87ba4", series_6: "#008300",
      diverging_pos: "#2a78d6", diverging_neg: "#e34948", diverging_mid: "#f0efec",
      seq: %w[#cde2fb #9ec5f4 #6da7ec #3987e5 #256abf #184f95 #0d366b].freeze,
      good: "#0ca30c", warning: "#fab219", critical: "#d03b3b"
    }.freeze,
    dark: {
      surface: "#1a1a19", plane: "#0d0d0d",
      text: "#f0efec", text_secondary: "#c3c2b7", muted: "#898781",
      grid: "#2c2c2a", axis: "#383835", border: "rgba(255,255,255,0.10)",
      series_1: "#3987e5", series_2: "#d95926", series_3: "#199e70",
      series_4: "#c98500", series_5: "#d55181", series_6: "#008300",
      diverging_pos: "#3987e5", diverging_neg: "#e66767", diverging_mid: "#383835",
      seq: %w[#cde2fb #9ec5f4 #6da7ec #3987e5 #256abf #184f95 #0d366b].freeze,
      good: "#0ca30c", warning: "#fab219", critical: "#d03b3b"
    }.freeze
  }.freeze

  SERIES_SLOTS = %w[--series-1 --series-2 --series-3 --series-4 --series-5 --series-6].freeze
  MAX_SERIES = SERIES_SLOTS.size
  BAR_RADIUS = 4       # rounded data-end only
  GAP = 2              # surface gap between adjacent fills
  # Single quotes inside the stack: it is interpolated into a double-quoted
  # style attribute, so a double-quoted family name would end the attribute.
  FONT = "system-ui, -apple-system, 'Segoe UI', sans-serif"

  # Default value formats. The Python reference took format strings
  # ("{:,.0f}", "{:.1f}%", "{:+.2f}", "{:,.2f}"); here a value format is any
  # callable taking the raw value and returning text, and these are the same
  # four defaults expressed as Procs.
  INTEGER_FORMAT = ->(value) { Charts.number(value) }                          # "{:,.0f}"
  DECIMAL_FORMAT = ->(value) { Charts.number(value, decimals: 2) }             # "{:,.2f}"
  PERCENT_FORMAT = ->(value) { "#{Charts.fixed(value, decimals: 1)}%" }        # "{:.1f}%"
  SIGNED_FORMAT  = ->(value) { Charts.fixed(value, decimals: 2, sign: true) }  # "{:+.2f}"

  module_function

  # Emit the palette as CSS custom properties for one mode.
  def css_tokens(mode = "light", selector: ".viz")
    tokens = PALETTE.fetch(mode.to_sym)
    lines = [
      "  --surface-1: #{tokens[:surface]};",
      "  --plane: #{tokens[:plane]};",
      "  --text-primary: #{tokens[:text]};",
      "  --text-secondary: #{tokens[:text_secondary]};",
      "  --muted: #{tokens[:muted]};",
      "  --grid: #{tokens[:grid]};",
      "  --axis: #{tokens[:axis]};",
      "  --border: #{tokens[:border]};",
      "  --diverging-pos: #{tokens[:diverging_pos]};",
      "  --diverging-neg: #{tokens[:diverging_neg]};",
      "  --diverging-mid: #{tokens[:diverging_mid]};",
      "  --good: #{tokens[:good]};",
      "  --warning: #{tokens[:warning]};",
      "  --critical: #{tokens[:critical]};"
    ]
    MAX_SERIES.times do |index|
      lines << "  --series-#{index + 1}: #{tokens[:"series_#{index + 1}"]};"
    end
    tokens[:seq].each_with_index do |step, index|
      lines << "  --seq-#{index + 1}: #{step};"
    end
    "#{selector} {\n#{lines.join("\n")}\n}"
  end

  # Correctly rounded fixed-point text with ties to even — what C's printf and
  # therefore the Python reference produce. Ruby's own sprintf rounds the
  # shortest decimal representation instead (0.025 -> "0.02", 44.135 -> "44.14"),
  # which disagreed with the reference on roughly one value in twenty across
  # prices, multiples and coordinates; going through the exact Rational value
  # removes the drift. `sign: true` is the "+" flag.
  def fixed(value, decimals: 0, sign: false)
    value = Float(value) unless value.is_a?(Numeric)
    return format("%#{'+' if sign}.#{decimals}f", value) unless value.to_f.finite?

    # Keep the sign of a negative value that rounds to zero ("-0.00"), as printf does.
    negative = value.to_f.negative? || (value.to_f.zero? && value.to_f.to_s.start_with?("-"))
    scaled = (value.to_r.round(decimals, half: :even) * 10**decimals).to_i.abs
    digits = scaled.to_s.rjust(decimals + 1, "0")
    text = decimals.zero? ? digits : "#{digits[0...-decimals]}.#{digits[-decimals..]}"
    "#{negative ? '-' : (sign ? '+' : '')}#{text}"
  end

  # Thousands-grouped fixed-point text, the Ruby stand-in for "{:,.Nf}".
  def number(value, decimals: 0)
    whole, fraction = fixed(value, decimals: decimals).split(".", 2)
    whole = whole.gsub(/(\d)(?=(\d{3})+\z)/, '\1,')
    fraction ? "#{whole}.#{fraction}" : whole
  end

  # Round axis ticks spanning [low, high].
  #
  # The magnitude is derived from the raw step rather than assumed, so a chart
  # whose values span three percentage points gets four gridlines and not
  # twenty-seven.
  def nice_ticks(low, high, count = 5)
    return [low] if high <= low

    raw = (high - low).fdiv([1, count - 1].max)
    return [low, high] if raw <= 0

    # Python's `10 ** floor(log10(raw))` is an int for raw >= 1 and a float
    # below it, and the ticks inherit that: a whole-number axis comes back as
    # Integers (so a caller's format that prints the raw value shows "200",
    # not "200.0") while a fractional one is Floats. Ruby would hand back a
    # Rational for an Integer raised to a negative power, hence the 10.0.
    exponent = Math.log10(raw).floor
    magnitude = exponent >= 0 ? 10**exponent : 10.0**exponent
    step = magnitude
    [1, 2, 2.5, 5, 10].each do |factor|
      step = magnitude * factor
      break if step >= raw
    end
    start = low.fdiv(step).floor * step
    ticks = []
    value = start
    # Guard against a pathological step producing an unbounded axis.
    while value <= high + step * 0.5 && ticks.size < 24
      ticks << value.round(6)
      value += step
    end
    ticks.empty? ? [low, high] : ticks
  end

  # ------------------------------------------------------------ football field

  # Floating range bars per methodology against one shared price axis.
  #
  # One measure (value per share) on one axis, so every methodology is one
  # series in one colour; the current share price is a reference rule, not a
  # second series.
  def football_field_svg(ranges, reference_price: nil, concluded: nil, currency_symbol: "$", width: 760, row_height: 44)
    ranges = ranges.to_a
    return '<p class="viz-empty">No valuation ranges available.</p>' if ranges.empty?

    label_width = 232
    pad_right = 56
    top = 34
    height = top + row_height * ranges.size + 54
    plot_left = label_width
    plot_width = width - label_width - pad_right

    lows = ranges.map { |r| Float(r[:low]) }
    highs = ranges.map { |r| Float(r[:high]) }
    if truthy?(reference_price)
      lows << Float(reference_price)
      highs << Float(reference_price)
    end
    axis_min = lows.min * 0.92
    axis_max = highs.max * 1.06
    ticks = nice_ticks(axis_min, axis_max, 6)
    # Both bounds as Floats: when the padded range snaps to whole-number ticks on
    # both ends (say [20, 70]) the Integer ticks win the min/max, and
    # Integer / Integer in x_of would truncate every tick to x = plot_left. The
    # Python reference never had the problem because its `/` is true division.
    axis_min = [axis_min, ticks.first].min.to_f
    axis_max = [axis_max, ticks.last].max.to_f

    x_of = ->(value) { plot_left + (value - axis_min) / (axis_max - axis_min) * plot_width }

    parts = svg_open(width, height, "Valuation summary — implied value per share",
                     "Range of implied value per share by valuation methodology.")

    if concluded && truthy?(concluded[:low]) && truthy?(concluded[:high])
      x1 = x_of.(Float(concluded[:low]))
      x2 = x_of.(Float(concluded[:high]))
      parts << %(<rect x="#{px(x1)}" y="#{top - 8}" width="#{px([1.0, x2 - x1].max)}" ) +
               %(height="#{row_height * ranges.size + 10}" fill="var(--series-1)" opacity="0.07" />)
    end

    ticks.each do |tick|
      x = x_of.(tick)
      parts << %(<line x1="#{px(x)}" y1="#{top - 10}" x2="#{px(x)}" y2="#{top + row_height * ranges.size}" ) +
               %(stroke="var(--grid)" stroke-width="1" />)
      parts << %(<text x="#{px(x)}" y="#{top + row_height * ranges.size + 18}" fill="var(--muted)" ) +
               %(font-size="11" text-anchor="middle" style="font-variant-numeric:tabular-nums">) +
               %(#{esc("#{currency_symbol}#{number(tick)}")}</text>)
    end

    ranges.each_with_index do |row, index|
      y = top + index * row_height
      bar_y = y + (row_height - 18) / 2.0
      x1 = x_of.(Float(row[:low]))
      x2 = x_of.(Float(row[:high]))
      bar_width = [3.0, x2 - x1 - GAP].max
      parts << %(<text x="#{label_width - 14}" y="#{bar_y + 13}" text-anchor="end" font-size="12.5" ) +
               %(fill="var(--text-primary)">#{esc(row[:method])}</text>)
      basis = truthy?(row[:basis]) ? " · #{esc(row[:basis])}" : ""
      parts << %(<rect x="#{px(x1)}" y="#{px(bar_y)}" width="#{px(bar_width)}" height="18" rx="#{BAR_RADIUS}" ) +
               %(fill="var(--series-1)" opacity="0.88"><title>#{esc(row[:method])}: ) +
               %(#{esc(currency_symbol)}#{number(row[:low], decimals: 2)} – #{esc(currency_symbol)}#{number(row[:high], decimals: 2)}) +
               %(#{basis}</title></rect>)
      # Direct labels at both ends: the relief rule for low-contrast fills, and
      # the reason this chart needs no tooltip to be readable.
      low_label = "#{currency_symbol}#{number(row[:low])}"
      high_label = "#{currency_symbol}#{number(row[:high])}"
      parts << %(<text x="#{px(x1 - 8)}" y="#{bar_y + 13}" text-anchor="end" font-size="11" ) +
               %(fill="var(--text-secondary)" style="font-variant-numeric:tabular-nums">) +
               %(#{esc(low_label)}</text>)
      parts << %(<text x="#{px(x1 + bar_width + 8)}" y="#{bar_y + 13}" font-size="11" ) +
               %(fill="var(--text-secondary)" style="font-variant-numeric:tabular-nums">) +
               %(#{esc(high_label)}</text>)
    end

    if truthy?(reference_price)
      x = x_of.(Float(reference_price))
      parts << %(<line x1="#{px(x)}" y1="#{top - 16}" x2="#{px(x)}" y2="#{top + row_height * ranges.size + 2}" ) +
               %(stroke="var(--text-primary)" stroke-width="2" />)
      parts << %(<text x="#{px(x)}" y="#{top - 20}" font-size="11.5" text-anchor="middle" fill="var(--text-primary)">) +
               %(Current #{esc("#{currency_symbol}#{number(reference_price, decimals: 2)}")}</text>)
    end
    parts << "</svg>"
    parts.join("\n")
  end

  # -------------------------------------------------------------- bar / column

  # Single-series columns: one measure, one colour, selective labels.
  #
  # `highlight_index` applies emphasis (one bar in the series colour, the rest
  # recessive) — the honest alternative to colouring every bar differently.
  # `estimate_from` marks forecast periods with a lighter fill and a legend.
  def column_chart_svg(labels, values, title: "", value_format: INTEGER_FORMAT, highlight_index: nil,
                       estimate_from: nil, width: 620, height: 240, label_every: 1)
    labels = labels.to_a
    values = values.to_a
    return '<p class="viz-empty">No data.</p>' if values.empty?

    pad_left = 54
    pad_right = 16
    pad_top = truthy?(title) ? 26 : 14
    pad_bottom = 42
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    top_value = values.max * 1.12
    top_value = 1 if top_value.zero?
    ticks = nice_ticks(0, top_value, 5)
    top_value = [top_value, ticks.last].max.to_f
    slot = plot_w.fdiv(values.size)
    bar_w = [6.0, slot - GAP * 3].max

    parts = svg_open(width, height, truthy?(title) ? title : "Column chart")
    parts << %(<text x="0" y="14" font-size="12.5" fill="var(--text-secondary)">#{esc(title)}</text>) if truthy?(title)
    ticks.each do |tick|
      y = pad_top + plot_h - (tick / top_value) * plot_h
      parts << %(<line x1="#{pad_left}" y1="#{px(y)}" x2="#{width - pad_right}" y2="#{px(y)}" stroke="var(--grid)" stroke-width="1" />)
      parts << %(<text x="#{pad_left - 8}" y="#{px(y + 4)}" font-size="11" text-anchor="end" fill="var(--muted)" ) +
               %(style="font-variant-numeric:tabular-nums">#{esc(value_format.call(tick))}</text>)
    end
    parts << %(<line x1="#{pad_left}" y1="#{px(pad_top + plot_h)}" x2="#{width - pad_right}" y2="#{px(pad_top + plot_h)}" ) +
             %(stroke="var(--axis)" stroke-width="1" />)
    values.each_with_index do |value, index|
      x = pad_left + index * slot + (slot - bar_w) / 2
      bar_h = [1.0, ([0.0, Float(value)].max / top_value) * plot_h].max
      y = pad_top + plot_h - bar_h
      is_estimate = !estimate_from.nil? && index >= estimate_from
      opacity =
        if !highlight_index.nil? && index != highlight_index then "0.42"
        elsif is_estimate then "0.55"
        else "0.9"
        end
      parts << %(<rect x="#{px(x)}" y="#{px(y)}" width="#{px(bar_w)}" height="#{px(bar_h)}" rx="#{BAR_RADIUS}" ) +
               %(fill="var(--series-1)" opacity="#{opacity}"><title>#{esc(labels[index])}: ) +
               %(#{esc(value_format.call(value))}#{is_estimate ? " (estimate)" : ""}</title></rect>)
      show_label =
        index == values.size - 1 ||
        index == highlight_index ||
        (highlight_index.nil? && truthy?(label_every) && (index % label_every).zero?)
      if show_label
        parts << %(<text x="#{px(x + bar_w / 2)}" y="#{px(y - 6)}" font-size="11" text-anchor="middle" ) +
                 %(fill="var(--text-secondary)" style="font-variant-numeric:tabular-nums">) +
                 %(#{esc(value_format.call(value))}</text>)
      end
      parts << %(<text x="#{px(x + bar_w / 2)}" y="#{px(pad_top + plot_h + 16)}" font-size="11" text-anchor="middle" ) +
               %(fill="var(--muted)">#{esc(labels[index])}</text>)
    end
    if !estimate_from.nil? && estimate_from < values.size
      parts << %(<g><rect x="#{pad_left}" y="#{height - 14}" width="10" height="10" rx="2" fill="var(--series-1)" opacity="0.9" />) +
               %(<text x="#{pad_left + 15}" y="#{height - 5}" font-size="10.5" fill="var(--muted)">Actual</text>) +
               %(<rect x="#{pad_left + 68}" y="#{height - 14}" width="10" height="10" rx="2" fill="var(--series-1)" opacity="0.55" />) +
               %(<text x="#{pad_left + 83}" y="#{height - 5}" font-size="10.5" fill="var(--muted)">Estimate</text></g>)
    end
    parts << "</svg>"
    parts.join("\n")
  end

  # One measure over time: 2px line, >=8px endpoint marker, endpoint label.
  def line_chart_svg(labels, values, title: "", value_format: PERCENT_FORMAT, width: 620, height: 200)
    labels = labels.to_a
    values = values.to_a
    points = values.each_with_index.filter_map { |v, i| [i, v] unless v.nil? }
    return '<p class="viz-empty">Not enough data for a trend.</p>' if points.size < 2

    pad_left = 54
    pad_right = 46
    pad_top = truthy?(title) ? 26 : 12
    pad_bottom = 34
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    numeric = points.map { |_, v| v }
    low = numeric.min
    high = numeric.max
    # A flat series still needs a non-zero span to place gridlines around it.
    span = high - low
    span = high.abs if span.zero?
    span = 1 if span.zero?
    low -= span * 0.18
    high += span * 0.18
    ticks = nice_ticks(low, high, 4)

    x_of = ->(index) { pad_left + index.fdiv([1, values.size - 1].max) * plot_w }
    y_of = ->(value) { pad_top + plot_h - (value - low) / (high - low) * plot_h }

    parts = svg_open(width, height, truthy?(title) ? title : "Trend")
    parts << %(<text x="0" y="14" font-size="12.5" fill="var(--text-secondary)">#{esc(title)}</text>) if truthy?(title)
    ticks.each do |tick|
      y = y_of.(tick)
      next unless (pad_top - 2) <= y && y <= pad_top + plot_h + 2

      parts << %(<line x1="#{pad_left}" y1="#{px(y)}" x2="#{width - pad_right}" y2="#{px(y)}" stroke="var(--grid)" stroke-width="1" />)
      parts << %(<text x="#{pad_left - 8}" y="#{px(y + 4)}" font-size="11" text-anchor="end" fill="var(--muted)" ) +
               %(style="font-variant-numeric:tabular-nums">#{esc(value_format.call(tick))}</text>)
    end
    path = points.each_with_index.map do |(index, value), i|
      "#{i.zero? ? 'M' : 'L'}#{px(x_of.(index))},#{px(y_of.(value))}"
    end.join(" ")
    parts << %(<path d="#{path}" fill="none" stroke="var(--series-1)" stroke-width="2" stroke-linejoin="round" />)
    points.each do |index, value|
      parts << %(<circle cx="#{px(x_of.(index))}" cy="#{px(y_of.(value))}" r="4" fill="var(--series-1)" ) +
               %(stroke="var(--surface-1)" stroke-width="2"><title>#{esc(labels[index])}: ) +
               %(#{esc(value_format.call(value))}</title></circle>)
    end
    last_index, last_value = points.last
    parts << %(<text x="#{px(x_of.(last_index) + 9)}" y="#{px(y_of.(last_value) + 4)}" font-size="11.5" ) +
             %(fill="var(--text-primary)" style="font-variant-numeric:tabular-nums">#{esc(value_format.call(last_value))}</text>)
    step = [1, labels.size / 7].max
    (0...labels.size).step(step) do |index|
      parts << %(<text x="#{px(x_of.(index))}" y="#{height - 12}" font-size="10.5" text-anchor="middle" ) +
               %(fill="var(--muted)">#{esc(labels[index])}</text>)
    end
    parts << "</svg>"
    parts.join("\n")
  end

  # Polarity around zero: two hues that read as opposite, neutral midline.
  def diverging_bar_svg(labels, values, title: "", width: 620, height: 210, value_format: SIGNED_FORMAT)
    labels = labels.to_a
    values = values.to_a
    return '<p class="viz-empty">No data.</p>' if values.empty?

    pad_left = 46
    pad_right = 16
    pad_top = truthy?(title) ? 26 : 12
    pad_bottom = 54
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    extent = [0.05, values.map { |v| Float(v).abs }.max * 1.2].max
    zero_y = pad_top + plot_h / 2.0
    slot = plot_w.fdiv(values.size)
    bar_w = [4.0, slot - GAP * 2].max

    parts = svg_open(width, height, truthy?(title) ? title : "Sentiment")
    parts << %(<text x="0" y="14" font-size="12.5" fill="var(--text-secondary)">#{esc(title)}</text>) if truthy?(title)
    [-extent / 2, 0, extent / 2].each do |level|
      y = zero_y - (level / extent) * (plot_h / 2.0)
      stroke = level == 0 ? "var(--axis)" : "var(--grid)"
      parts << %(<line x1="#{pad_left}" y1="#{px(y)}" x2="#{width - pad_right}" y2="#{px(y)}" stroke="#{stroke}" stroke-width="1" />)
      parts << %(<text x="#{pad_left - 8}" y="#{px(y + 4)}" font-size="10.5" text-anchor="end" fill="var(--muted)" ) +
               %(style="font-variant-numeric:tabular-nums">#{esc(fixed(level, decimals: 2, sign: true))}</text>)
    end
    values.each_with_index do |raw, index|
      value = Float(raw)
      x = pad_left + index * slot + (slot - bar_w) / 2
      bar_h = [1.0, value.abs / extent * (plot_h / 2.0)].max
      y = value >= 0 ? zero_y - bar_h : zero_y
      colour = value >= 0 ? "var(--diverging-pos)" : "var(--diverging-neg)"
      parts << %(<rect x="#{px(x)}" y="#{px(y)}" width="#{px(bar_w)}" height="#{px(bar_h)}" rx="2" fill="#{colour}" ) +
               %(opacity="0.88"><title>#{esc(labels[index])}: #{esc(value_format.call(value))}</title></rect>)
    end
    step = [1, labels.size / 8].max
    (0...labels.size).step(step) do |index|
      parts << %(<text x="#{px(pad_left + index * slot + slot / 2)}" y="#{px(pad_top + plot_h + 16)}" font-size="10.5" ) +
               %(text-anchor="middle" fill="var(--muted)">#{esc(labels[index])}</text>)
    end
    legend_y = height - 8
    parts << %(<g><rect x="#{pad_left}" y="#{legend_y - 9}" width="9" height="9" rx="2" fill="var(--diverging-pos)" />) +
             %(<text x="#{pad_left + 14}" y="#{legend_y}" font-size="10" fill="var(--muted)">Positive tone</text>) +
             %(<rect x="#{pad_left + 96}" y="#{legend_y - 9}" width="9" height="9" rx="2" fill="var(--diverging-neg)" />) +
             %(<text x="#{pad_left + 110}" y="#{legend_y}" font-size="10" fill="var(--muted)">Negative tone</text></g>)
    parts << "</svg>"
    parts.join("\n")
  end

  # Document volume by type: categorical slots in fixed order, legend always.
  # `series` is `[{name:, values:}]`; anything past MAX_SERIES is dropped rather
  # than cycled back to slot one.
  def stacked_bar_svg(labels, series, title: "", width: 620, height: 230)
    labels = labels.to_a
    series = series.to_a
    return '<p class="viz-empty">No data.</p>' if series.empty? || labels.empty?

    series = series.first(MAX_SERIES)
    pad_left = 42
    pad_right = 14
    pad_top = truthy?(title) ? 26 : 12
    pad_bottom = 52
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    totals = labels.each_index.map { |i| series.sum { |s| Float(s[:values][i] || 0) } }
    top_value = totals.max * 1.1
    top_value = 1 if top_value.zero?
    ticks = nice_ticks(0, top_value, 4)
    top_value = [top_value, ticks.last].max.to_f
    slot = plot_w.fdiv(labels.size)
    bar_w = [5.0, slot - GAP * 3].max

    parts = svg_open(width, height, truthy?(title) ? title : "Volume by type")
    parts << %(<text x="0" y="14" font-size="12.5" fill="var(--text-secondary)">#{esc(title)}</text>) if truthy?(title)
    ticks.each do |tick|
      y = pad_top + plot_h - (tick / top_value) * plot_h
      parts << %(<line x1="#{pad_left}" y1="#{px(y)}" x2="#{width - pad_right}" y2="#{px(y)}" stroke="var(--grid)" stroke-width="1" />)
      parts << %(<text x="#{pad_left - 8}" y="#{px(y + 4)}" font-size="10.5" text-anchor="end" fill="var(--muted)" ) +
               %(style="font-variant-numeric:tabular-nums">#{esc(number(tick))}</text>)
    end
    labels.each_with_index do |label, index|
      x = pad_left + index * slot + (slot - bar_w) / 2
      cursor = pad_top + plot_h
      series.each_with_index do |entry, slot_index|
        value = Float(entry[:values][index] || 0)
        next if value <= 0

        segment_h = (value / top_value) * plot_h
        cursor -= segment_h
        parts << %(<rect x="#{px(x)}" y="#{px(cursor)}" width="#{px(bar_w)}" height="#{px([1.0, segment_h - GAP].max)}" ) +
                 %(rx="2" fill="var(#{SERIES_SLOTS[slot_index]})" opacity="0.9">) +
                 %(<title>#{esc(label)} · #{esc(entry[:name])}: #{number(value)}</title></rect>)
      end
    end
    step = [1, labels.size / 8].max
    (0...labels.size).step(step) do |index|
      parts << %(<text x="#{px(pad_left + index * slot + slot / 2)}" y="#{px(pad_top + plot_h + 15)}" font-size="10.5" ) +
               %(text-anchor="middle" fill="var(--muted)">#{esc(labels[index])}</text>)
    end
    legend_x = pad_left
    series.each_with_index do |entry, slot_index|
      parts << %(<rect x="#{legend_x}" y="#{height - 20}" width="9" height="9" rx="2" fill="var(#{SERIES_SLOTS[slot_index]})" />) +
               %(<text x="#{legend_x + 14}" y="#{height - 12}" font-size="10.5" fill="var(--muted)">#{esc(entry[:name])}</text>)
      legend_x += 24 + 7 * entry[:name].to_s.length
    end
    parts << "</svg>"
    parts.join("\n")
  end

  # Sensitivity grid as an HTML table on one sequential blue ramp.
  #
  # A table rather than an SVG on purpose: the cells carry readable numbers, so
  # colour is a secondary cue and the low-contrast steps keep their relief.
  def heatmap_html(grid, row_labels:, column_labels:, row_title: "", column_title: "",
                   value_format: DECIMAL_FORMAT, reference: nil)
    grid = grid.to_a
    flat = grid.flat_map { |row| row.to_a.compact.map { |v| Float(v) } }
    return '<p class="viz-empty">No sensitivity data.</p>' if flat.empty?

    low = flat.min
    high = flat.max
    span = high - low
    span = 1 if span.zero?

    # 7-step ramp, light (low) to dark (high).
    step_for = ->(value) { [7, [1, ((value - low) / span * 6).to_i + 1].max].min }

    head = column_labels.map { |c| "<th scope='col'>#{esc(c)}</th>" }.join
    # Python's zip semantics: stop at the shorter of labels and grid.
    rows_html = (0...[row_labels.size, grid.size].min).map do |index|
      label = row_labels[index]
      cells = grid[index].map do |value|
        next '<td class="heat-na">n/a</td>' if value.nil?

        step = step_for.(Float(value))
        near_reference = truthy?(reference) && (Float(value) - reference).abs / reference < 0.02
        classes = "heat heat-#{step}#{near_reference ? ' heat-ref' : ''}"
        %(<td class="#{classes}">#{esc(value_format.call(value))}</td>)
      end
      "<tr><th scope='row'>#{esc(label)}</th>#{cells.join}</tr>"
    end
    %(<table class="heatmap"><caption class="viz-caption">#{esc(row_title)} (rows) × #{esc(column_title)} (columns)</caption>) +
      %(<thead><tr><th scope='col'></th>#{head}</tr></thead><tbody>#{rows_html.join}</tbody></table>)
  end

  # Accessible data table — also the "table view" every chart falls back to.
  # `columns` is `[{key:, label:, numeric:, format:}]` where `format` is a Proc
  # (or nil); a formatter that cannot handle a value falls back to `to_s`
  # rather than failing the whole table.
  def table_html(columns, rows, caption: "", highlight_key: nil)
    head = columns.map do |c|
      "<th scope='col' class='#{truthy?(c[:numeric]) ? 'num' : ''}'>#{esc(c[:label])}</th>"
    end.join
    body = rows.map do |row|
      classes = truthy?(highlight_key) && truthy?(row[highlight_key]) ? "is-highlight" : ""
      cells = columns.map do |column|
        value = row[column[:key]]
        fmt = column[:format]
        text =
          if value.nil?
            "n/a"
          elsif fmt
            begin
              fmt.call(value)
            rescue ArgumentError, TypeError, NoMethodError
              value.to_s
            end
          else
            value.to_s
          end
        "<td class='#{truthy?(column[:numeric]) ? 'num' : ''}'>#{esc(text)}</td>"
      end
      "<tr class='#{classes}'>#{cells.join}</tr>"
    end
    caption_html = truthy?(caption) ? "<caption class='viz-caption'>#{esc(caption)}</caption>" : ""
    "<table class='data-table'>#{caption_html}<thead><tr>#{head}</tr></thead><tbody>#{body.join}</tbody></table>"
  end

  # ------------------------------------------------------------------ helpers

  # Always escapes, even an already `html_safe` string: labels come from
  # filings, tickers and user-entered titles, and this module is the last stop
  # before markup.
  def esc(value)
    CGI.escapeHTML(value.to_s)
  end

  # Coordinates are written to one decimal place, like the reference's `:.1f`.
  def px(value)
    fixed(value, decimals: 1)
  end

  # Python truthiness, which the reference leans on for its optional inputs:
  # nil, false, zero and empty strings/collections all read as "absent".
  def truthy?(value)
    return false if value.nil? || value == false
    return false if value.is_a?(Numeric) && value.zero?
    return false if value.respond_to?(:empty?) && value.empty?

    true
  end

  def svg_open(width, height, title, description = "")
    parts = [
      %(<svg class="viz-svg" viewBox="0 0 #{width} #{height}" width="100%" height="#{height}" ) +
        %(role="img" aria-label="#{esc(title)}" xmlns="http://www.w3.org/2000/svg" ) +
        %(style="font-family:#{FONT}">),
      "<title>#{esc(title)}</title>"
    ]
    parts << "<desc>#{esc(description)}</desc>" if truthy?(description)
    parts
  end

  private_class_method :esc, :px, :truthy?, :svg_open
end
